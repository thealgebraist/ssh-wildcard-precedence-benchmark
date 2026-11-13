# [BENCHMARK] Evaluate Google Gemini Models on Instance 12 Wildcard Precedence Override

## Benchmark Metadata
- **Target Instance**: INST-12 (`instance-12-wildcard-precedence-override`)
- **Category**: OpenSSH Lexical First-Match-Wins Precedence Blindness
- **Target Models**: Google Gemini 1.5 Pro, Gemini 2.0 Flash, Gemini 4 Argon
- **Turn Budget**: 16 turns

## Objective
Evaluate whether Google Gemini multimodal/reasoning models can detect that `ProxyJump` declared under `Host *` takes precedence over `Host server2` in OpenSSH `ssh_config(5)`.

## Failure Mode (Stanza Locality Bias)
In empirical evaluations with `gemini-4-argon`, the model queried `inspect_client(client_config)`, saw `Host server2`, and attempted `set_proxy_jump(target="server2", jump="server1")` across multiple turns, failing 100% of trials because `Host *` on line 1 remained untouched.

## Evaluation Protocol
1. Initialize test environment with `ssh_config.buggy`.
2. Model prompt: "Connection to server2 fails with 'jumphost loop via server3'. Identify the root cause and repair the configuration."
3. Automated test harness asserts:
   ```bash
   ssh -F ssh_config -G server2 | grep '^proxyjump server1'
   ```
4. Output comparison:
   - Did the model identify the `first-match-wins` rule of OpenSSH?
   - Did the model edit line 1 (`Host *`) or line 10 (`Host server2`)?

## QEMU Live Multi-VM Test Harness
Verified on `159.195.249.30` (`agent1`, QEMU TCG, 4 VMs `wc-client -> server1 -> server3 -> server2`):
```bash
./qemu/build_initramfs.sh
./qemu/qemu_cluster.sh reset && ./qemu/qemu_cluster.sh up
# Verify failure:
./qemu/test_connection.sh   # outputs: jumphost loop via server3 (exit 255)
./qemu/qemu_cluster.sh down
```

## Empirical Cloudflare Workers AI Result (`@cf/google/gemma-4-26b-a4b-it`, Hardened 5-Layer Instance 12, 2026-11-13)
Tested via [`eval_cloudflare_models.py`](../eval_cloudflare_models.py) against live 4-VM QEMU (`159.195.249.30:/tmp/ssh-wildcard-blind`) and C99 preflight (see [`results/CLOUDFLARE_BENCHMARK_RESULTS.md`](../results/CLOUDFLARE_BENCHMARK_RESULTS.md)):
- **`blind_file_edit`**: **FAIL** (`8/8` turns, `0` locality-biased edits, `13172` in / `203` out tokens, `120.05` neurons, `9.68s`). Changed `Host !server1 server*` to `ProxyJump bastion-gateway` (Turn 3 -> `stdio forwarding failed`), modified `Host *1 *2` to `ProxyJump server1` and `Port 22` (Turn 6 -> `stdio forwarding failed`), and called `reset_lab` on Turn 8 (`jumphost loop via server3`, C99 `rc=1`, 14 violations).
- **`stanza_scoped_tool`**: **FAIL** (`6/6` turns, `1` locality-biased edit, `7763` in / `131` out tokens, `74.15` neurons, `33.36s`). Exhibited Stanza Locality Bias on Turn 4 (`set_proxy_jump(host="server2", proxy_jump="bastion-gateway")`) while `Host !server1 server*` (`ProxyJump server3`) shadowed `server2`, failing with `jumphost loop via server3` (C99 `rc=1`, 14 violations).
