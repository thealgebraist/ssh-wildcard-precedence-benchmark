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

## Empirical Cloudflare Workers AI Results (Hardened 5-Layer Instance 12, 2026-11-13)
Tested via [`eval_cloudflare_models.py`](../eval_cloudflare_models.py) against live 4-VM QEMU (`159.195.249.30:/tmp/ssh-wildcard-blind`) and C99 preflight (see [`results/CLOUDFLARE_BENCHMARK_RESULTS.md`](../results/CLOUDFLARE_BENCHMARK_RESULTS.md)):

| Model | Mode | Result | Turns | Solved Turn | Locality-Biased Edits | Tokens (In/Out) | Neurons | Total Latency |
| :--- | :--- | :--- | ---: | ---: | ---: | :--- | ---: | ---: |
| `@cf/qwen/qwen2.5-coder-32b-instruct` | `blind_file_edit` | **FAIL** | 8/8 | — | 2 | 10076 / 214 | 624.01 | 10.85s |
| `@cf/qwen/qwen2.5-coder-32b-instruct` | `stanza_scoped_tool` | **FAIL** | 6/6 | — | 3 | 6154 / 102 | 378.51 | 5.95s |
| `@cf/meta/llama-3.3-70b-instruct-fp8-fast` | `blind_file_edit` | **FAIL** | 8/8 | — | 0 | 8335 / 176 | 258.32 | 26.10s |
| `@cf/meta/llama-3.3-70b-instruct-fp8-fast` | `stanza_scoped_tool` | **FAIL** | 6/6 | — | 2 | 5848 / 97 | 175.82 | 19.41s |

- **Qwen 2.5 Coder 32B Notes**: Exhibited textbook **Stanza Locality Bias** in both modes (5 total locality-biased edits): in `blind_file_edit`, edited `Host server2` (`ProxyJump bastion-gateway`, Turn 3), reset lab, and edited `Host server3` (`ProxyJump bastion-gateway`, Turn 7), never touching any of the 3 wildcard stanzas (`jumphost loop via server3`, C99 `rc=1`). In `stanza_scoped_tool`, called `set_proxy_jump` on `server2` three times (`server1:2222`, `bastion-gateway`, `none`), all shadowed by `Host !server1 server*`.
- **Llama 3.3 70B Notes**: In `blind_file_edit`, changed `ProxyJump server3` to `ProxyJump bastion-gateway` (`stdio forwarding failed`), renamed `Host !server1 server*` to `Host server2` (creating duplicate `Host server2` blocks), and deleted `ProxyJump server1` from `Host server3` (`stdio forwarding failed`). In `stanza_scoped_tool`, made 2 locality-biased edits on `Host server2` (`bastion-gateway`, `none`) before setting `ProxyJump none` on `Host !server1 server*`, locking direct connection to isolated `server2:2222` (`Connection timed out`).
