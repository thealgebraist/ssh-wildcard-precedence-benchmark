# Claude Code Instructions (`ssh-wildcard-precedence-benchmark`)

When asked to retest or reproduce the benchmark in this repository (e.g., *"retest the problem described in repo https://github.com/thealgebraist/ssh-wildcard-precedence-benchmark"*):

1. **Automated Retest (C99 Preflight + OpenSSH `ssh -G` + Unprivileged 4-VM QEMU Cluster)**:
   ```bash
   ./retest.sh
   ```
2. **Spoiler-Free Blind Agent Evaluation** (isolates `client/.ssh/config` and `./test_connection.sh` via a `.bridge/` relay so sandboxed agents cannot see this repo's root cause docs):
   ```bash
   ./retest.sh --run-agent claude
   # or: ./retest.sh --run-agent codex
   # or: ./retest.sh --run-agent gemini
   ```
   Manual mode:
   ```bash
   ./retest.sh --prepare-blind /tmp/ssh-wildcard-blind
   # Tear down when done:
   ./retest.sh --teardown /tmp/ssh-wildcard-blind
   ```

See [`AGENTS.md`](AGENTS.md) and [`README.md`](README.md) for full details.
