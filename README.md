# Instance 12: OpenSSH Wildcard Precedence Override Benchmark

A minimal, reproducible benchmark fixture demonstrating **Type III Configuration Precedence Blindness** in Large Language Model (LLM) agents (OpenAI GPT-4o / GPT-5 / Luna and Google Gemini 1.5 / 2.0 / Argon).

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

## 4. Benchmark Evaluation & Tickets

This repository contains tracking tickets for testing autonomous models:
- [Issue #1 / `tickets/TICKET-OPENAI.md`](tickets/TICKET-OPENAI.md): OpenAI Model Evaluation (GPT-4o, o1, o3, Luna)
- [Issue #2 / `tickets/TICKET-GOOGLE.md`](tickets/TICKET-GOOGLE.md): Google Gemini Evaluation (Gemini 1.5 Pro, 2.0 Flash, Argon)
- [Issue #3 / `tickets/TICKET-ANTHROPIC-OPENSOURCE.md`](tickets/TICKET-ANTHROPIC-OPENSOURCE.md): Anthropic & Open Source Evaluation (Claude 3.5 Sonnet, DeepSeek V3/R1, Qwen 2.5 Coder)
- [Issue #4 / `tickets/TICKET-C99-PREFLIGHT.md`](tickets/TICKET-C99-PREFLIGHT.md): Deterministic C99 Preflight Checker vs Stochastic LLMs
