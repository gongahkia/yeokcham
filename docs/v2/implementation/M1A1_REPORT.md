# M1a.1 implementation report

Date: 2026-11-21, Singapore. **Verdict: PASS within the verified M1a.1 scope.**
No later tranche was authorized or implemented. This is not VCS parity, platform
qualification, migration approval or a claim that the original CI blocker is fixed.

## Source, authorization and preservation

Initial and final source HEAD: `c9b507f5ff321d391342cf01267b87eb341dd73c`.
Initial tree: clean `main...origin/main`; no staged, unstaged or nonignored
untracked files. The historical staged reference emitter mentioned by the owner
is now committed; there was no staged version to alter. Neither `python/` nor
this report existed. No Git write, commit, push, checkout, reset or cleanup ran.

The owner explicitly approved strict oversized-inline rejection and separate
bounded legacy inspection for this tranche. That supersedes the pending RC07
choice in the reference handoff, without changing that document or V1 contracts.
D4/M0 corrections take precedence over incompatible old D2/D3 proposals; no
normalization algorithm or public control was implemented here.

A before/after inventory checks SHA-256 and native modes for all 532 pre-existing
tracked/nonignored untracked files. All remain unchanged. Existing goldens,
reference generators, research, source, README and ledgers were preserved.
Runtime/test/build artifacts went to external temporary directories or ignored
new-package build directories. An initial mypy invocation created its own root
cache; its files were checked as newer than the initial manifest, removed, and
subsequent mypy runs use an external cache. No pre-existing cache was removed.

## Delivered responsibilities

- [identities.py](../../../python/src/yeokcham/identities.py): immutable nominal
  repository/workspace/stored/content/full-content/tree/snapshot/chunk/record IDs;
  exact byte/hex validation and workspace/sequence capture identity. Different
  ID classes are unequal; API boundaries reject unintended substitutions.
- [codec.py](../../../python/src/yeokcham/codec.py): restricted deterministic CBOR,
  minimal arguments, int64, ordered nonnegative integer map keys, strict UTF-8,
  preallocation/depth/item guards; Envelope-1 framing/checksum/object hash;
  bounded injected-stream framing. Only kinds 1/2/3/13/14 are supported.
- [content.py](../../../python/src/yeokcham/content.py): feed-independent Buzhash,
  canonical streaming content construction through an injected sink, typed tree/
  snapshot encoding, strict complete-closure verification and explicit legacy
  inspection through an injected resolver. Logical trees retain raw names,
  empty directories, executable distinction and symlink-target bytes.
- [errors.py](../../../python/src/yeokcham/errors.py): inspectable `ContentError`
  with the seven qualified refusal categories. Programmer/type errors use
  TypeError/ValueError; malformed serialized inputs use structured refusals.
- [pyproject.toml](../../../python/pyproject.toml): isolated setuptools package,
  Python >=3.13 declaration, no runtime dependencies and no executable entry point.
  `py.typed` is included in the wheel. Tests and tooling are explicit optional extras.
- [tests](../../../python/tests/test_core.py) and its fixture adapter: behavioral
  ports of OCaml content-verification/encoding/chunking/snapshot obligations,
  independent frozen vectors, adversarial cases and Hypothesis properties.

No production code imports the fixture emitter/verifier. Tests run the unchanged
emitter in an external directory and compare against the unchanged frozen
manifest before using its raw object fixtures. No expected value is regenerated
from the production function under test.

## Test-first record

Only packaging and an empty package marker existed before the first tests.
Implementation imports are inside test functions so missing functionality is a
test failure rather than a collection/harness failure.

| Stage | Actual observation |
| --- | --- |
| RED 1 | Full initial suite: **159 failed** in 14.99s. Focused first failure: `cannot import name 'identities' from 'yeokcham'`, identifying the installed empty package at the intended source path. The package and fixture harness were present; implementation modules were absent. |
| GREEN 1 | Minimal identity/codec/chunker/content/resolver implementation: **159 passed**, 40.26s. |
| RED 2 | Repeated-zero thresholds, early declared-size overrun, typed tree writers: **4 failed, 5 passed, 159 deselected**. Zero input at 65535/65536 incorrectly selected manifest based on early chunk cuts; the source overrun was consumed too far; typed writers were absent. |
| GREEN 2 | Buffer a bounded chunk prefix until total exceeds the inline threshold; validate feed lengths before consumption; implement typed tree/snapshot writers: **168 passed**, 41.85s. |
| RED 3 | Four attempts to increase qualified parser limits: **4 failed**. |
| RED 4 | Bounded stream framing: **1 failed** because `read_envelope` was absent. |
| GREEN / refactor | Implement guards/stream framing; remove duplication and unused bindings, sort imports and format only new Python files: **175 passed**, 45.14s. |
| RED 5 | Attempts to increase tree work limits: **4 failed**. An edit targeting pre-format text did not apply; the subsequent broad verification still reported **4 failed, 175 passed**. The actual formatted block was corrected; focused verification then reported **4 passed, 175 deselected**. |
| Final VERIFY | Add independent feed-boundary checks and payload-corruption properties; strict typing/lint/format and full post-refactor suite: **195 passed, 0 failed, 0 errors, 0 skipped**, 44.67s. |

The immutable evidence is these observations and failure reasons, not a promise
that external temporary log paths survive. This report records the failures;
none was hidden by changing a normative oracle or weakening an assertion.

## Compatibility, negative cases and properties

Final suite: **195 collected tests**. Normative partitions are **14 positive file
cases**, **19 positive generic-CBOR cases**, and **109 negative cases with exact
refusal classifications**. The other 53 tests cover identity boundaries, mixed
fidelity, tree writers, work guards, streaming, corruption and properties.
One parameterized test may contain several positive and negative assertions.
All **103 distinct frozen object envelopes** round-trip byte-for-byte, including
object identity and payload hash checks. All 14 writer roots and every emitted
object match independent expected bytes. Fifteen additional tests compare the
three RC02 inputs at feed sizes 1/64/65/16384/65536; whole and 63-byte feeds are
also exercised by file/writer checks. No original vector was modified.

Actual Hypothesis statistics from the final run:

| Property | Passing examples | Failing | Invalid generated candidates |
| --- | ---: | ---: | ---: |
| Recursive supported-value canonical round-trip/determinism | 100 | 0 | 18 (recursive strategy leaf-budget retries) |
| Feed independence and exact reassembly | 30 | 0 | 0 |
| Arbitrary malformed bytes yield structured refusal or exact canonical round-trip | 150 | 0 | 0 |
| Payload corruption cannot be admitted, even with display bound zero | 30 | 0 | 0 |

These are 310 passing generated examples, not 310 additional collected tests.
They are finite testing, not a proof or exhaustive fuzz campaign.

Inline writing uses **file byte length**, inclusive 65536, regardless of encoded
length or early chunk cuts. Explicit tests cover 0/1/16384/65535/65536/65537/200000
zero bytes plus the independent patterned/binary corpus. Larger files are
manifest/chunk closures. Declared-size under/overruns refuse. Normal verification
rejects oversized inline content. `inspect_legacy` preserves the original ID,
returns `LegacyReadableNoncanonical`, and neither writes nor promotes admission.
Missing/corrupt dependencies still refuse when display bytes are omitted.

Resolver verification checks every requested hash, envelope, schema, referenced
kind, length, full-content digest and canonical cut sequence. Trees enforce raw
name order, exact entry/mode/reference types, traversal depth, expanded path/byte
budgets and active-ancestry cycle checks. Shared subtrees are legal. A missing
object is Unavailable, never an empty file or absent path. No verified-root-only
cache bypasses later dependency checks.

## Commands and environment

Observed host: Linux 7.2.15-1-omarchy x86_64/glibc 2.44, CPython **3.14.8**.
No OCaml/Dune/opam is available on PATH; no new OCaml runtime differential,
project build/CI, native or power-loss experiment ran. The checked-in OCaml
5.5.1 reference observations remain historical, anchored by unchanged sources.
Only this Python/host combination was exercised; >=3.13 is a declared floor,
not evidence that 3.13 or another platform was tested.

Runtime dependencies: **none**. Isolated observed tools: pytest 9.2.0,
Hypothesis 6.170.17, Ruff 0.17.6, mypy 2.4.1, build 1.6.1. Their transitive
packages and build-isolation setuptools were installed only in temporary virtual
environments. System Python/tooling was not modified.

Reproduce from repository root (requires an available supported Python and network
for installing the declared development extras):

```sh
task_tmp=$(mktemp -d)
python3 -m venv "$task_tmp/env"
"$task_tmp/env/bin/python" -m pip install -e './python[test,dev]'
PYTHONDONTWRITEBYTECODE=1 HYPOTHESIS_STORAGE_DIRECTORY="$task_tmp/hypothesis" \
  "$task_tmp/env/bin/python" -m pytest python/tests \
  --basetemp="$task_tmp/tests" -p no:cacheprovider --hypothesis-show-statistics
"$task_tmp/env/bin/ruff" check --no-cache python
"$task_tmp/env/bin/ruff" format --no-cache --check python
"$task_tmp/env/bin/mypy" --config-file python/pyproject.toml \
  --cache-dir "$task_tmp/mypy" python/src
"$task_tmp/env/bin/python" -m build python --outdir "$task_tmp/dist"
python3 -B tools/check_doc_links.py
```

All final checks above pass. The wheel and source distribution built successfully.
The wheel was installed with `--no-deps` into a second clean temporary environment;
`python -I` outside the checkout imported that installed package, round-tripped
binary bytes through the resolver API, and checked there are **no CLI entry
points**. Strict mypy checks all five source modules. Ruff checks seven Python
files. Build/test outputs are not production persistence or a replacement command.

## Limits, unsupported capabilities and next dependencies

- Work bounds are enforced refusals, not claims that larger histories are invalid.
  Content writing conservatively caps manifest references at 40000 and tree
  writing at 40000 entries before codec item accounting. Decoder limits may only
  be reduced; default traversal caps follow the qualified contract. No claim of
  arbitrary-size repositories, mature throughput or full-128-MiB peak-RSS behavior.
- The 4-MiB streamed chunking test measures tracemalloc peak below 2 MiB. It does
  not retain all chunks, and does not measure process RSS, caller-owned input,
  native allocations or every writer/resolver workload. Content verification
  buffers returned display bytes only when the caller explicitly allows the full
  length. Tree results are bounded by configured entry/path limits, not pagination.
- A resolver must honor its byte-return contract and enforce the object cap before
  its own allocation; caller-internal allocation/IO cannot be controlled here.
  Injected byte streams must honor read(n). An injected sink can receive unrooted
  chunks before a later writer refusal; no atomic storage transaction is claimed.
- Byte/hash validation makes forged cycle references fail integrity first;
  structural ancestry guards also exist. Native name/link representability,
  directory races, durable capture counters and identity allocation are not tested
  or implemented. No Python hash-table hash is a persistent identity.
- No normalization, candidate/acceptance/signing/authority API, SQLite store,
  GC, restoration, capture daemon, transport, archive, migration, agent system or
  full CLI is included. No live `.yeokcham` directory was created or opened.
- M1a.2 still needs independently executable general subtree-resolution,
  correspondence, long-DAG and default-budget saturation qualification. It is the
  proposed next pure semantic tranche, not authorized by this work.
- M1b still needs authoritative SQL/plan/request/root schemas, ownership and
  uncertain-commit/GC/backup process-fault tests. M2 still needs exact native
  action/DestinationClaim encodings, absent-destination race/flush qualification
  and discriminating copy-out recovery tests. **BASELINE-COPYOUT-20261116 remains
  unresolved; its root cause is unknown.** M4/M5 public protocol/trust vectors
  and all later service/review/archive/platform gates remain separate.

M1a.1 implementation completed to the extent verified. No later tranche was authorized.
