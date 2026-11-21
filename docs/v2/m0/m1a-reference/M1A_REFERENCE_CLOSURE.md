# M1a reference qualification

Version: `m1a-reference-1`, 2026-11-20. **DRAFT / OWNER APPROVAL PENDING**.
This is reference evidence and a proposed implementation boundary, not an
implementation or approval of all D1–D4 contracts.

## Outcome

**M1A_PARTIALLY_READY.** The retained content/identity subset has sufficiently
specified inputs and independently checked examples for a separately authorized
M1a.1 implementation. Full candidate normalization is not qualified for production.
Do the content tranche next; do not start another general architecture review.

M1a.1 may implement typed content identities, the restricted canonical CBOR
profile, Envelope-1 validation, Content/Chunk/Manifest/Tree/Snapshot version 1,
canonical chunking, and complete content verification through an injected
read-only resolver. It may use an in-memory object sink in tests. It must not
open a repository, write a store, encode new public controls, infer authority,
normalize candidates, restore files or become the default executable.

The two consuming contracts are [content admission](M1A_CONTENT_ADMISSION.md)
and the [vector manifest](M1A_VECTOR_MANIFEST.md). The
[normalization contract](M1A_NORMALIZATION_CONTRACT.md) specifies proposed
charging and finite reference behavior, with its remaining gate stated explicitly.
The owner approved A–E as M0 planning assumptions, not the new admission policy
or a production implementation instruction.

## Exact RC dispositions

RC identifiers retain their definitions from
[M0 vector inventory, Reference corpus](../M0_VECTOR_INVENTORY.md).
“Reference verified” covers the named finite cases, not all inputs or a complete
OCaml/Python runtime equivalence proof.

| Case / exact existing definition | Intended invariant and method | Disposition for M1a |
| --- | --- | --- |
| RC01: empty, NUL, P(65535/65536/65537) inline boundaries | Source writer branch; A constructs complete closures, independent B reconstructs inputs/parses/encodes/hashes. Extracted OCaml writer agrees on all 14 corpus branch checks. Inclusive file-length threshold. | **CLOSED_REFERENCE_VERIFIED**, retained bytes; see RC07 for proposed reader policy |
| RC02: P(200000), P(1048589), zero×262145; feeds 1/63/64/65/16384/65536/whole | Ring-buffer A versus prefix-recurrence B, exact source OCaml chunker and 256-entry table; 24 feed comparisons including supplements agree. | **CLOSED_REFERENCE_VERIFIED**, finite segmentation/cut corpus |
| RC03: six named entries, nested note, empty directory, byte name bad-ff, executable and symlink | Complete raw-name order, mode and content closure; A recursive encoding versus B bounded parse and stack encoding; exact tree/snapshot hashes. | **CLOSED_REFERENCE_VERIFIED**, logical objects; native name/link representability **REQUIRES_RUNTIME_QUALIFICATION**, M2/M8 |
| RC04: same bytes at different positions/modes, Content versus Chunk, two capture IDs for one snapshot | Distinct domain/kind/tree/history identities; six manifest identity sections checked. Capture references are exact (workspace16, sequence7/8) tuples, not invented signed/local-history digests. | **CLOSED_REFERENCE_VERIFIED** for checked identity distinctions; durable capture allocation remains M1b/M2 |
| RC05: missing/corrupt/wrong-kind chunks, lengths/full ID, short manifest, noncanonical cuts/parameters | A mutations, B independently follows closure and checks all bytes/cuts. No display bound may hide corruption or absence. See negatives in JSON. | **CLOSED_REFERENCE_VERIFIED**, finite invalid corpus. Zero-display streaming integration remains a mandatory first Python test; no complete OCaml store test was run |
| RC06: invalid names, modes, canonical CBOR and envelopes | Exact negative bytes; B classifications; source Encoding roundtrips 100 payloads and agrees on 30 bounded generic positive/negative examples. Sparse integer maps accepted; exact record shapes enforced separately. | **CLOSED_REFERENCE_VERIFIED**, finite corpus. Physical allocation/RSS qualification and larger parser fuzzing **REQUIRES_RUNTIME_QUALIFICATION** |
| RC07: valid oversized inline P(65537) versus its canonical manifest | Source reader accepts larger inline; writer selects manifest. B checks strict refusal versus explicitly labelled legacy inspection. | Source asymmetry **CLOSED_REFERENCE_VERIFIED**; proposed two-mode admission policy **CLOSED_BY_SPECIFICATION**, owner decision before M1a.1 reader API |

Positive, boundary and negative inputs, expected categories and actual digests are
in [content-vectors.json](content-vectors.json). This table does not upgrade RC07's
policy decision into independent evidence of owner intent. None of RC01–RC07
requires new V2 public-record bytes; those encodings remain OPEN before M4.

## Source evidence and current observations

The authoritative source is the working tree, not an assumed earlier commit.
The captured source hashes and extracted-function hashes are in
[qualification-evidence.json](qualification-evidence.json).

| Source | Relevant implementation / existing tests |
| --- | --- |
| [Snapshot](../../../../lib/yeokcham_snapshot/yeokcham_snapshot.ml) | `inline_file_limit`, `Chunk`, `Manifest.decode/check_representation/verify_stream`, `Content.store/decode/load_bounded/verify`, `Tree`, `Snapshot` |
| [Chunking](../../../../lib/yeokcham_chunking/yeokcham_chunking.ml) | Algorithm/table, rolling window, feed/finish; source compiled externally |
| [Encoding](../../../../lib/yeokcham_encoding/yeokcham_encoding.ml) | Minimal arguments, int64, UTF-8, map order, construction and decoding limits |
| [Envelope](../../../../lib/yeokcham_envelope/yeokcham_envelope.ml), [Store](../../../../lib/yeokcham_store/yeokcham_store.ml) | Registry/framing/checksum, StoredObjectId and 128 MiB object-read cap |
| [Content verification tests](../../../../test/test_content_verification.ml) | Exact bounded reads at 0/1/65536/65537/1048589; zero-display still checks full hash/cuts; missing chunks and declared lengths |
| [Safe application tests](../../../../test/test_safe_apply.ml), [snapshot materialization](../../../../test/test_snapshot_materialize.ml) | Existing downstream consumers, not freshly executed here |
| [Composition](../../../../lib/yeokcham_v1_composition/yeokcham_v1_composition.ml), [line hunks](../../../../lib/yeokcham_v1_composition/line_hunks.ml), [tests](../../../../test/test_composition.ml), [graph tests](../../../../test/test_composition_graph.ml) | Whole-entry equality, separate mode/content selection, UTF-8/NUL/size/cell limits; D4 changes composition normalization, not these old wire records |

Fresh observations: A/B agree on 14 file constructions, 103 distinct object
envelopes, 109 rejection cases, one mixed tree, identity checks, two legacy modes
and 19 generic CBOR positives. Actual OCaml pure sources compiled with **5.5.1**;
this is not the pinned **5.5.0** full project build. Extracted Content writer
uses fixture Store/Manifest adapters to observe branching, not actual storage.
No full Snapshot/store, signature, native or SQLite runtime was exercised.

Four existing Core envelopes were freshly checked for framing, checksums and old
record-ID hashes, without regenerating fixtures or testing signatures. M0's 34
independent comparisons, 13 P01 receipt matches and 74-golden inventory remain
**historical M0 evidence**; this task does not claim another full 34-vector run.
`test/generate_core_vectors.py` writes its destination and was not run in place.

The normalization experiment checks all 22 M0 case groups against their stated
expectations; 100 applicable path-result comparisons agree between whole-tree
enumeration and subset DP. There are six causal receipt orders, six permutations
of a real nonconfluent witness, five ordinary leaf comparisons and three witness
trees checked with actual OCaml line hunks. Phase/private/authority cases are
conditional symbolic projections, not implementation of acceptance or recovery.

## Remaining prerequisites and implementation split

| Consumer | Input still required / prohibition |
| --- | --- |
| M1a.1 content | Owner chooses RC07 API policy and separately authorizes this isolated implementation. First tests consume the supplied corpus, verify display-bound independence, parser preallocation guards, streaming closure and source compatibility. No dependency installation is authorized here. |
| M1a.2 normalization | General subtree-resolution and known-present correspondence witnesses; saturation/large-DAG and long-history budget cases; exact executable charging/default qualification. Current small-case agreement is insufficient for full readiness. See normalization gate. |
| M1b | Exact authoritative schema/plans/root ownership/idempotency encoding; process/disk/fault matrix in M0/D4. No SQLite runtime safety claim follows from content references. |
| M2 | DestinationClaim/native observation/action encoding; absent-only destination races; recovery and complete-byte verification, unresolved copy-out issue. |
| M4/M5 | Exact public payload schemas, OriginRef/resolution encoding, signing/authority/capability vectors. Proposed registry reservations are not allocation or interoperability. |
| M3/M6/M7/M8 | Service/native/agent/security/platform gates retained from M0. Nothing here changes their dependencies or migration prohibitions. |

Host reference runs used CPython 3.15.0. The proposed product Python floor is
3.13; 3.13/3.14 tests and dependency/provider selection are not qualified here.
For M1a.1, a small restricted standard-library codec avoids making a general
CBOR package's permissive defaults part of the contract. This recommendation
does not approve a production dependency change or remove later provider gates.

**BASELINE-COPYOUT-20261116 remains unresolved**: historical fixture
`test/test_benchmark_runner.py::RunnerTests.test_resume_preserves_samples_and_refuses_changed_inputs`
reported `installed target bytes changed at "restored" after application`.
Root cause unknown; no fix, waiver, assertion weakening or fresh reproduction.
It gates M2/native rollout; isolated pure content work can proceed after its own
authorization. Preserve the M0/D4 discrimination tests and original evidence.

## Owner decisions and next prompt

1. Adopt RC07 strict canonical admission plus explicit bounded read-only legacy
   inspection, with no silent identity conversion, as specified here.
2. Separately authorize **M1a.1 retained content and identities only**, with tests
   on this corpus, no live-repository access or new default executable. Leave
   M1a.2 normalization and all later tranches gated.

Proposed next assignment: implement the isolated typed content/codec subset in
an explicitly experimental Python package and its tests; pin the package/test
paths in that instruction, use no SQLite/native/signing API, and require exact
corpus agreement, streaming verification even at display limit zero, malformed
input/resource refusals and CPython floor validation. Do not automatically begin.

## Repository preservation and verification record

Initial HEAD: `fb8e1989fb6e11b3b8c7bd9c5d90e751df1d10e7`; initial status
`## main...origin/main`, clean, no nonignored untracked files. Target directory
did not exist. A 522-file SHA-256/mode inventory was captured externally before
creation. Reference programs emit/compile only into new external directories.

Final HEAD/status and preservation results are recorded in
`qualification-evidence.json` under `repository_final`. This task ran no Git
write command. The index acquired a staged version of the new emitter during
review. [Inference] This is external activity; it was left intact. Any
subsequent external HEAD change is reported there separately. All delivered
files are new descendants of this directory; no old fixtures/source/RFCs were
rewritten. Ignored build caches are outside the 522-file inventory; no build,
CI, G01 rerun, active store operation, migration or production code occurred.
