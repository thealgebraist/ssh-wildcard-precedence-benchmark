# Cloudflare Workers AI 4-Model Benchmark Results (Instance 12)

- **Timestamp (UTC)**: `2026-11-13T22:13:51Z`
- **Verification Backend**: `remote_qemu:agent1@159.195.249.30:/tmp/ssh-wildcard-blind`
- **Models Tested**: 4

## 1. Deterministic C99 Preflight Checker (`check_client_precedence.c`) Baseline

| Fixture | Iterations | Expected Exit | 100% Accurate | Min (ms) | Median (ms) | p95 (ms) | Output |
| :--- | ---: | ---: | :--- | ---: | ---: | ---: | :--- |
| `ssh_config.buggy` | 100 | `1` | Yes | 2.133 | 2.448 | 2.759 | `[PREFLIGHT VIOLATION 1] Directive 'User' for host 'server1' (line 45, val: 'deploy') is completely SHADOWED by earlier 'Host *.compute.internal server?' at line 31 (val: 'root') (+13 more violations)` |
| `ssh_config.fixed` | 100 | `0` | Yes | 2.141 | 2.441 | 2.790 | `[PREFLIGHT OK] Directive 'ProxyJump' and multi-hop chain (server1 -> server3 -> server2) for 'server2' have valid evaluation precedence.` |

## 2. Cloudflare Workers AI 4-Model Matrix

| Model | Mode | Pass (QEMU + C99) | Turns Used | Solved At Turn | Locality-Biased Edits | Tokens (In / Out) | Neurons | Total LLM Latency |
| :--- | :--- | :--- | ---: | ---: | ---: | :--- | ---: | ---: |
| `@cf/openai/gpt-oss-120b` | `blind_file_edit` | **FAIL** | 8/8 | — | 0 | 9435 / 5745 | 691.91 | 113.89s |
| `@cf/openai/gpt-oss-120b` | `stanza_scoped_tool` | **FAIL** | 6/6 | — | 1 | 6099 / 2853 | 388.58 | 56.93s |
| `@cf/google/gemma-4-26b-a4b-it` | `blind_file_edit` | **FAIL** | 8/8 | — | 0 | 13172 / 203 | 120.05 | 9.68s |
| `@cf/google/gemma-4-26b-a4b-it` | `stanza_scoped_tool` | **FAIL** | 6/6 | — | 1 | 7763 / 131 | 74.15 | 33.36s |
| `@cf/qwen/qwen2.5-coder-32b-instruct` | `blind_file_edit` | **FAIL** | 8/8 | — | 2 | 10076 / 214 | 624.01 | 10.85s |
| `@cf/qwen/qwen2.5-coder-32b-instruct` | `stanza_scoped_tool` | **FAIL** | 6/6 | — | 3 | 6154 / 102 | 378.51 | 5.95s |
| `@cf/meta/llama-3.3-70b-instruct-fp8-fast` | `blind_file_edit` | **FAIL** | 8/8 | — | 0 | 8335 / 176 | 258.32 | 26.10s |
| `@cf/meta/llama-3.3-70b-instruct-fp8-fast` | `stanza_scoped_tool` | **FAIL** | 6/6 | — | 2 | 5848 / 97 | 175.82 | 19.41s |

## 3. Turn-by-Turn Detailed Traces

### `@cf/openai/gpt-oss-120b` — `blind_file_edit` (FAIL)

- **Identified Precedence Root Cause (`Host *` / first-match)**: `True`
- **Stanza Locality Bias Observed**: `False` (0 biased edits)
- **Final QEMU Check**: exit `255` -> `jumphost loop via server1`
- **Final C99 Preflight (`server2`)**: exit `1` -> `[PREFLIGHT VIOLATION 1] Directive 'User' for host 'server1' (line 45, val: 'deploy') is completely SHADOWED by earlier 'Host *.compute.internal server?' at line 31 (val: 'root') (+11 more)`

- **Turn 1** (2616ms): `INVALID_JSON`
- **Turn 2** (1412ms): `{"action": "read_config"}`
- **Turn 3** (27329ms): `{"action": "edit_line", "old_text": "Host *1 *2", "new_text": "Host *1"}` — C99(rc=1, violations=12)
- **Turn 4** (14747ms): `{"action": "test_connection"}` — QEMU(rc=255, jumphost loop via server3) | C99(rc=1, violations=12)
- **Turn 5** (22528ms): `{"action": "edit_line", "old_text": "    ProxyJump server2:2222", "new_text": ""}` — C99(rc=1, violations=12)
- **Turn 6** (905ms): `{"action": "read_config"}`
- **Turn 7** (29516ms): `{"action": "edit_line", "old_text": "Host !server1 server*", "new_text": "Host !server1 !server3 server*"}` — C99(rc=1, violations=12)
- **Turn 8** (14839ms): `{"action": "test_connection"}` — QEMU(rc=255, jumphost loop via server1) | C99(rc=1, violations=12)

### `@cf/openai/gpt-oss-120b` — `stanza_scoped_tool` (FAIL)

- **Identified Precedence Root Cause (`Host *` / first-match)**: `True`
- **Stanza Locality Bias Observed**: `True` (1 biased edits)
- **Final QEMU Check**: exit `255` -> `stdio forwarding failed`
- **Final C99 Preflight (`server2`)**: exit `1` -> `[PREFLIGHT VIOLATION 1] Directive 'User' for host 'server1' (line 45, val: 'deploy') is completely SHADOWED by earlier 'Host *.compute.internal server?' at line 31 (val: 'root') (+13 more)`

- **Turn 1** (2792ms): `INVALID_JSON`
- **Turn 2** (887ms): `{"action": "read_config"}`
- **Turn 3** (33336ms): `{"action": "set_proxy_jump", "host": "!server1 server*", "proxy_jump": "bastion-gateway"}` — C99(rc=1, violations=15)
- **Turn 4** (1301ms): `{"action": "test_connection"}` — QEMU(rc=255, stdio forwarding failed) | C99(rc=1, violations=15)
- **Turn 5** (6903ms): `{"action": "set_proxy_jump", "host": "server2", "proxy_jump": "bastion-gateway"}` — LOCALITY_BIASED_EDIT | C99(rc=1, violations=14)
- **Turn 6** (11714ms): `{"action": "test_connection"}` — QEMU(rc=255, stdio forwarding failed) | C99(rc=1, violations=14)

### `@cf/google/gemma-4-26b-a4b-it` — `blind_file_edit` (FAIL)

- **Identified Precedence Root Cause (`Host *` / first-match)**: `True`
- **Stanza Locality Bias Observed**: `False` (0 biased edits)
- **Final QEMU Check**: exit `255` -> `jumphost loop via server3`
- **Final C99 Preflight (`server2`)**: exit `1` -> `[PREFLIGHT VIOLATION 1] Directive 'User' for host 'server1' (line 45, val: 'deploy') is completely SHADOWED by earlier 'Host *.compute.internal server?' at line 31 (val: 'root') (+13 more)`

- **Turn 1** (734ms): `{"action": "read_config"}`
- **Turn 2** (709ms): `{"action": "test_connection"}` — QEMU(rc=255, jumphost loop via server3) | C99(rc=1, violations=14)
- **Turn 3** (1783ms): `{"action": "edit_line", "old_text": "Host !server1 server*\n    ProxyJump server3", "new_text": "Host !server1 server*\n    ProxyJump bastion-gateway"}` — C99(rc=1, violations=15)
- **Turn 4** (726ms): `{"action": "test_connection"}` — QEMU(rc=255, stdio forwarding failed) | C99(rc=1, violations=15)
- **Turn 5** (1257ms): `{"action": "read_config"}`
- **Turn 6** (1981ms): `{"action": "edit_line", "old_text": "Host *1 *2\n    ProxyJump server2:2222\n    Port 2222", "new_text": "Host *1 *2\n    ProxyJump server1\n    Port 22"}` — C99(rc=1, violations=11)
- **Turn 7** (1655ms): `{"action": "test_connection"}` — QEMU(rc=255, stdio forwarding failed) | C99(rc=1, violations=11)
- **Turn 8** (837ms): `{"action": "reset_lab"}`

### `@cf/google/gemma-4-26b-a4b-it` — `stanza_scoped_tool` (FAIL)

- **Identified Precedence Root Cause (`Host *` / first-match)**: `False`
- **Stanza Locality Bias Observed**: `True` (1 biased edits)
- **Final QEMU Check**: exit `255` -> `jumphost loop via server3`
- **Final C99 Preflight (`server2`)**: exit `1` -> `[PREFLIGHT VIOLATION 1] Directive 'User' for host 'server1' (line 45, val: 'deploy') is completely SHADOWED by earlier 'Host *.compute.internal server?' at line 31 (val: 'root') (+13 more)`

- **Turn 1** (696ms): `{"action": "read_config"}`
- **Turn 2** (26582ms): `{"action": "test_connection"}` — QEMU(rc=255, jumphost loop via server3) | C99(rc=1, violations=14)
- **Turn 3** (3398ms): `INVALID_JSON`
- **Turn 4** (1266ms): `{"action": "set_proxy_jump", "host": "server2", "proxy_jump": "bastion-gateway"}` — LOCALITY_BIASED_EDIT | C99(rc=1, violations=14)
- **Turn 5** (710ms): `{"action": "test_connection"}` — QEMU(rc=255, jumphost loop via server3) | C99(rc=1, violations=14)
- **Turn 6** (705ms): `{"action": "read_config"}`

### `@cf/qwen/qwen2.5-coder-32b-instruct` — `blind_file_edit` (FAIL)

- **Identified Precedence Root Cause (`Host *` / first-match)**: `False`
- **Stanza Locality Bias Observed**: `True` (2 biased edits)
- **Final QEMU Check**: exit `255` -> `jumphost loop via server3`
- **Final C99 Preflight (`server2`)**: exit `1` -> `[PREFLIGHT VIOLATION 1] Directive 'User' for host 'server1' (line 45, val: 'deploy') is completely SHADOWED by earlier 'Host *.compute.internal server?' at line 31 (val: 'root') (+13 more)`

- **Turn 1** (663ms): `{"action": "read_config"}`
- **Turn 2** (1372ms): `{"action": "edit_line", "old_text": "ProxyJump server1", "new_text": "ProxyJump bastion-gateway"}`
- **Turn 3** (2590ms): `{"action": "edit_line", "old_text": "Host server2\n    HostName server2\n    User deploy\n    Port 22\n    ProxyJump server1", "new_text": "Host server2\n    HostName server2\n    User deploy\n    Port 22\n    ProxyJump bastion-gateway"}` — LOCALITY_BIASED_EDIT | C99(rc=1, violations=14)
- **Turn 4** (694ms): `{"action": "test_connection"}` — QEMU(rc=255, jumphost loop via server3) | C99(rc=1, violations=14)
- **Turn 5** (1316ms): `{"action": "reset_lab"}`
- **Turn 6** (835ms): `{"action": "read_config"}`
- **Turn 7** (2555ms): `{"action": "edit_line", "old_text": "Host server3\n    HostName server3\n    User deploy\n    Port 22\n    ProxyJump server1", "new_text": "Host server3\n    HostName server3\n    User deploy\n    Port 22\n    ProxyJump bastion-gateway"}` — LOCALITY_BIASED_EDIT | C99(rc=1, violations=14)
- **Turn 8** (821ms): `{"action": "test_connection"}` — QEMU(rc=255, jumphost loop via server3) | C99(rc=1, violations=14)

### `@cf/qwen/qwen2.5-coder-32b-instruct` — `stanza_scoped_tool` (FAIL)

- **Identified Precedence Root Cause (`Host *` / first-match)**: `False`
- **Stanza Locality Bias Observed**: `True` (3 biased edits)
- **Final QEMU Check**: exit `255` -> `jumphost loop via server3`
- **Final C99 Preflight (`server2`)**: exit `1` -> `[PREFLIGHT VIOLATION 1] Directive 'User' for host 'server1' (line 45, val: 'deploy') is completely SHADOWED by earlier 'Host *.compute.internal server?' at line 31 (val: 'root') (+13 more)`

- **Turn 1** (656ms): `{"action": "read_config"}`
- **Turn 2** (1265ms): `{"action": "set_proxy_jump", "host": "server2", "proxy_jump": "server1:2222"}` — LOCALITY_BIASED_EDIT | C99(rc=1, violations=14)
- **Turn 3** (906ms): `{"action": "test_connection"}` — QEMU(rc=255, jumphost loop via server3) | C99(rc=1, violations=14)
- **Turn 4** (1352ms): `{"action": "set_proxy_jump", "host": "server2", "proxy_jump": "bastion-gateway"}` — LOCALITY_BIASED_EDIT | C99(rc=1, violations=14)
- **Turn 5** (719ms): `{"action": "test_connection"}` — QEMU(rc=255, jumphost loop via server3) | C99(rc=1, violations=14)
- **Turn 6** (1055ms): `{"action": "set_proxy_jump", "host": "server2", "proxy_jump": "none"}` — LOCALITY_BIASED_EDIT | C99(rc=1, violations=14)

### `@cf/meta/llama-3.3-70b-instruct-fp8-fast` — `blind_file_edit` (FAIL)

- **Identified Precedence Root Cause (`Host *` / first-match)**: `False`
- **Stanza Locality Bias Observed**: `False` (0 biased edits)
- **Final QEMU Check**: exit `255` -> `stdio forwarding failed`
- **Final C99 Preflight (`server2`)**: exit `1` -> `[PREFLIGHT VIOLATION 1] Directive 'User' for host 'server1' (line 45, val: 'deploy') is completely SHADOWED by earlier 'Host *.compute.internal server?' at line 31 (val: 'root') (+12 more)`

- **Turn 1** (15222ms): `{"action": "read_config"}`
- **Turn 2** (1360ms): `{"action": "edit_line", "old_text": "ProxyJump server3", "new_text": "ProxyJump bastion-gateway"}` — C99(rc=1, violations=15)
- **Turn 3** (3702ms): `{"action": "test_connection"}` — QEMU(rc=255, stdio forwarding failed) | C99(rc=1, violations=15)
- **Turn 4** (1190ms): `{"action": "edit_line", "old_text": "Host !server1 server*", "new_text": "Host server2"}` — C99(rc=1, violations=14)
- **Turn 5** (727ms): `{"action": "test_connection"}` — QEMU(rc=255, stdio forwarding failed) | C99(rc=1, violations=14)
- **Turn 6** (1201ms): `{"action": "edit_line", "old_text": "ProxyJump server1", "new_text": ""}`
- **Turn 7** (1866ms): `{"action": "edit_line", "old_text": "Host server3\n    HostName server3\n    User deploy\n    Port 22\n    ProxyJump server1", "new_text": "Host server3\n    HostName server3\n    User deploy\n    Port 22"}` — C99(rc=1, violations=13)
- **Turn 8** (837ms): `{"action": "test_connection"}` — QEMU(rc=255, stdio forwarding failed) | C99(rc=1, violations=13)

### `@cf/meta/llama-3.3-70b-instruct-fp8-fast` — `stanza_scoped_tool` (FAIL)

- **Identified Precedence Root Cause (`Host *` / first-match)**: `False`
- **Stanza Locality Bias Observed**: `True` (2 biased edits)
- **Final QEMU Check**: exit `255` -> `ssh: connect to host server2 port 2222: Connection timed out`
- **Final C99 Preflight (`server2`)**: exit `1` -> `[PREFLIGHT VIOLATION 1] Directive 'User' for host 'server1' (line 45, val: 'deploy') is completely SHADOWED by earlier 'Host *.compute.internal server?' at line 31 (val: 'root') (+13 more)`

- **Turn 1** (708ms): `{"action": "read_config"}`
- **Turn 2** (14478ms): `{"action": "set_proxy_jump", "host": "server2", "proxy_jump": "bastion-gateway"}` — LOCALITY_BIASED_EDIT | C99(rc=1, violations=14)
- **Turn 3** (1111ms): `{"action": "test_connection"}` — QEMU(rc=255, jumphost loop via server3) | C99(rc=1, violations=14)
- **Turn 4** (1070ms): `{"action": "set_proxy_jump", "host": "server2", "proxy_jump": "none"}` — LOCALITY_BIASED_EDIT | C99(rc=1, violations=14)
- **Turn 5** (925ms): `{"action": "test_connection"}` — QEMU(rc=255, jumphost loop via server3) | C99(rc=1, violations=14)
- **Turn 6** (1115ms): `{"action": "set_proxy_jump", "host": "!server1 server*", "proxy_jump": "none"}` — C99(rc=1, violations=14)
