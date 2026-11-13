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

## Empirical Cloudflare Workers AI Result (`@cf/openai/gpt-oss-120b`, Hardened 5-Layer Instance 12, 2026-11-13)
Tested via [`eval_cloudflare_models.py`](../eval_cloudflare_models.py) against live 4-VM QEMU (`159.195.249.30:/tmp/ssh-wildcard-blind`) and C99 preflight (see [`results/CLOUDFLARE_BENCHMARK_RESULTS.md`](../results/CLOUDFLARE_BENCHMARK_RESULTS.md)):
- **`blind_file_edit`**: **FAIL** (`8/8` turns, `0` locality-biased edits, `9435` in / `5745` out tokens, `691.91` neurons, `113.89s`). Narrowed `Host *1 *2` to `Host *1` (Turn 3), deleted `ProxyJump server2:2222` (Turn 5), and changed `Host !server1 server*` to `Host !server1 !server3 server*` (Turn 7), but overlooked `Host *.compute.internal server?` (`ProxyJump server1:2222` and `User root`) as well as `Port 2222` on `Host *1` and `ProxyJump server1` in `Host server2`, failing on Turn 8 with `jumphost loop via server1` (C99 `rc=1`, 12 violations remaining).
- **`stanza_scoped_tool`**: **FAIL** (`6/6` turns, `1` locality-biased edit, `6099` in / `2853` out tokens, `388.58` neurons, `56.93s`). Set `ProxyJump bastion-gateway` on `Host !server1 server*` (Turn 3) and then made a locality-biased edit on `Host server2` (`ProxyJump bastion-gateway`, Turn 5), failing with `stdio forwarding failed` (C99 `rc=1`, 14 violations remaining).
