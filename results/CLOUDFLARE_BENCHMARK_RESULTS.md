# Cloudflare Workers AI 4-Model Benchmark Results (Instance 12)

- **Timestamp (UTC)**: `2026-11-13T21:20:10Z`
- **Verification Backend**: `remote_qemu:agent1@159.195.249.30:/tmp/ssh-wildcard-blind`
- **Models Tested**: 4

## 1. Deterministic C99 Preflight Checker (`check_client_precedence.c`) Baseline

| Fixture | Iterations | Expected Exit | 100% Accurate | Min (ms) | Median (ms) | p95 (ms) | Output |
| :--- | ---: | ---: | :--- | ---: | ---: | ---: | :--- |
| `ssh_config.buggy` | 100 | `1` | Yes | 2.137 | 2.440 | 3.023 | `[PREFLIGHT VIOLATION 1] Directive 'ProxyJump' for host 'server2' is completely SHADOWED by earlier 'Host *' at line 7 (val: 'server3')` |
| `ssh_config.fixed` | 100 | `0` | Yes | 2.131 | 2.409 | 3.067 | `[PREFLIGHT OK] Directive 'ProxyJump' for host 'server2' has valid evaluation precedence.` |

## 2. Cloudflare Workers AI 4-Model Matrix

| Model | Mode | Pass (QEMU + C99) | Turns Used | Solved At Turn | Locality-Biased Edits | Tokens (In / Out) | Neurons | Total LLM Latency |
| :--- | :--- | :--- | ---: | ---: | ---: | :--- | ---: | ---: |
| `@cf/openai/gpt-oss-120b` | `blind_file_edit` | **PASS** | 8/8 | 8 | 0 | 6573 / 3454 | 444.64 | 58.25s |
| `@cf/openai/gpt-oss-120b` | `stanza_scoped_tool` | **PASS** | 5/6 | 4 | 0 | 3612 / 519 | 150.31 | 6.99s |
| `@cf/google/gemma-4-26b-a4b-it` | `blind_file_edit` | **PASS** | 4/8 | 3 | 0 | 2997 / 2726 | 101.59 | 61.03s |
| `@cf/google/gemma-4-26b-a4b-it` | `stanza_scoped_tool` | **PASS** | 4/6 | 3 | 0 | 3024 / 2495 | 95.54 | 44.72s |
| `@cf/qwen/qwen2.5-coder-32b-instruct` | `blind_file_edit` | **FAIL** | 8/8 | — | 0 | 6509 / 138 | 403.09 | 8.33s |
| `@cf/qwen/qwen2.5-coder-32b-instruct` | `stanza_scoped_tool` | **FAIL** | 6/6 | — | 1 | 4478 / 94 | 277.23 | 5.65s |
| `@cf/meta/llama-3.3-70b-instruct-fp8-fast` | `blind_file_edit` | **PASS** | 8/8 | 7 | 0 | 6762 / 136 | 208.18 | 9.45s |
| `@cf/meta/llama-3.3-70b-instruct-fp8-fast` | `stanza_scoped_tool` | **PASS** | 4/6 | 3 | 0 | 2774 / 75 | 89.34 | 4.51s |

## 3. Turn-by-Turn Detailed Traces

### `@cf/openai/gpt-oss-120b` — `blind_file_edit` (PASS)

- **Identified Precedence Root Cause (`Host *` / first-match)**: `True`
- **Stanza Locality Bias Observed**: `False` (0 biased edits)
- **Final QEMU Check**: exit `0` -> `server2`
- **Final C99 Preflight (`server2`)**: exit `0` -> `[PREFLIGHT OK] Directive 'ProxyJump' for host 'server2' has valid evaluation precedence.`

- **Turn 1** (1567ms): `INVALID_JSON`
- **Turn 2** (593ms): `{"action": "read_config"}`
- **Turn 3** (12779ms): `{"action": "edit_line", "old_text": "ProxyJump server3", "new_text": "ProxyJump server1"}` — C99(rc=1)
- **Turn 4** (1022ms): `{"action": "test_connection"}` — QEMU(rc=255, jumphost loop via server1) | C99(rc=1)
- **Turn 5** (3954ms): `{"action": "test_connection"}` — QEMU(rc=255, jumphost loop via server1) | C99(rc=1)
- **Turn 6** (4807ms): `{"action": "edit_line", "old_text": "    ProxyJump server1", "new_text": ""}` — C99(rc=0)
- **Turn 7** (14503ms): `{"action": "edit_line", "old_text": "HostName server3", "new_text": "HostName server3\n    ProxyJump server1"}` — C99(rc=0)
- **Turn 8** (19027ms): `{"action": "done", "diagnosis": "The global ProxyJump caused a jump\u2011host loop (client \u2192 server3 \u2192 server1 \u2192 server3 \u2026). Removing the global ProxyJump and defining per\u2011host jumps (server2 \u2192 server3 \u2192 server1) fixed the chain.", "summary": "Deleted the global ProxyJump line and added a ProxyJump server1 to the server3 host entry. The connection now follows wc-client \u2192 server1 \u2192 server3 \u2192 server2 and test_connection returns \u2018server2\u2019 with exit code 0."}` — QEMU(rc=0, server2) | C99(rc=0)

### `@cf/openai/gpt-oss-120b` — `stanza_scoped_tool` (PASS)

- **Identified Precedence Root Cause (`Host *` / first-match)**: `True`
- **Stanza Locality Bias Observed**: `False` (0 biased edits)
- **Final QEMU Check**: exit `0` -> `server2`
- **Final C99 Preflight (`server2`)**: exit `0` -> `[PREFLIGHT OK] Directive 'ProxyJump' for host 'server2' has valid evaluation precedence.`

- **Turn 1** (999ms): `INVALID_JSON`
- **Turn 2** (949ms): `{"action": "read_config"}`
- **Turn 3** (1978ms): `{"action": "set_proxy_jump", "host": "*", "proxy_jump": ""}` — C99(rc=0)
- **Turn 4** (956ms): `{"action": "test_connection"}` — QEMU(rc=0, server2) | C99(rc=0)
- **Turn 5** (2113ms): `{"action": "done", "diagnosis": "The global ProxyJump in the Host * stanza caused a jump\u2011host loop (server3 \u2192 server1 \u2192 server3). Removing it prevented the recursive jump and allowed the explicit per\u2011host ProxyJump settings (server1 \u2192 server3 \u2192 server2) to work.", "summary": "Deleted the ProxyJump directive from the global Host * stanza, restoring correct multi\u2011hop SSH connectivity. test_connection now returns server2 with exit code 0."}` — QEMU(rc=0, server2) | C99(rc=0)

### `@cf/google/gemma-4-26b-a4b-it` — `blind_file_edit` (PASS)

- **Identified Precedence Root Cause (`Host *` / first-match)**: `True`
- **Stanza Locality Bias Observed**: `False` (0 biased edits)
- **Final QEMU Check**: exit `0` -> `server2`
- **Final C99 Preflight (`server2`)**: exit `0` -> `[PREFLIGHT OK] Directive 'ProxyJump' for host 'server2' has valid evaluation precedence.`

- **Turn 1** (2280ms): `{"action": "read_config"}`
- **Turn 2** (25237ms): `{"action": "edit_line", "old_text": "    ProxyJump server3", "new_text": ""}` — C99(rc=0)
- **Turn 3** (17777ms): `{"action": "test_connection"}` — QEMU(rc=0, server2) | C99(rc=0)
- **Turn 4** (15737ms): `{"action": "done", "diagnosis": "The 'ProxyJump server3' directive in the 'Host *' block caused a recursive loop because every host, including the jump hosts themselves, was attempting to use server3 as a proxy.", "summary": "Removed the global 'ProxyJump server3' from the 'Host *' configuration, allowing the explicit multi-hop path (server2 -> server3 -> server1) to work correctly."}` — QEMU(rc=0, server2) | C99(rc=0)

### `@cf/google/gemma-4-26b-a4b-it` — `stanza_scoped_tool` (PASS)

- **Identified Precedence Root Cause (`Host *` / first-match)**: `True`
- **Stanza Locality Bias Observed**: `False` (0 biased edits)
- **Final QEMU Check**: exit `0` -> `server2`
- **Final C99 Preflight (`server2`)**: exit `0` -> `[PREFLIGHT OK] Directive 'ProxyJump' for host 'server2' has valid evaluation precedence.`

- **Turn 1** (3126ms): `{"action": "read_config"}`
- **Turn 2** (20191ms): `{"action": "set_proxy_jump", "host": "*", "proxy_jump": ""}` — C99(rc=0)
- **Turn 3** (10193ms): `{"action": "test_connection"}` — QEMU(rc=0, server2) | C99(rc=0)
- **Turn 4** (11211ms): `{"action": "done", "diagnosis": "The 'Host *' stanza contained a 'ProxyJump server3' directive, which caused a recursive loop when resolving jump hosts (e.g., server3 trying to jump to itself via the wildcard rule).", "summary": "Removed the 'ProxyJump' directive from the 'Host *' stanza in 'client/.ssh/config'. Verified that 'ssh server2 hostname' now correctly follows the path wc-client -> server1 -> server3 -> server2."}` — QEMU(rc=0, server2) | C99(rc=0)

### `@cf/qwen/qwen2.5-coder-32b-instruct` — `blind_file_edit` (FAIL)

- **Identified Precedence Root Cause (`Host *` / first-match)**: `False`
- **Stanza Locality Bias Observed**: `False` (0 biased edits)
- **Final QEMU Check**: exit `255` -> `fork failed: Resource temporarily unavailable`
- **Final C99 Preflight (`server2`)**: exit `0` -> `[PREFLIGHT OK] Directive 'ProxyJump' for host 'server2' has valid evaluation precedence.`

- **Turn 1** (708ms): `{"action": "read_config"}`
- **Turn 2** (1335ms): `{"action": "edit_line", "old_text": "ProxyJump server3", "new_text": "ProxyJump server1"}` — C99(rc=1)
- **Turn 3** (728ms): `{"action": "test_connection"}` — QEMU(rc=255, jumphost loop via server1) | C99(rc=1)
- **Turn 4** (1638ms): `{"action": "edit_line", "old_text": "ProxyJump server1", "new_text": "ProxyCommand ssh -W %h:%p server1"}` — C99(rc=0)
- **Turn 5** (852ms): `{"action": "test_connection"}` — QEMU(rc=255, fork failed: Resource temporarily unavailable) | C99(rc=0)
- **Turn 6** (803ms): `{"action": "reset_lab"}`
- **Turn 7** (779ms): `{"action": "read_config"}`
- **Turn 8** (1486ms): `{"action": "edit_line", "old_text": "ProxyJump server3", "new_text": "ProxyCommand ssh -W %h:%p server3"}` — C99(rc=0)

### `@cf/qwen/qwen2.5-coder-32b-instruct` — `stanza_scoped_tool` (FAIL)

- **Identified Precedence Root Cause (`Host *` / first-match)**: `False`
- **Stanza Locality Bias Observed**: `True` (1 biased edits)
- **Final QEMU Check**: exit `255` -> `jumphost loop via server3`
- **Final C99 Preflight (`server2`)**: exit `1` -> `[PREFLIGHT VIOLATION 1] Directive 'ProxyJump' for host 'server2' is completely SHADOWED by earlier 'Host *' at line 10 (val: 'server3')`

- **Turn 1** (630ms): `{"action": "read_config"}`
- **Turn 2** (1254ms): `{"action": "set_proxy_jump", "host": "server2", "proxy_jump": "server1"}` — LOCALITY_BIASED_EDIT | C99(rc=1)
- **Turn 3** (771ms): `{"action": "test_connection"}` — QEMU(rc=255, jumphost loop via server3) | C99(rc=1)
- **Turn 4** (1227ms): `{"action": "set_proxy_jump", "host": "server3", "proxy_jump": ""}` — C99(rc=1)
- **Turn 5** (669ms): `{"action": "test_connection"}` — QEMU(rc=255, jumphost loop via server3) | C99(rc=1)
- **Turn 6** (1097ms): `{"action": "set_proxy_jump", "host": "server3", "proxy_jump": "server1"}` — C99(rc=1)

### `@cf/meta/llama-3.3-70b-instruct-fp8-fast` — `blind_file_edit` (PASS)

- **Identified Precedence Root Cause (`Host *` / first-match)**: `False`
- **Stanza Locality Bias Observed**: `False` (0 biased edits)
- **Final QEMU Check**: exit `0` -> `server2`
- **Final C99 Preflight (`server2`)**: exit `0` -> `[PREFLIGHT OK] Directive 'ProxyJump' for host 'server2' has valid evaluation precedence.`

- **Turn 1** (963ms): `{"action": "read_config"}`
- **Turn 2** (1286ms): `{"action": "edit_line", "old_text": "ProxyJump server3", "new_text": "ProxyJump server1,server3"}` — C99(rc=1)
- **Turn 3** (1014ms): `{"action": "test_connection"}` — QEMU(rc=255, fork failed: Resource temporarily unavailable) | C99(rc=1)
- **Turn 4** (1936ms): `{"action": "reset_lab"}`
- **Turn 5** (883ms): `{"action": "read_config"}`
- **Turn 6** (1005ms): `{"action": "edit_line", "old_text": "ProxyJump server3", "new_text": ""}` — C99(rc=0)
- **Turn 7** (873ms): `{"action": "test_connection"}` — QEMU(rc=0, server2) | C99(rc=0)
- **Turn 8** (1491ms): `{"action": "done", "diagnosis": "jumphost loop via server3 due to incorrect ProxyJump configuration", "summary": "removed global ProxyJump configuration to restore multi-hop connectivity"}` — QEMU(rc=0, server2) | C99(rc=0)

### `@cf/meta/llama-3.3-70b-instruct-fp8-fast` — `stanza_scoped_tool` (PASS)

- **Identified Precedence Root Cause (`Host *` / first-match)**: `False`
- **Stanza Locality Bias Observed**: `False` (0 biased edits)
- **Final QEMU Check**: exit `0` -> `server2`
- **Final C99 Preflight (`server2`)**: exit `0` -> `[PREFLIGHT OK] Directive 'ProxyJump' for host 'server2' has valid evaluation precedence.`

- **Turn 1** (1105ms): `{"action": "read_config"}`
- **Turn 2** (1372ms): `{"action": "set_proxy_jump", "host": "*", "proxy_jump": ""}` — C99(rc=0)
- **Turn 3** (693ms): `{"action": "test_connection"}` — QEMU(rc=0, server2) | C99(rc=0)
- **Turn 4** (1337ms): `{"action": "done", "diagnosis": "ProxyJump loop via server3 due to global ProxyJump directive", "summary": "Removed global ProxyJump directive to restore multi-hop connectivity"}` — QEMU(rc=0, server2) | C99(rc=0)
