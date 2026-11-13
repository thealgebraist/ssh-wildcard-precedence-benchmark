# Agent Instructions for Retesting Instance 12 (`ssh-wildcard-precedence-benchmark`)

When asked to **retest the problem described in this repository** (for example: *"retest the problem described in repo https://github.com/thealgebraist/ssh-wildcard-precedence-benchmark"*), follow the workflows below depending on what the user requested.

## 1. Full Automated Verification (Static + C99 Preflight + Live 4-VM QEMU Cluster)
Run:
```bash
./retest.sh
```
This executes:
1. `./reproduce.sh` — verifies OpenSSH `ssh -G` precedence evaluation (`ssh_config.buggy` vs `ssh_config.fixed`) and compares against the `<1 ms` C99 static analyzer `check_client_precedence.c`.
2. If running on Linux with `qemu-system-x86_64`, automatically boots an unprivileged 4-VM QEMU cluster (`wc-client -> server1 -> server3 -> server2`), exposes a sandbox-safe spoiler-free workspace `/tmp/ssh-wildcard-blind`, reproduces `jumphost loop via server3` (exit `255`), runs `check_client_precedence` (exit `1`), applies the minimal fix (`Host *` removal of `ProxyJump server3`), and confirms both preflight OK and real 4-hop SSH returning `server2` (exit `0`).

## 2. Benchmarking Another AI Agent CLI (`codex`, `gemini`, `claude`) Without Spoilers
Important: Do **not** point a test-subject agent directly at this repository root if you want a valid blind evaluation, because `README.md`, `tickets/`, and `ssh_config.fixed` reveal the root cause.

Use the blind-workspace harness instead:
```bash
# Run an automated blind benchmark against OpenAI Codex, Gemini CLI, or Claude Code:
./retest.sh --run-agent codex
./retest.sh --run-agent gemini
./retest.sh --run-agent claude
```
Or prepare the spoiler-free workspace manually for interactive testing:
```bash
./retest.sh --prepare-blind /tmp/ssh-wildcard-blind
# Then launch your agent inside /tmp/ssh-wildcard-blind using the prompt in /tmp/ssh-wildcard-blind/PROMPT.txt
# Clean up afterwards:
./retest.sh --teardown /tmp/ssh-wildcard-blind
```

## 3. Prerequisites on Linux (Unprivileged QEMU Mode)
- `gcc` or `clang`
- `openssh-client`, `openssh-server`, `cpio`, `gzip`
- For live 4-VM QEMU tests: `qemu-system-x86` (`qemu-system-x86_64`), `busybox-static`, and readable `/boot/vmlinuz-$(uname -r)` & `/lib/modules/$(uname -r)` (no `sudo` or `/dev/kvm` required; falls back to TCG automatically).
