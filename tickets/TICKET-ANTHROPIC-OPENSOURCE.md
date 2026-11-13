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
