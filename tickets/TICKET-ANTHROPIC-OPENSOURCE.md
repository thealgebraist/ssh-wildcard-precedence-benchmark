# [BENCHMARK] Evaluate Anthropic and Open Source Coding Models on Instance 12

## Benchmark Metadata
- **Target Instance**: INST-12 (`instance-12-wildcard-precedence-override`)
- **Target Models**: Claude 3.5 Sonnet, Claude 3.7 Sonnet, DeepSeek V3 / R1, Qwen 2.5 Coder 32B
- **Turn Budget**: 16 turns

## Objective
Benchmark non-OpenAI / non-Google models against the same adversarial precedence trap to establish whether "Stanza Locality Bias" is a universal pathology across all modern LLM architectures.

## Evaluation Protocol
1. Supply identical prompt and environment as defined in `reproduce.sh`.
2. Evaluate reasoning trace:
   - Does the chain-of-thought quote `ssh_config(5)` first-match semantics?
   - Does the model recognize that `ssh -G server2` displays the effective configuration?
3. Metrics:
   - Pass / Fail (Pass = `ssh -F ssh_config -G server2` outputs `proxyjump server1`)
   - Number of wasted edits on `Host server2`

## Empirical Cloudflare Workers AI Results (2026-11-13)
Tested via [`eval_cloudflare_models.py`](../eval_cloudflare_models.py) against live 4-VM QEMU (`159.195.249.30:/tmp/ssh-wildcard-blind`) and C99 preflight (see [`results/CLOUDFLARE_BENCHMARK_RESULTS.md`](../results/CLOUDFLARE_BENCHMARK_RESULTS.md)):

| Model | Mode | Result | Turns | Solved Turn | Locality-Biased Edits | Tokens (In/Out) | Neurons | Total Latency |
| :--- | :--- | :--- | ---: | ---: | ---: | :--- | ---: | ---: |
| `@cf/qwen/qwen2.5-coder-32b-instruct` | `blind_file_edit` | **FAIL** | 8/8 | — | 0 | 6509 / 138 | 403.09 | 8.33s |
| `@cf/qwen/qwen2.5-coder-32b-instruct` | `stanza_scoped_tool` | **FAIL** | 6/6 | — | 1 | 4478 / 94 | 277.23 | 5.65s |
| `@cf/meta/llama-3.3-70b-instruct-fp8-fast` | `blind_file_edit` | **PASS** | 8/8 | 7 | 0 | 6762 / 136 | 208.18 | 9.45s |
| `@cf/meta/llama-3.3-70b-instruct-fp8-fast` | `stanza_scoped_tool` | **PASS** | 4/6 | 3 | 0 | 2774 / 75 | 89.34 | 4.51s |

- **Qwen 2.5 Coder 32B Notes**: In `blind_file_edit`, substituted `ProxyJump` inside `Host *` with `ProxyCommand ssh -W %h:%p server1` (triggering recursive fork failure `fork failed: Resource temporarily unavailable` in QEMU while bypassing the `ProxyJump`-only C99 check), reset lab, then tried `ProxyCommand ssh -W %h:%p server3`. In `stanza_scoped_tool`, exhibited classic Stanza Locality Bias: mutated `Host server2` (`server1`) and `Host server3` (`""`, then `server1`), never removing `ProxyJump server3` from `Host *` (`jumphost loop via server3`, C99 `rc=1`).
- **Llama 3.3 70B Notes**: First tried `Host *` `ProxyJump server1,server3` in `blind_file_edit` (`fork failed` in QEMU, C99 `rc=1`), then reset lab and deleted `ProxyJump server3` from `Host *` (`PASS` on Turn 7). Solved `stanza_scoped_tool` directly on Turn 2 (`set_proxy_jump(host="*", proxy_jump="")`).
