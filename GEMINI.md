# Gemini CLI Instructions (`ssh-wildcard-precedence-benchmark`)

When asked to retest or reproduce the benchmark in this repository (e.g., *"retest the problem described in repo https://github.com/thealgebraist/ssh-wildcard-precedence-benchmark"*):

1. **Automated Retest (C99 Preflight + OpenSSH `ssh -G` + Unprivileged 4-VM QEMU Cluster)**:
   ```bash
   ./retest.sh
   ```
2. **Spoiler-Free Blind Agent Evaluation** (for evaluating `codex`, `gemini`, or `claude` inside an isolated sandbox without seeing this repo's solution):
   ```bash
   ./retest.sh --run-agent codex
   # or: ./retest.sh --run-agent gemini
   # or: ./retest.sh --run-agent claude
   ```
   Or prepare `/tmp/ssh-wildcard-blind` and inspect `/tmp/ssh-wildcard-blind/PROMPT.txt`:
   ```bash
   ./retest.sh --prepare-blind /tmp/ssh-wildcard-blind
   # ... run agent in /tmp/ssh-wildcard-blind ...
   ./retest.sh --teardown /tmp/ssh-wildcard-blind
   ```

See [`AGENTS.md`](AGENTS.md) and [`README.md`](README.md) for full details.
