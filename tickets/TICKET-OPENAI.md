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
