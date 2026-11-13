# Instance 12: OpenSSH Wildcard Precedence Override Benchmark

A minimal, reproducible benchmark fixture demonstrating **Type III Configuration Precedence Blindness** in Large Language Model (LLM) agents (OpenAI GPT-4o / GPT-5 / Luna and Google Gemini 1.5 / 2.0 / Argon).

---

## Quick Retest with Codex, Gemini-CLI, or Claude Code

Anyone can clone and retest this benchmark—or evaluate another coding agent against a live 4-VM QEMU cluster—with a single prompt or command:

### Option A: One-Prompt Retest Inside Any Coding Agent CLI
Point `codex`, `gemini`, `claude`, or `agy` at this repository and ask:
> *"Retest the problem described in repo `https://github.com/thealgebraist/ssh-wildcard-precedence-benchmark`"*

Agent entrypoints ([`AGENTS.md`](AGENTS.md), [`GEMINI.md`](GEMINI.md), [`CLAUDE.md`](CLAUDE.md)) automatically direct the tool to run [`./retest.sh`](retest.sh).

### Option B: Benchmark an Agent in a Spoiler-Free Sandbox Workspace
Because this repo documents the root cause, use [`setup_blind_workspace.sh`](setup_blind_workspace.sh) / [`retest.sh`](retest.sh) to spawn an isolated workspace (`/tmp/ssh-wildcard-blind`) connected to a live 4-VM QEMU cluster (`wc-client -> server1 -> server3 -> server2`) over a sandbox-safe file relay (`.bridge/` — works even inside `codex -s workspace-write` without network or Docker access):

```bash
# Automated blind evaluation comparing an AI agent vs C99 preflight:
./retest.sh --run-agent codex     # or: gemini, claude

# Optional model override:
AGENT_MODEL=o3 ./retest.sh --run-agent codex

# Or prepare the blind workspace manually for interactive CLI runs:
./retest.sh --prepare-blind /tmp/ssh-wildcard-blind
cat /tmp/ssh-wildcard-blind/PROMPT.txt
# Run your CLI tool inside /tmp/ssh-wildcard-blind, then clean up:
./retest.sh --teardown /tmp/ssh-wildcard-blind
```

### Option C: Full Automated Verification (No Agent Calls)
```bash
./retest.sh
```
Runs `reproduce.sh` (`ssh -G` + C99 preflight) and, on Linux hosts with `qemu-system-x86_64`, runs the blind-workspace + 4-VM QEMU cluster E2E check.

---

## 1. Problem Description

OpenSSH parses `ssh_config(5)` with a strict **first-match-wins** evaluation rule:
> *"For each parameter, the first obtained value will be used."*

In the hardened Instance 12 configuration ([`ssh_config.buggy`](ssh_config.buggy), 58 lines), five overlapping precedence layers and a decoy bastion stanza interact before the per-host stanzas (`Host server1`, `Host server3`, `Host server2`):
1. **`Host bastion-gateway`**: Decoy stanza pointing at `10.202.1.3` (`server1`'s IP), tempting agents to route `server2` directly through `bastion-gateway` (bypassing `server3`, which fails with `stdio forwarding failed` because `server2` at `10.202.32.2` is isolated on `server3`'s second subnet).
2. **`Host !server1 server*`**: Negated wildcard pattern matching `server3` and `server2` (but not `server1`), locking `ProxyJump server3` and causing `jumphost loop via server3`.
3. **`Host *.compute.internal server?`**: Single-character glob `server?` matching `server1`, `server2`, and `server3`, locking `ProxyJump server1:2222` (causing `jumphost loop via server1` on the ingress jump host) and `User root` (shadowing `User deploy` on all three servers, causing `Permission denied (publickey)`).
4. **`Host *1 *2`**: Suffix wildcard matching `server1` and `server2`, locking `ProxyJump server2:2222` (causing `jumphost loop via server2`) and `Port 2222` (shadowing `Port 22` on `server1` and `server2`, causing `Connection refused`).
5. **`Host server2` Local Routing Defect**: Specifies `ProxyJump server1` at line 58 instead of `ProxyJump server3` (so even after all wildcard overrides are removed, `server2` still fails with `stdio forwarding failed` until updated to `ProxyJump server3`).

### The Autonomous Agent Cognitive Trap
When LLM agents encounter `jumphost loop via server3`:
- **Stanza Locality Bias**: Agents edit `Host server2` or `Host server3` at the bottom of the file, or call `set_proxy_jump` on `server2`, which has zero operational effect while earlier wildcard stanzas remain active.
- **Partial Unpeeling & Decoy Routing**: Even models that recognize `Host !server1 server*` or `Host *1 *2` get trapped by `server?` (`User root` / `ProxyJump server1:2222`), `Port 2222`, or route through the decoy `bastion-gateway` (`stdio forwarding failed`), resulting in a **100% failure rate (8/8 trials)** across all 4 tested Cloudflare Workers AI models.

---

## 2. Quickstart Reproduction

### Prerequisites
- Clang or GCC (C99 compiler)
- OpenSSH client (`ssh`)
- Bash

### One-Command Reproduction
```bash
./reproduce.sh
```

### Manual OpenSSH Verification
```bash
# Observe that OpenSSH resolves server2's ProxyJump to server3 (ignoring Host server2):
ssh -F ssh_config.buggy -G server2 | grep '^proxyjump '
# Output: proxyjump server3

# Observe resolved ProxyJump after fix (wc-client -> server1 -> server3 -> server2):
ssh -F ssh_config.fixed -G server2 | grep '^proxyjump '
# Output: proxyjump server3
ssh -F ssh_config.fixed -G server3 | grep '^proxyjump '
# Output: proxyjump server1
```

---

## 3. C99 Deterministic Preflight Checker

Compile the standalone C99 checker (implements full OpenSSH `Host` pattern list matching including `*`, `?`, and `!negation`, plus multi-hop `ProxyJump`, `Port`, `User`, and `ProxyCommand` shadowing detection):
```bash
clang -std=c99 -Wall -Wextra check_client_precedence.c -o check_client_precedence
```

Run checker against buggy config:
```bash
./check_client_precedence ssh_config.buggy server2 ProxyJump
# Output: [PREFLIGHT VIOLATION 1] Directive 'User' for host 'server1' (line 45, val: 'deploy') is completely SHADOWED by earlier 'Host *.compute.internal server?' at line 31 (val: 'root') (+13 more violations)
# Exit code: 1
```

Run checker against fixed config:
```bash
./check_client_precedence ssh_config.fixed server2 ProxyJump
# Output: [PREFLIGHT OK] Directive 'ProxyJump' and multi-hop chain (server1 -> server3 -> server2) for 'server2' have valid evaluation precedence.
# Exit code: 0
```

---

## 4. Full 4-VM QEMU Cluster Test Suite (Unprivileged, No-KVM TCG Compatible)

The `qemu/` directory provides an unprivileged, rootless 4-VM QEMU topology (`wc-client -> server1 -> server3 -> server2`) using real OpenSSH (`sshd` / `ssh`), `busybox`, and the host Linux kernel + virtio/9p drivers:

- [`qemu/build_initramfs.sh`](qemu/build_initramfs.sh): Builds a minimal `initramfs.cpio.gz` (`9.2M`) bundling OpenSSH binaries, BusyBox, NSS libraries, and `virtio_net`/`virtio-rng`/`9p` modules.
- [`qemu/qemu_cluster.sh`](qemu/qemu_cluster.sh): Boots or tears down all 4 QEMU VMs (`up`, `down`, `reset`, `status`) interconnected via point-to-point `-netdev socket` Ethernet links, with a `-virtfs` 9p hostshare mounting `qemu/client/.ssh` into `wc-client`. Uses KVM if available or falls back to `-accel tcg -cpu max`.
- [`qemu/test_connection.sh`](qemu/test_connection.sh): Executes `ssh -o ConnectTimeout=6 server2 hostname` inside `wc-client` via its management SSH port (`17100`).
- [`qemu/run_qemu_e2e_test.sh`](qemu/run_qemu_e2e_test.sh): Runs all 5 end-to-end verification stages (boot buggy cluster, observe `jumphost loop via server3`, catch violation via C99 preflight, apply minimal fix, verify preflight OK, confirm 4-hop `ssh server2 hostname` returns `server2`).

### Running the QEMU E2E Test (Linux Host)
Prerequisites on Debian/Ubuntu: `qemu-system-x86`, `busybox-static`, `openssh-server`, `openssh-client`, `gcc` or `clang`, readable `/boot/vmlinuz-$(uname -r)` and `/lib/modules/$(uname -r)`.

```bash
./qemu/run_qemu_e2e_test.sh
```

### Verified Run on `v2202609375901513183.ultrasrv.de` (`159.195.249.30`, unprivileged `agent1`, TCG mode, kernel `6.12.111+deb13-amd64`)
- **Step 1 (Buggy 4-VM cluster)**: `test_connection.sh` exited `255` with `jumphost loop via server3`.
- **Step 2 (C99 Preflight on buggy config)**: `check_client_precedence` exited `1` with `[PREFLIGHT VIOLATION 1] Directive 'ProxyJump' for host 'server2' is completely SHADOWED by earlier 'Host *' at line 10 (val: 'server3')`.
- **Step 3 & 4 (Minimal fix & C99 Preflight)**: Removing `ProxyJump server3` from `Host *` yields `[PREFLIGHT OK]` (`exit 0`).
- **Step 5 (Fixed 4-VM cluster)**: `test_connection.sh` traversed `wc-client -> server1 -> server3 -> server2` and printed `server2` (`exit 0`).

---

## 5. Cloudflare Workers AI 4-Model Empirical Evaluation vs. C99 Preflight (`eval_cloudflare_models.py`)

Evaluated [`eval_cloudflare_models.py`](eval_cloudflare_models.py) via `cf ai run` across 4 Cloudflare Workers AI models on both spoiler-free blind regimes (`blind_file_edit` and `stanza_scoped_tool`), backed by the live 4-VM QEMU cluster (`159.195.249.30:/tmp/ssh-wildcard-blind`) and [`check_client_precedence.c`](check_client_precedence.c) (full traces in [`results/CLOUDFLARE_BENCHMARK_RESULTS.md`](results/CLOUDFLARE_BENCHMARK_RESULTS.md) and [`results/cloudflare_4models_results.json`](results/cloudflare_4models_results.json)):

### Re-Running with Your Cloudflare Credentials
```bash
export CLOUDFLARE_ACCOUNT_ID="<your-account-id>"
export CLOUDFLARE_API_TOKEN="<your-api-token>"
export QEMU_SSH_PASSWORD="<ssh-pass-if-needed>"
python3 eval_cloudflare_models.py --qemu-ssh agent1@<linux-host> --qemu-ws /tmp/ssh-wildcard-blind --ssh-password-env QEMU_SSH_PASSWORD
```

### Empirical Results on Hardened 5-Layer Benchmark (2026-11-13T22:13:51Z)

| Model / Verifier | Mode | Result (QEMU + C99) | Turns Used | Solved At Turn | Locality-Biased Edits | Tokens (In / Out) | Neurons | Total Time |
| :--- | :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| `check_client_precedence` (C99) | Static Preflight (100 runs) | **PASS** (100% accurate, 14 violations caught) | — | Deterministic | 0 | 0 / 0 | 0 | **2.441–2.448 ms** (median) |
| `@cf/openai/gpt-oss-120b` | `blind_file_edit` | **FAIL** (`jumphost loop via server1`) | 8/8 | — | 0 | 9435 / 5745 | 691.91 | 113.89s |
| `@cf/openai/gpt-oss-120b` | `stanza_scoped_tool` | **FAIL** (`stdio forwarding failed`) | 6/6 | — | 1 | 6099 / 2853 | 388.58 | 56.93s |
| `@cf/google/gemma-4-26b-a4b-it` | `blind_file_edit` | **FAIL** (`jumphost loop via server3`) | 8/8 | — | 0 | 13172 / 203 | 120.05 | 9.68s |
| `@cf/google/gemma-4-26b-a4b-it` | `stanza_scoped_tool` | **FAIL** (`jumphost loop via server3`) | 6/6 | — | 1 | 7763 / 131 | 74.15 | 33.36s |
| `@cf/qwen/qwen2.5-coder-32b-instruct` | `blind_file_edit` | **FAIL** (`jumphost loop via server3`) | 8/8 | — | 2 | 10076 / 214 | 624.01 | 10.85s |
| `@cf/qwen/qwen2.5-coder-32b-instruct` | `stanza_scoped_tool` | **FAIL** (`jumphost loop via server3`) | 6/6 | — | 3 | 6154 / 102 | 378.51 | 5.95s |
| `@cf/meta/llama-3.3-70b-instruct-fp8-fast` | `blind_file_edit` | **FAIL** (`stdio forwarding failed`) | 8/8 | — | 0 | 8335 / 176 | 258.32 | 26.10s |
| `@cf/meta/llama-3.3-70b-instruct-fp8-fast` | `stanza_scoped_tool` | **FAIL** (`Connection timed out`) | 6/6 | — | 2 | 5848 / 97 | 175.82 | 19.41s |

### Key Empirical Findings
- **100% Failure Rate Across All 4 Models (8/8 Trials)**: When multi-layered OpenSSH wildcard patterns (`!server1 server*`, `*.compute.internal server?`, `*1 *2`) shadow `ProxyJump`, `Port`, and `User` simultaneously alongside a decoy `bastion-gateway` stanza and a local `Host server2` jump defect, **every model failed in both evaluation modes**.
- **Distinct Failure Signatures in Live 4-VM QEMU**:
  - `@cf/openai/gpt-oss-120b` unpeeled `Host *1 *2` and `Host !server1 server*` (`!server1 !server3 server*`), only to get trapped by `Host *.compute.internal server?` (`jumphost loop via server1`).
  - `@cf/google/gemma-4-26b-a4b-it` and `@cf/meta/llama-3.3-70b-instruct-fp8-fast` routed `Host !server1 server*` through the decoy `bastion-gateway` (`stdio forwarding failed`), and in `stanza_scoped_tool` `llama-3.3-70b` set `ProxyJump none` on `!server1 server*`, locking a direct connection to isolated `server2:2222` (`Connection timed out`).
  - `@cf/qwen/qwen2.5-coder-32b-instruct` exhibited pure **Stanza Locality Bias** across both modes (5 locality-biased edits on `Host server2` / `Host server3`), never touching the shadowing wildcard stanzas (`jumphost loop via server3`).
- **Deterministic C99 Preflight (`check_client_precedence.c`)**: Caught all 14 shadowing and routing violations on `ssh_config.buggy` and every broken intermediate model config in **`2.448 ms` median latency** with **0 tokens** and **100% accuracy**.
---

## 6. Benchmark Evaluation & Tickets

This repository contains tracking tickets for testing autonomous models:
- [Issue #1 / `tickets/TICKET-OPENAI.md`](tickets/TICKET-OPENAI.md): OpenAI Model Evaluation (`@cf/openai/gpt-oss-120b` tested, GPT-4o, o1, o3, Luna)
- [Issue #2 / `tickets/TICKET-GOOGLE.md`](tickets/TICKET-GOOGLE.md): Google Gemini/Gemma Evaluation (`@cf/google/gemma-4-26b-a4b-it` tested, Gemini 1.5 Pro, 2.0 Flash, Argon)
- [Issue #3 / `tickets/TICKET-ANTHROPIC-OPENSOURCE.md`](tickets/TICKET-ANTHROPIC-OPENSOURCE.md): Anthropic & Open Source Evaluation (`@cf/qwen/qwen2.5-coder-32b-instruct` & `@cf/meta/llama-3.3-70b-instruct-fp8-fast` tested, Claude, DeepSeek)
- [Issue #4 / `tickets/TICKET-C99-PREFLIGHT.md`](tickets/TICKET-C99-PREFLIGHT.md): Deterministic C99 Preflight Checker vs Stochastic LLMs
