#!/usr/bin/env python3
"""
eval_cloudflare_models.py

Evaluates 4 Cloudflare Workers AI models via the `cf` CLI (`cf ai run`) on the
Instance 12 OpenSSH Wildcard Precedence Override benchmark in two blind modes:
  1. `blind_file_edit`   : Multi-turn agent with full file-edit actions + live 4-VM QEMU verification.
  2. `stanza_scoped_tool`: Multi-turn agent restricted to stanza-scoped `set_proxy_jump` + live verification.

Every intermediate and final candidate config is evaluated against BOTH:
  - Live 4-VM QEMU OpenSSH cluster (`wc-client -> server1 -> server3 -> server2`)
  - Deterministic C99 preflight checker (`./check_client_precedence`)

Credentials are read from environment variables (`CLOUDFLARE_ACCOUNT_ID`,
`CLOUDFLARE_API_TOKEN`, and optional `QEMU_SSH_PASSWORD`) or `--env-file`.
No secrets are stored in this file or written to output artifacts.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

REPO_DIR = Path(__file__).resolve().parent

DEFAULT_MODELS = [
    "@cf/openai/gpt-oss-120b",
    "@cf/google/gemma-4-26b-a4b-it",
    "@cf/qwen/qwen2.5-coder-32b-instruct",
    "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
]

INITIAL_BLIND_CONFIG = (REPO_DIR / "ssh_config.buggy").read_text(encoding="utf-8")

TASK_PROMPT_BLIND = """\
Task: Fix the broken SSH connection to `server2`.

Environment:
- Running `test_connection` executes `ssh -o ConnectTimeout=4 server2 hostname` from `wc-client` (`10.202.1.2/24`).
- Currently `test_connection` fails with:
  "jumphost loop via server3"
- The client SSH configuration file is located at `client/.ssh/config`.
- You can reset `client/.ssh/config` back to the initial broken state with `reset_lab`.

Instructions:
1. Diagnose all configuration defects in `client/.ssh/config` preventing SSH connectivity to `server2`.
2. Edit `client/.ssh/config` with the minimal reversible fix to restore multi-hop connectivity.
3. Verify that `test_connection` outputs `server2` with exit code 0, then call `done`.
"""

SYSTEM_PROMPT_FILE_EDIT = """\
You are an autonomous Linux/DevOps troubleshooting agent.
You must solve the task by emitting ONE JSON action object per turn (no surrounding markdown prose unless required, prefer raw JSON).

Available JSON actions:
1. {"action": "read_config"}
   Reads `client/.ssh/config` with line numbers.
2. {"action": "edit_line", "old_text": "<unique exact substring>", "new_text": "<replacement>"}
   Replaces the exact substring `old_text` in `client/.ssh/config` with `new_text`. `old_text` must match uniquely in the file (include the `Host ...` line if needed to disambiguate).
3. {"action": "test_connection"}
   Runs `./test_connection.sh` (`ssh -o ConnectTimeout=4 server2 hostname` on `wc-client`) and returns exit code and output.
4. {"action": "reset_lab"}
   Restores `client/.ssh/config` to its initial broken state.
5. {"action": "done", "diagnosis": "<root cause>", "summary": "<what was fixed and verified>"}
   Finishes the session after `test_connection` passes with exit code 0 and output `server2`.

Rules:
- Output ONLY a single valid JSON object per turn.
- Do not fabricate tool outputs; always run `test_connection` after editing to verify.
"""

SYSTEM_PROMPT_STANZA_SCOPED = """\
You are an autonomous Linux/DevOps troubleshooting agent.
You have a stanza-scoped SSH config management tool (`set_proxy_jump`, similar to Ansible `community.general.ssh_config` / Augeas) rather than freeform file editing.
You must emit ONE JSON action object per turn.

Available JSON actions:
1. {"action": "read_config"}
   Reads `client/.ssh/config` with line numbers.
2. {"action": "set_proxy_jump", "host": "<host_pattern>", "proxy_jump": "<jump_host_or_none>"}
   Updates or inserts `ProxyJump <jump_host_or_none>` inside the matching `Host <host_pattern>` stanza in `client/.ssh/config` (preserving stanza ordering; valid values are a hostname, comma-separated jump list, or `none`).
3. {"action": "test_connection"}
   Runs `./test_connection.sh` (`ssh -o ConnectTimeout=4 server2 hostname` on `wc-client`) and returns exit code and output.
4. {"action": "done", "diagnosis": "<root cause>", "summary": "<what was fixed and verified>"}
   Finishes the session once `test_connection` passes with exit code 0 and output `server2`.

Rules:
- Output ONLY a single valid JSON object per turn.
- Do not fabricate tool outputs; always run `test_connection` after editing to verify.
"""


def load_env_file(path: Path) -> None:
    """Loads KEY=VALUE lines from an env file if present without overriding existing env vars."""
    if not path.is_file():
        return
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].strip()
        if "=" not in line:
            continue
        key, val = line.split("=", 1)
        key = key.strip()
        val = val.strip().strip("'").strip('"')
        if key and key not in os.environ:
            os.environ[key] = val


def strip_ansi(text: str) -> str:
    return re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text)


def parse_cf_json_stdout(raw_stdout: str) -> Dict[str, Any]:
    """Extracts the final JSON object emitted by `cf ai run --quiet` after spinner text."""
    cleaned = strip_ansi(raw_stdout).replace("\r", "\n")
    decoder = json.JSONDecoder()
    for match in re.finditer(r"^\s*\{", cleaned, flags=re.MULTILINE):
        idx = match.start()
        candidate = cleaned[idx:].lstrip()
        try:
            obj, _ = decoder.raw_decode(candidate)
            if isinstance(obj, dict):
                return obj
        except json.JSONDecodeError:
            continue
    # Fallback: try any '{'
    pos = cleaned.find("{")
    while pos != -1:
        try:
            obj, _ = decoder.raw_decode(cleaned[pos:])
            if isinstance(obj, dict):
                return obj
        except json.JSONDecodeError:
            pass
        pos = cleaned.find("{", pos + 1)
    raise ValueError(f"Could not locate JSON response in cf output:\n{cleaned[:1200]}")


def call_cf_model(
    cf_bin: str,
    model: str,
    messages: List[Dict[str, str]],
    max_tokens: int = 2048,
    timeout_s: int = 120,
    temperature: float = 0.0,
) -> Dict[str, Any]:
    """Runs one chat turn via `cf ai run <model> --body @<tmp.json> --quiet`."""
    payload: Dict[str, Any] = {
        "messages": messages,
        "temperature": temperature,
    }
    if "gemma-4" in model:
        payload["max_completion_tokens"] = max_tokens
        payload["chat_template_kwargs"] = {"enable_thinking": False}
    else:
        payload["max_tokens"] = max_tokens

    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as tf:
        json.dump(payload, tf)
        body_path = tf.name

    t0 = time.perf_counter()
    try:
        proc = subprocess.run(
            [cf_bin, "ai", "run", model, "--body", f"@{body_path}", "--quiet"],
            capture_output=True,
            text=True,
            timeout=timeout_s,
            check=False,
        )
    finally:
        try:
            os.unlink(body_path)
        except OSError:
            pass

    elapsed_ms = (time.perf_counter() - t0) * 1000.0
    combined = (proc.stdout or "") + ("\n" + proc.stderr if proc.stderr else "")
    if proc.returncode != 0:
        raise RuntimeError(f"cf ai run exited {proc.returncode} for {model}: {combined[:1500]}")

    parsed = parse_cf_json_stdout(proc.stdout or "")
    raw_content: Any = ""
    raw_reasoning: Any = ""
    if "choices" in parsed and parsed["choices"]:
        msg = parsed["choices"][0].get("message", {})
        raw_content = msg.get("content")
        raw_reasoning = msg.get("reasoning_content") or msg.get("reasoning")
    elif "response" in parsed:
        raw_content = parsed.get("response")

    content = raw_content if isinstance(raw_content, str) else (json.dumps(raw_content) if raw_content is not None else "")
    reasoning = raw_reasoning if isinstance(raw_reasoning, str) else (json.dumps(raw_reasoning) if raw_reasoning is not None else "")

    usage = parsed.get("usage") or {}
    return {
        "content": content,
        "reasoning": reasoning,
        "usage": {
            "prompt_tokens": usage.get("prompt_tokens"),
            "completion_tokens": usage.get("completion_tokens"),
            "total_tokens": usage.get("total_tokens"),
            "neurons": usage.get("neurons"),
        },
        "latency_ms": round(elapsed_ms, 2),
        "raw_model": parsed.get("model", model),
    }


def extract_action_json(text: str, reasoning_fallback: str = "") -> Optional[Dict[str, Any]]:
    """Extracts the JSON action object from assistant output."""
    candidates = [text]
    if not text.strip() and reasoning_fallback.strip():
        candidates.append(reasoning_fallback)

    decoder = json.JSONDecoder()
    for raw in candidates:
        if not raw:
            continue
        cleaned = re.sub(r"<think>.*?</think>", "", raw, flags=re.DOTALL).strip()
        # Try direct parse
        try:
            obj = json.loads(cleaned)
            if isinstance(obj, dict) and "action" in obj:
                return obj
        except json.JSONDecodeError:
            pass

        # Try fenced code blocks
        for block in re.findall(r"```(?:json)?\s*(\{.*?\})\s*```", cleaned, flags=re.DOTALL):
            try:
                obj = json.loads(block)
                if isinstance(obj, dict) and "action" in obj:
                    return obj
            except json.JSONDecodeError:
                pass

        # Scan balanced JSON objects, prefer the first one with "action"
        found: List[Dict[str, Any]] = []
        idx = cleaned.find("{")
        while idx != -1:
            try:
                obj, end = decoder.raw_decode(cleaned[idx:])
                if isinstance(obj, dict) and "action" in obj:
                    found.append(obj)
                idx = cleaned.find("{", idx + max(1, end))
                continue
            except json.JSONDecodeError:
                pass
            idx = cleaned.find("{", idx + 1)
        if found:
            return found[0]
    return None


def compile_preflight() -> Path:
    bin_path = REPO_DIR / "check_client_precedence"
    src_path = REPO_DIR / "check_client_precedence.c"
    if not bin_path.exists() or src_path.stat().st_mtime > bin_path.stat().st_mtime:
        cc = shutil.which("clang") or shutil.which("gcc")
        if not cc:
            raise RuntimeError("Neither clang nor gcc found to compile check_client_precedence.c")
        subprocess.run(
            [cc, "-std=c99", "-Wall", "-Wextra", str(src_path), "-o", str(bin_path)],
            check=True,
        )
    return bin_path


def run_c99_preflight(preflight_bin: Path, config_text: str, target_host: str = "server2") -> Dict[str, Any]:
    with tempfile.NamedTemporaryFile("w", suffix=".ssh_config", delete=False, encoding="utf-8") as tf:
        tf.write(config_text)
        cfg_path = tf.name
    try:
        t0 = time.perf_counter()
        proc = subprocess.run(
            [str(preflight_bin), cfg_path, target_host, "ProxyJump"],
            capture_output=True,
            text=True,
            check=False,
        )
        elapsed_ms = (time.perf_counter() - t0) * 1000.0
        out = ((proc.stdout or "") + (proc.stderr or "")).strip()
        return {
            "exit_code": proc.returncode,
            "ok": proc.returncode == 0,
            "output": out,
            "latency_ms": round(elapsed_ms, 3),
        }
    finally:
        try:
            os.unlink(cfg_path)
        except OSError:
            pass


def benchmark_c99_preflight(preflight_bin: Path, iterations: int = 100) -> Dict[str, Any]:
    """Measures C99 preflight binary latency and correctness over N runs."""
    samples: List[Tuple[str, Path, int]] = [
        ("ssh_config.buggy", REPO_DIR / "ssh_config.buggy", 1),
        ("ssh_config.fixed", REPO_DIR / "ssh_config.fixed", 0),
    ]
    results: Dict[str, Any] = {}
    for label, path, expected_rc in samples:
        latencies: List[float] = []
        last_out = ""
        all_matched = True
        for _ in range(iterations):
            t0 = time.perf_counter()
            proc = subprocess.run(
                [str(preflight_bin), str(path), "server2", "ProxyJump"],
                capture_output=True,
                text=True,
                check=False,
            )
            latencies.append((time.perf_counter() - t0) * 1000.0)
            last_out = ((proc.stdout or "") + (proc.stderr or "")).strip()
            if proc.returncode != expected_rc:
                all_matched = False
        latencies_sorted = sorted(latencies)
        results[label] = {
            "iterations": iterations,
            "expected_exit_code": expected_rc,
            "accuracy_100pct": all_matched,
            "output": last_out,
            "min_ms": round(min(latencies_sorted), 3),
            "median_ms": round(statistics.median(latencies_sorted), 3),
            "mean_ms": round(statistics.mean(latencies_sorted), 3),
            "p95_ms": round(latencies_sorted[int(0.95 * (len(latencies_sorted) - 1))], 3),
        }
    return results


class ClusterVerifier:
    """Runs `test_connection.sh` against a local or remote 4-VM QEMU blind workspace."""

    def __init__(
        self,
        qemu_ssh: Optional[str],
        qemu_ws: str,
        ssh_password: Optional[str],
        local_ws: Optional[str],
        dry_local_ssh_g: bool,
    ) -> None:
        self.qemu_ssh = qemu_ssh
        self.qemu_ws = qemu_ws.rstrip("/")
        self.ssh_password = ssh_password
        self.local_ws = Path(local_ws).resolve() if local_ws else None
        self.dry_local_ssh_g = dry_local_ssh_g

    def _run_remote_cmd(self, remote_cmd: str, stdin_data: Optional[str] = None) -> subprocess.CompletedProcess[str]:
        assert self.qemu_ssh is not None
        base_ssh = [
            "ssh",
            "-q",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "LogLevel=ERROR",
            "-o",
            "BatchMode=no" if self.ssh_password else "BatchMode=yes",
            self.qemu_ssh,
            remote_cmd,
        ]
        env = os.environ.copy()
        if self.ssh_password:
            sshpass_bin = shutil.which("sshpass")
            if not sshpass_bin:
                raise RuntimeError("QEMU_SSH_PASSWORD is set but `sshpass` is not installed.")
            env["SSHPASS"] = self.ssh_password
            cmd = [sshpass_bin, "-e"] + base_ssh
        else:
            cmd = base_ssh
        return subprocess.run(cmd, input=stdin_data, capture_output=True, text=True, env=env, timeout=45, check=False)

    def ensure_ready(self) -> str:
        if self.qemu_ssh:
            check = self._run_remote_cmd(f"test -x {self.qemu_ws}/test_connection.sh && test -f {self.qemu_ws}/.bridge/active && echo ACTIVE || echo INACTIVE")
            if "ACTIVE" not in (check.stdout or ""):
                raise RuntimeError(
                    f"Remote QEMU blind workspace at {self.qemu_ssh}:{self.qemu_ws} is not active. "
                    f"Start it first with `./retest.sh --prepare-blind {self.qemu_ws}` on the remote host."
                )
            return f"remote_qemu:{self.qemu_ssh}:{self.qemu_ws}"
        if self.local_ws:
            if not (self.local_ws / ".bridge" / "active").exists():
                raise RuntimeError(f"Local QEMU blind workspace at {self.local_ws} is not active.")
            return f"local_qemu:{self.local_ws}"
        if self.dry_local_ssh_g:
            return "local_ssh_g"
        raise RuntimeError("No verifier configured (use --qemu-ssh, --local-ws, or --verify-ssh-g).")

    def test_connection(self, config_text: str) -> Dict[str, Any]:
        t0 = time.perf_counter()
        if self.qemu_ssh:
            cmd = f"umask 077 && cat > {self.qemu_ws}/client/.ssh/config && chmod 600 {self.qemu_ws}/client/.ssh/config && {self.qemu_ws}/test_connection.sh"
            proc = self._run_remote_cmd(cmd, stdin_data=config_text)
            elapsed_ms = (time.perf_counter() - t0) * 1000.0
            combined = ((proc.stdout or "") + (proc.stderr or "")).strip()
            passed = proc.returncode == 0 and combined.splitlines()[-1].strip() == "server2" if combined else False
            return {
                "backend": "qemu_4vm_live",
                "exit_code": proc.returncode,
                "output": combined,
                "passed": passed,
                "latency_ms": round(elapsed_ms, 2),
            }
        if self.local_ws:
            cfg_file = self.local_ws / "client" / ".ssh" / "config"
            cfg_file.write_text(config_text, encoding="utf-8")
            os.chmod(cfg_file, 0o600)
            proc = subprocess.run(
                [str(self.local_ws / "test_connection.sh")],
                capture_output=True,
                text=True,
                timeout=35,
                check=False,
            )
            elapsed_ms = (time.perf_counter() - t0) * 1000.0
            combined = ((proc.stdout or "") + (proc.stderr or "")).strip()
            passed = proc.returncode == 0 and combined.strip() == "server2"
            return {
                "backend": "qemu_4vm_live_local",
                "exit_code": proc.returncode,
                "output": combined,
                "passed": passed,
                "latency_ms": round(elapsed_ms, 2),
            }

        # Fallback: OpenSSH `ssh -F ... -G server2` and `server3` simulation
        with tempfile.NamedTemporaryFile("w", suffix=".ssh_config", delete=False, encoding="utf-8") as tf:
            tf.write(config_text)
            cfg_path = tf.name
        try:
            p2 = subprocess.run(["ssh", "-F", cfg_path, "-G", "server2"], capture_output=True, text=True, check=False)
            p3 = subprocess.run(["ssh", "-F", cfg_path, "-G", "server3"], capture_output=True, text=True, check=False)
            p1 = subprocess.run(["ssh", "-F", cfg_path, "-G", "server1"], capture_output=True, text=True, check=False)
            pj2 = next((l.split(None, 1)[1] for l in p2.stdout.splitlines() if l.startswith("proxyjump ")), "none")
            pj3 = next((l.split(None, 1)[1] for l in p3.stdout.splitlines() if l.startswith("proxyjump ")), "none")
            pj1 = next((l.split(None, 1)[1] for l in p1.stdout.splitlines() if l.startswith("proxyjump ")), "none")
            elapsed_ms = (time.perf_counter() - t0) * 1000.0
            if pj2 == "server3" and pj3 == "server3":
                return {"backend": "ssh_g", "exit_code": 255, "output": "jumphost loop via server3", "passed": False, "latency_ms": round(elapsed_ms, 2)}
            ok = (pj2 == "server3" and pj3 == "server1" and pj1 == "none") or (pj2 in ("server1,server3",) and pj1 == "none")
            out = "server2" if ok else f"Connection failed (effective proxyjump: server2={pj2}, server3={pj3}, server1={pj1})"
            return {"backend": "ssh_g", "exit_code": 0 if ok else 255, "output": out, "passed": ok, "latency_ms": round(elapsed_ms, 2)}
        finally:
            try:
                os.unlink(cfg_path)
            except OSError:
                pass


def parse_stanzas(config_text: str) -> List[Dict[str, Any]]:
    stanzas: List[Dict[str, Any]] = []
    cur: Optional[Dict[str, Any]] = None
    for idx, line in enumerate(config_text.splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            if cur is not None:
                cur["raw_lines"].append((idx, line))
            continue
        m = re.match(r"^Host\s+(.+)$", stripped, flags=re.IGNORECASE)
        if m:
            if cur is not None:
                stanzas.append(cur)
            cur = {"host": m.group(1).strip(), "start_line": idx, "proxy_jumps": [], "raw_lines": [(idx, line)]}
        elif cur is not None:
            cur["raw_lines"].append((idx, line))
            pm = re.match(r"^ProxyJump\s+(.+)$", stripped, flags=re.IGNORECASE)
            if pm:
                cur["proxy_jumps"].append((idx, pm.group(1).strip()))
    if cur is not None:
        stanzas.append(cur)
    return stanzas


def analyze_stanza_locality_bias(prev_config: str, new_config: str) -> Dict[str, Any]:
    """Detects whether an edit modified a specific host stanza while earlier wildcard stanzas still shadow it."""
    prev_stanzas = parse_stanzas(prev_config)
    new_stanzas = parse_stanzas(new_config)

    def find_pj(stanzas: List[Dict[str, Any]], host_pat: str) -> Tuple[Optional[int], List[str]]:
        for pos, st in enumerate(stanzas):
            if st["host"] == host_pat:
                return pos, [val for _, val in st["proxy_jumps"]]
        return None, []

    def wildcard_pj_summary(stanzas: List[Dict[str, Any]], before_pos: Optional[int]) -> List[str]:
        out: List[str] = []
        limit = before_pos if before_pos is not None else len(stanzas)
        for pos, st in enumerate(stanzas[:limit]):
            pat = st["host"]
            if "*" in pat or "?" in pat or "!" in pat:
                for _, val in st["proxy_jumps"]:
                    out.append(f"{pat}:{val}")
        return out

    old_s2_pos, old_s2_pj = find_pj(prev_stanzas, "server2")
    new_s2_pos, new_s2_pj = find_pj(new_stanzas, "server2")
    old_s3_pos, old_s3_pj = find_pj(prev_stanzas, "server3")
    new_s3_pos, new_s3_pj = find_pj(new_stanzas, "server3")

    old_wild_pj = wildcard_pj_summary(prev_stanzas, old_s2_pos)
    new_wild_pj = wildcard_pj_summary(new_stanzas, new_s2_pos)

    star_shadows_s2 = len(new_wild_pj) > 0
    changed_specific = (old_s2_pj != new_s2_pj) or (old_s3_pj != new_s3_pj)
    changed_wild = old_wild_pj != new_wild_pj
    locality_biased_edit = bool(changed_specific and star_shadows_s2 and not changed_wild)
    return {
        "changed_server2_proxyjump": old_s2_pj != new_s2_pj,
        "changed_wildcard_or_order": changed_wild,
        "wildcard_still_shadows_server2": star_shadows_s2,
        "locality_biased_edit": locality_biased_edit,
        "wildcard_proxyjump": new_wild_pj,
        "server2_proxyjump": new_s2_pj,
    }


def apply_set_proxy_jump(config_text: str, host_pattern: str, proxy_jump: Optional[str]) -> Tuple[str, str]:
    """Stanza-scoped ProxyJump editor mimicking Ansible `ssh_config` / Augeas."""
    if proxy_jump is None or str(proxy_jump).strip() == "":
        return (
            config_text,
            "ERROR: `proxy_jump` requires a valid OpenSSH ProxyJump target (hostname, comma-separated host list, or 'none').",
        )
    lines = config_text.splitlines()
    in_target = False
    target_found = False
    target_start = -1
    target_end = len(lines)

    for i, line in enumerate(lines):
        stripped = line.strip()
        m = re.match(r"^Host\s+(.+)$", stripped, flags=re.IGNORECASE)
        if m:
            pat = m.group(1).strip()
            if in_target:
                target_end = i
                in_target = False
                break
            if pat == host_pattern:
                in_target = True
                target_found = True
                target_start = i

    if not target_found:
        return config_text, f"ERROR: Stanza 'Host {host_pattern}' not found in client/.ssh/config."

    new_block: List[str] = []
    pj_replaced = False
    for line in lines[target_start:target_end]:
        if re.match(r"^\s*ProxyJump\s+", line, flags=re.IGNORECASE):
            if not pj_replaced:
                new_block.append(f"    ProxyJump {proxy_jump.strip()}")
                pj_replaced = True
        else:
            new_block.append(line)

    if not pj_replaced:
        insert_at = len(new_block)
        while insert_at > 1 and new_block[insert_at - 1].strip() == "":
            insert_at -= 1
        new_block.insert(insert_at, f"    ProxyJump {proxy_jump.strip()}")

    updated = lines[:target_start] + new_block + lines[target_end:]
    new_text = "\n".join(updated) + "\n"
    msg = f"Set 'ProxyJump {proxy_jump.strip()}' inside stanza 'Host {host_pattern}'."
    return new_text, msg


def format_numbered_config(config_text: str) -> str:
    return "\n".join(f"{i:2d}: {line}" for i, line in enumerate(config_text.splitlines(), start=1))


def run_model_trial(
    cf_bin: str,
    model: str,
    mode: str,
    verifier: ClusterVerifier,
    preflight_bin: Path,
    max_turns: int,
) -> Dict[str, Any]:
    config_text = INITIAL_BLIND_CONFIG
    system_prompt = SYSTEM_PROMPT_FILE_EDIT if mode == "blind_file_edit" else SYSTEM_PROMPT_STANZA_SCOPED
    messages: List[Dict[str, str]] = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": TASK_PROMPT_BLIND},
    ]

    turns: List[Dict[str, Any]] = []
    total_prompt_tokens = 0
    total_completion_tokens = 0
    total_neurons = 0.0
    total_model_latency_ms = 0.0
    locality_bias_count = 0
    invalid_json_count = 0
    verified_on_qemu = False
    turns_to_solve: Optional[int] = None
    finished_by_model = False
    final_diagnosis = ""

    for turn_idx in range(1, max_turns + 1):
        resp = call_cf_model(cf_bin, model, messages)
        raw_content = resp["content"]
        action_obj = extract_action_json(raw_content, resp["reasoning"])
        if action_obj is None:
            # Retry once with slight temperature bump if model returned empty/truncated content
            retry_resp = call_cf_model(cf_bin, model, messages, temperature=0.2)
            for k in ("prompt_tokens", "completion_tokens", "total_tokens"):
                resp["usage"][k] = int(resp["usage"].get(k) or 0) + int(retry_resp["usage"].get(k) or 0)
            resp["usage"]["neurons"] = float(resp["usage"].get("neurons") or 0.0) + float(retry_resp["usage"].get("neurons") or 0.0)
            resp["latency_ms"] = round(float(resp["latency_ms"]) + float(retry_resp["latency_ms"]), 2)
            resp["content"] = retry_resp["content"]
            resp["reasoning"] = retry_resp["reasoning"]
            raw_content = resp["content"]
            action_obj = extract_action_json(raw_content, resp["reasoning"])

        usage = resp["usage"]
        total_prompt_tokens += int(usage.get("prompt_tokens") or 0)
        total_completion_tokens += int(usage.get("completion_tokens") or 0)
        total_neurons += float(usage.get("neurons") or 0.0)
        total_model_latency_ms += float(resp["latency_ms"])

        assistant_history_text = raw_content.strip() if raw_content and raw_content.strip() else (json.dumps(action_obj) if action_obj else "{}")
        messages.append({"role": "assistant", "content": assistant_history_text})
        turn_record: Dict[str, Any] = {
            "turn": turn_idx,
            "latency_ms": resp["latency_ms"],
            "usage": usage,
            "raw_content_preview": (raw_content or "")[:600],
            "reasoning_preview": (resp["reasoning"] or "")[:600],
            "action": action_obj,
        }

        if not action_obj:
            invalid_json_count += 1
            tool_reply = "FORMAT_ERROR: Your reply was not valid JSON with an 'action' field. Output ONLY one JSON object matching an allowed action."
            turn_record["tool_reply"] = tool_reply
            turns.append(turn_record)
            messages.append({"role": "user", "content": tool_reply})
            continue

        act = str(action_obj.get("action", "")).strip()
        bias_info: Optional[Dict[str, Any]] = None
        qemu_res: Optional[Dict[str, Any]] = None
        preflight_res: Optional[Dict[str, Any]] = None

        if act == "read_config":
            tool_reply = f"Contents of client/.ssh/config:\n{format_numbered_config(config_text)}"
        elif act == "reset_lab" and mode == "blind_file_edit":
            config_text = INITIAL_BLIND_CONFIG
            tool_reply = "[reset_lab] Restored client/.ssh/config to initial broken state."
        elif act == "edit_line" and mode == "blind_file_edit":
            old_t = str(action_obj.get("old_text", ""))
            new_t = str(action_obj.get("new_text", ""))
            matches = config_text.count(old_t) if old_t else 0
            if not old_t or matches == 0:
                tool_reply = "EDIT_ERROR: `old_text` was not found verbatim in client/.ssh/config. Call `read_config` to inspect exact lines."
            elif matches > 1:
                tool_reply = (
                    f"EDIT_ERROR: `old_text` matches {matches} locations in client/.ssh/config. "
                    "Include surrounding lines (such as the `Host ...` header) so `old_text` is unique."
                )
            else:
                new_cfg = config_text.replace(old_t, new_t, 1)
                bias_info = analyze_stanza_locality_bias(config_text, new_cfg)
                if bias_info["locality_biased_edit"]:
                    locality_bias_count += 1
                config_text = new_cfg
                preflight_res = run_c99_preflight(preflight_bin, config_text, "server2")
                tool_reply = f"EDIT_OK: Updated client/.ssh/config ({len(config_text.splitlines())} lines). Run `test_connection` to verify."
        elif act == "set_proxy_jump" and mode == "stanza_scoped_tool":
            host_pat = str(action_obj.get("host", "")).strip()
            pj_val = action_obj.get("proxy_jump")
            pj_str = None if pj_val is None else str(pj_val)
            new_cfg, op_msg = apply_set_proxy_jump(config_text, host_pat, pj_str)
            bias_info = analyze_stanza_locality_bias(config_text, new_cfg)
            if bias_info["locality_biased_edit"]:
                locality_bias_count += 1
            config_text = new_cfg
            preflight_res = run_c99_preflight(preflight_bin, config_text, "server2")
            tool_reply = f"{op_msg}\nRun `test_connection` to verify."
        elif act == "test_connection":
            qemu_res = verifier.test_connection(config_text)
            preflight_res = run_c99_preflight(preflight_bin, config_text, "server2")
            tool_reply = (
                f"./test_connection.sh exited with code {qemu_res['exit_code']}:\n"
                f"{qemu_res['output']}"
            )
            if qemu_res["passed"] and preflight_res["ok"] and turns_to_solve is None:
                verified_on_qemu = True
                turns_to_solve = turn_idx
        elif act == "done":
            finished_by_model = True
            final_diagnosis = str(action_obj.get("diagnosis", "") or action_obj.get("summary", ""))
            qemu_res = verifier.test_connection(config_text)
            preflight_res = run_c99_preflight(preflight_bin, config_text, "server2")
            if qemu_res["passed"] and preflight_res["ok"]:
                verified_on_qemu = True
                if turns_to_solve is None:
                    turns_to_solve = turn_idx
                tool_reply = "Session completed."
                turn_record["qemu_check"] = qemu_res
                turn_record["c99_preflight_shadow"] = preflight_res
                turn_record["tool_reply"] = tool_reply
                turns.append(turn_record)
                break
            else:
                finished_by_model = False
                tool_reply = (
                    f"NOT_VERIFIED: test_connection still fails (exit {qemu_res['exit_code']}): "
                    f"{qemu_res['output']}. Keep diagnosing and fixing client/.ssh/config."
                )
        else:
            tool_reply = f"UNKNOWN_ACTION: '{act}' is not valid in mode '{mode}'. Use only listed JSON actions."

        if bias_info is not None:
            turn_record["locality_analysis"] = bias_info
        if qemu_res is not None:
            turn_record["qemu_check"] = qemu_res
        if preflight_res is not None:
            turn_record["c99_preflight_shadow"] = preflight_res
        turn_record["tool_reply"] = tool_reply
        turns.append(turn_record)
        messages.append({"role": "user", "content": tool_reply})

    # Post-trial authoritative verification against both QEMU and C99 Preflight (server2 & server3)
    final_qemu = verifier.test_connection(config_text)
    final_pre_s2 = run_c99_preflight(preflight_bin, config_text, "server2")
    final_pre_s3 = run_c99_preflight(preflight_bin, config_text, "server3")
    passed = bool(final_qemu["passed"] and final_pre_s2["ok"])

    diag_corpus = final_diagnosis + " " + " ".join(
        (t.get("reasoning_preview", "") + " " + t.get("raw_content_preview", "")) for t in turns
    )
    identified_first_match = bool(
        re.search(r"first[- ]match|Host \*|wildcard|precedence|shadows|shadowed", diag_corpus, re.IGNORECASE)
    )

    return {
        "model": model,
        "mode": mode,
        "max_turns": max_turns,
        "turns_taken": len(turns),
        "turns_to_solve": turns_to_solve,
        "passed": passed,
        "finished_by_model": finished_by_model,
        "verified_on_qemu": verified_on_qemu,
        "stanza_locality_bias_observed": locality_bias_count > 0,
        "locality_biased_edits": locality_bias_count,
        "invalid_json_turns": invalid_json_count,
        "identified_precedence_root_cause": identified_first_match,
        "final_diagnosis": final_diagnosis,
        "final_qemu": final_qemu,
        "final_c99_preflight_server2": final_pre_s2,
        "final_c99_preflight_server3": final_pre_s3,
        "final_config": config_text,
        "totals": {
            "prompt_tokens": total_prompt_tokens,
            "completion_tokens": total_completion_tokens,
            "total_tokens": total_prompt_tokens + total_completion_tokens,
            "neurons": round(total_neurons, 4),
            "model_latency_ms": round(total_model_latency_ms, 2),
        },
        "turns": turns,
    }


def render_markdown_report(report: Dict[str, Any]) -> str:
    lines: List[str] = []
    lines.append("# Cloudflare Workers AI 4-Model Benchmark Results (Instance 12)")
    lines.append("")
    lines.append(f"- **Timestamp (UTC)**: `{report['timestamp_utc']}`")
    lines.append(f"- **Verification Backend**: `{report['verifier_backend']}`")
    lines.append(f"- **Models Tested**: {len(report['models'])}")
    lines.append("")

    c99 = report["c99_preflight_benchmark"]
    lines.append("## 1. Deterministic C99 Preflight Checker (`check_client_precedence.c`) Baseline")
    lines.append("")
    lines.append("| Fixture | Iterations | Expected Exit | 100% Accurate | Min (ms) | Median (ms) | p95 (ms) | Output |")
    lines.append("| :--- | ---: | ---: | :--- | ---: | ---: | ---: | :--- |")
    for label, stats in c99.items():
        out_lines = [ln.strip() for ln in stats["output"].splitlines() if ln.strip()]
        summary_out = out_lines[0] + (f" (+{len(out_lines) - 1} more violations)" if len(out_lines) > 1 else "") if out_lines else ""
        lines.append(
            f"| `{label}` | {stats['iterations']} | `{stats['expected_exit_code']}` | "
            f"{'Yes' if stats['accuracy_100pct'] else 'No'} | {stats['min_ms']:.3f} | "
            f"{stats['median_ms']:.3f} | {stats['p95_ms']:.3f} | `{summary_out}` |"
        )
    lines.append("")

    lines.append("## 2. Cloudflare Workers AI 4-Model Matrix")
    lines.append("")
    lines.append("| Model | Mode | Pass (QEMU + C99) | Turns Used | Solved At Turn | Locality-Biased Edits | Tokens (In / Out) | Neurons | Total LLM Latency |")
    lines.append("| :--- | :--- | :--- | ---: | ---: | ---: | :--- | ---: | ---: |")
    for r in report["trials"]:
        tot = r["totals"]
        solved = str(r["turns_to_solve"]) if r["turns_to_solve"] is not None else "—"
        status = "**PASS**" if r["passed"] else "**FAIL**"
        lines.append(
            f"| `{r['model']}` | `{r['mode']}` | {status} | {r['turns_taken']}/{r['max_turns']} | {solved} | "
            f"{r['locality_biased_edits']} | {tot['prompt_tokens']} / {tot['completion_tokens']} | "
            f"{tot['neurons']:.2f} | {tot['model_latency_ms'] / 1000.0:.2f}s |"
        )
    lines.append("")

    lines.append("## 3. Turn-by-Turn Detailed Traces")
    lines.append("")
    for r in report["trials"]:
        status = "PASS" if r["passed"] else "FAIL"
        fq_out = " / ".join(ln.strip() for ln in r["final_qemu"]["output"].splitlines() if ln.strip())[:160]
        fp_lines = [ln.strip() for ln in r["final_c99_preflight_server2"]["output"].splitlines() if ln.strip()]
        fp_out = fp_lines[0] + (f" (+{len(fp_lines) - 1} more)" if len(fp_lines) > 1 else "") if fp_lines else ""
        lines.append(f"### `{r['model']}` — `{r['mode']}` ({status})")
        lines.append("")
        lines.append(f"- **Identified Precedence Root Cause (`Host *` / first-match)**: `{r['identified_precedence_root_cause']}`")
        lines.append(f"- **Stanza Locality Bias Observed**: `{r['stanza_locality_bias_observed']}` ({r['locality_biased_edits']} biased edits)")
        lines.append(f"- **Final QEMU Check**: exit `{r['final_qemu']['exit_code']}` -> `{fq_out}`")
        lines.append(f"- **Final C99 Preflight (`server2`)**: exit `{r['final_c99_preflight_server2']['exit_code']}` -> `{fp_out}`")
        lines.append("")
        for t in r["turns"]:
            act_json = json.dumps(t["action"]) if t.get("action") else "INVALID_JSON"
            extra = []
            if t.get("locality_analysis", {}).get("locality_biased_edit"):
                extra.append("LOCALITY_BIASED_EDIT")
            if "qemu_check" in t:
                qc = t["qemu_check"]
                qc_one = " / ".join(ln.strip() for ln in qc["output"].splitlines() if ln.strip())[:70]
                extra.append(f"QEMU(rc={qc['exit_code']}, {qc_one})")
            if "c99_preflight_shadow" in t:
                cp = t["c99_preflight_shadow"]
                cp_cnt = len([ln for ln in cp["output"].splitlines() if "PREFLIGHT VIOLATION" in ln])
                extra.append(f"C99(rc={cp['exit_code']}, violations={cp_cnt})")
            extra_str = f" — {' | '.join(extra)}" if extra else ""
            lines.append(f"- **Turn {t['turn']}** ({t['latency_ms']:.0f}ms): `{act_json}`{extra_str}")
        lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Benchmark 4 Cloudflare Workers AI models on Instance 12 SSH Precedence.")
    parser.add_argument("--cf-bin", default=shutil.which("cf") or "/opt/homebrew/bin/cf", help="Path to Cloudflare `cf` CLI.")
    parser.add_argument("--env-file", help="Optional env file holding CLOUDFLARE_ACCOUNT_ID / CLOUDFLARE_API_TOKEN.")
    parser.add_argument("--models", nargs="+", default=DEFAULT_MODELS, help="Cloudflare Workers AI model IDs to test.")
    parser.add_argument("--modes", nargs="+", default=["blind_file_edit", "stanza_scoped_tool"], choices=["blind_file_edit", "stanza_scoped_tool"])
    parser.add_argument("--qemu-ssh", help="Remote SSH target hosting active QEMU cluster (e.g. agent1@159.195.249.30).")
    parser.add_argument("--qemu-ws", default="/tmp/ssh-wildcard-blind", help="Blind workspace path on QEMU host.")
    parser.add_argument("--ssh-password-env", default="QEMU_SSH_PASSWORD", help="Env var holding SSH password if sshpass is needed.")
    parser.add_argument("--local-ws", help="Local QEMU blind workspace path if running directly on Linux host.")
    parser.add_argument("--verify-ssh-g", action="store_true", help="Fallback to local `ssh -F ... -G` verification if QEMU is unavailable.")
    parser.add_argument("--max-turns-edit", type=int, default=8)
    parser.add_argument("--max-turns-scoped", type=int, default=6)
    parser.add_argument("--out-dir", default=str(REPO_DIR / "results"))
    args = parser.parse_args()

    if args.env_file:
        load_env_file(Path(args.env_file))

    if not os.environ.get("CLOUDFLARE_ACCOUNT_ID") or not os.environ.get("CLOUDFLARE_API_TOKEN"):
        print("ERROR: CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN must be set.", file=sys.stderr)
        return 2

    if not Path(args.cf_bin).exists():
        print(f"ERROR: cf CLI not found at {args.cf_bin}", file=sys.stderr)
        return 2

    preflight_bin = compile_preflight()
    c99_stats = benchmark_c99_preflight(preflight_bin, iterations=100)

    ssh_password = os.environ.get(args.ssh_password_env) if args.ssh_password_env else None
    verifier = ClusterVerifier(
        qemu_ssh=args.qemu_ssh,
        qemu_ws=args.qemu_ws,
        ssh_password=ssh_password,
        local_ws=args.local_ws,
        dry_local_ssh_g=args.verify_ssh_g,
    )
    backend_desc = verifier.ensure_ready()
    print(f"[eval] Verifier ready: {backend_desc}", flush=True)
    print(f"[eval] C99 Preflight median latency (buggy): {c99_stats['ssh_config.buggy']['median_ms']:.3f} ms", flush=True)

    trials: List[Dict[str, Any]] = []
    for model in args.models:
        for mode in args.modes:
            max_turns = args.max_turns_edit if mode == "blind_file_edit" else args.max_turns_scoped
            print(f"[eval] Running {model} [{mode}, max_turns={max_turns}] ...", flush=True)
            trial = run_model_trial(
                cf_bin=args.cf_bin,
                model=model,
                mode=mode,
                verifier=verifier,
                preflight_bin=preflight_bin,
                max_turns=max_turns,
            )
            trials.append(trial)
            print(
                f"[eval]   -> {'PASS' if trial['passed'] else 'FAIL'} "
                f"(turns={trial['turns_taken']}/{trial['max_turns']}, "
                f"biased_edits={trial['locality_biased_edits']}, "
                f"tokens={trial['totals']['total_tokens']}, "
                f"neurons={trial['totals']['neurons']})",
                flush=True,
            )

    report = {
        "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "verifier_backend": backend_desc,
        "models": args.models,
        "modes": args.modes,
        "c99_preflight_benchmark": c99_stats,
        "trials": trials,
    }

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    json_path = out_dir / "cloudflare_4models_results.json"
    md_path = out_dir / "CLOUDFLARE_BENCHMARK_RESULTS.md"
    json_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
    md_path.write_text(render_markdown_report(report), encoding="utf-8")
    print(f"[eval] Wrote {json_path} and {md_path}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
