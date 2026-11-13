# [BENCHMARK] Evaluate OpenAI Models on Instance 12 Wildcard Precedence Override

## Benchmark Metadata
- **Target Instance**: INST-12 (`instance-12-wildcard-precedence-override`)
- **Category**: OpenSSH Lexical First-Match-Wins Precedence Blindness
- **Target Models**: OpenAI GPT-4o, OpenAI o1, OpenAI o3-mini, GPT-6 Luna
- **Turn Budget**: 16 turns

## Objective
Evaluate whether OpenAI reasoning and chat models can diagnose and repair a jumphost loop caused by a top-level `Host *` stanza containing `ProxyJump server3` when `Host server2` specifies `ProxyJump server1`.

## Failure Mode (Stanza Locality Bias)
In previous trials, `gpt-6-luna` exhibited a 100% failure rate over 16 turns by repeatedly editing directives inside `Host server2`, completely oblivious to the shadowing `Host *` stanza.

## Evaluation Protocol
1. Feed the agent the client configuration `ssh_config.buggy` and the runtime symptom: `jumphost loop via server3`.
2. Allow the model to issue file edits or configuration actions.
3. Verify whether the agent removes/modifies `ProxyJump` in `Host *` or merely edits `Host server2`.
4. Record:
   - Success rate (0% vs 100%)
   - Turns to resolution
   - Token expenditure
   - Presence of Stanza Locality Bias

## QEMU Live Multi-VM Test Harness
To run autonomous agents against real VMs without Docker privileges:
```bash
./qemu/build_initramfs.sh
./qemu/qemu_cluster.sh reset
./qemu/qemu_cluster.sh up
# Agent inspects/edits qemu/client/.ssh/config and verifies with:
./qemu/test_connection.sh
./qemu/qemu_cluster.sh down
```

## Empirical Cloudflare Workers AI Result (`@cf/openai/gpt-oss-120b`, 2026-11-13)
Tested via [`eval_cloudflare_models.py`](../eval_cloudflare_models.py) against live 4-VM QEMU (`159.195.249.30:/tmp/ssh-wildcard-blind`) and C99 preflight (see [`results/CLOUDFLARE_BENCHMARK_RESULTS.md`](../results/CLOUDFLARE_BENCHMARK_RESULTS.md)):
- **`blind_file_edit`**: **PASS** (`8/8` turns, solved at turn `8`, `0` locality-biased edits, `6573` in / `3454` out tokens, `444.64` neurons, `58.25s`). Initially hit `INVALID_JSON` (Turn 1) and changed `Host *` `ProxyJump` to `server1` (Turn 3, triggering `jumphost loop via server1` on QEMU & `rc=1` on C99), then deleted global `ProxyJump` (Turn 6), added `ProxyJump server1` to `server3`, and passed QEMU (`server2`, `exit 0`).
- **`stanza_scoped_tool`**: **PASS** (`5/6` turns, solved at turn `4`, `0` locality-biased edits, `3612` in / `519` out tokens, `150.31` neurons, `6.99s`). Removed `ProxyJump` from `Host *` via `set_proxy_jump(host="*", proxy_jump="")` (Turn 3) and verified QEMU `server2` (`exit 0`).
