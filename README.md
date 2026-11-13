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

When a wildcard stanza `Host *` appears before host-specific stanzas (e.g., `Host server2`) and declares a routing directive like `ProxyJump server3`:
1. Any connection to `server2` matches `Host *` first.
2. OpenSSH sets `ProxyJump = server3` and permanently locks the parameter.
3. The subsequent `Host server2` stanza with `ProxyJump server1` is discarded by the OpenSSH parser.
4. If `server3` itself jumps through `server1` or `server2`, this creates a cyclic jump loop (`jumphost loop via server3`).

### The Autonomous Agent Cognitive Trap
When LLM agents encounter `jumphost loop via server3`:
- They search for the `Host server2` stanza.
- They assume directives for `server2` are scoped locally inside that block.
- They repeatedly invoke repair tools to set `ProxyJump server1` under `Host server2`.
- Since OpenSSH ignores the later block, the edit has zero operational effect, leading to 100% failure rate over multi-turn diagnosis.

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

# Observe resolved ProxyJump after fix:
ssh -F ssh_config.fixed -G server2 | grep '^proxyjump '
# Output: proxyjump server1
```

---

## 3. C99 Deterministic Preflight Checker

Compile the standalone C99 checker:
```bash
clang -std=c99 -Wall -Wextra check_client_precedence.c -o check_client_precedence
```

Run checker against buggy config:
```bash
./check_client_precedence ssh_config.buggy server2 ProxyJump
# Output: [PREFLIGHT VIOLATION 1] Directive 'ProxyJump' for host 'server2' is completely SHADOWED by earlier 'Host *' at line 7 (val: 'server3')
# Exit code: 1
```

Run checker against fixed config:
```bash
./check_client_precedence ssh_config.fixed server2 ProxyJump
# Output: [PREFLIGHT OK] Directive 'ProxyJump' for host 'server2' has valid evaluation precedence.
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

### Empirical Results (2026-11-13T21:20:10Z)

| Model / Verifier | Mode | Result (QEMU + C99) | Turns Used | Solved At Turn | Locality-Biased Edits | Tokens (In / Out) | Neurons | Total Time |
| :--- | :--- | :--- | ---: | ---: | ---: | :--- | ---: | ---: |
| `check_client_precedence` (C99) | Static Preflight (100 runs) | **PASS** (100% accurate) | — | Deterministic | 0 | 0 / 0 | 0 | **2.41–2.44 ms** (median) |
| `@cf/google/gemma-4-26b-a4b-it` | `blind_file_edit` | **PASS** | 4/8 | 3 | 0 | 2997 / 2726 | 101.59 | 61.03s |
| `@cf/google/gemma-4-26b-a4b-it` | `stanza_scoped_tool` | **PASS** | 4/6 | 3 | 0 | 3024 / 2495 | 95.54 | 44.72s |
| `@cf/openai/gpt-oss-120b` | `blind_file_edit` | **PASS** | 8/8 | 8 | 0 | 6573 / 3454 | 444.64 | 58.25s |
| `@cf/openai/gpt-oss-120b` | `stanza_scoped_tool` | **PASS** | 5/6 | 4 | 0 | 3612 / 519 | 150.31 | 6.99s |
| `@cf/meta/llama-3.3-70b-instruct-fp8-fast` | `blind_file_edit` | **PASS** | 8/8 | 7 | 0 | 6762 / 136 | 208.18 | 9.45s |
| `@cf/meta/llama-3.3-70b-instruct-fp8-fast` | `stanza_scoped_tool` | **PASS** | 4/6 | 3 | 0 | 2774 / 75 | 89.34 | 4.51s |
| `@cf/qwen/qwen2.5-coder-32b-instruct` | `blind_file_edit` | **FAIL** (`fork failed`) | 8/8 | — | 0 | 6509 / 138 | 403.09 | 8.33s |
| `@cf/qwen/qwen2.5-coder-32b-instruct` | `stanza_scoped_tool` | **FAIL** (`jumphost loop via server3`) | 6/6 | — | 1 | 4478 / 94 | 277.23 | 5.65s |

### Key Empirical Findings
- **3 of 4 Cloudflare models solved both modes** (`gemma-4-26b-a4b-it`, `gpt-oss-120b`, and `llama-3.3-70b-instruct-fp8-fast`) once real OpenSSH error feedback (`jumphost loop via server3` / `server1`) was returned from live QEMU VMs.
- **`@cf/qwen/qwen2.5-coder-32b-instruct` failed both modes**: in `stanza_scoped_tool`, it fell straight into **Stanza Locality Bias** (`set_proxy_jump` on `server2` -> `server1`, then `server3` -> `""` -> `server1`), leaving `Host *` untouched (`C99 exit 1`, `QEMU jumphost loop via server3`); in `blind_file_edit`, it swapped `ProxyJump` inside `Host *` to recursive `ProxyCommand ssh -W %h:%p server1/server3`, triggering `fork failed: Resource temporarily unavailable` in `wc-client` (which also bypassed C99 `ProxyJump`-only checking, highlighting why live QEMU execution complements static preflight checks).

---

## 6. Benchmark Evaluation & Tickets

This repository contains tracking tickets for testing autonomous models:
- [Issue #1 / `tickets/TICKET-OPENAI.md`](tickets/TICKET-OPENAI.md): OpenAI Model Evaluation (`@cf/openai/gpt-oss-120b` tested, GPT-4o, o1, o3, Luna)
- [Issue #2 / `tickets/TICKET-GOOGLE.md`](tickets/TICKET-GOOGLE.md): Google Gemini/Gemma Evaluation (`@cf/google/gemma-4-26b-a4b-it` tested, Gemini 1.5 Pro, 2.0 Flash, Argon)
- [Issue #3 / `tickets/TICKET-ANTHROPIC-OPENSOURCE.md`](tickets/TICKET-ANTHROPIC-OPENSOURCE.md): Anthropic & Open Source Evaluation (`@cf/qwen/qwen2.5-coder-32b-instruct` & `@cf/meta/llama-3.3-70b-instruct-fp8-fast` tested, Claude, DeepSeek)
- [Issue #4 / `tickets/TICKET-C99-PREFLIGHT.md`](tickets/TICKET-C99-PREFLIGHT.md): Deterministic C99 Preflight Checker vs Stochastic LLMs
