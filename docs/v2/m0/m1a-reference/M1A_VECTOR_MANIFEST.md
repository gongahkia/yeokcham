# M1a independent vector manifest

Version: `m1a-vector-reference-1`, 2026-11-20. **DRAFT / OWNER APPROVAL PENDING**.
Machine inventory: [content-vectors.json](content-vectors.json), format
`yeokcham-m1a-content-reference-1`. All full expected object IDs, payload/envelope
hashes, lengths, recipes and negative outcomes are there; short examples here
do not replace the machine inventory.

## Methods and independence

* [Emitter A](emit_content_reference.py) constructs fixture-only recursive CBOR,
  Envelope-1 and chunk closures with a rolling ring buffer. It imports no
  Yeokcham implementation or verifier. It can write only into a **new external**
  directory; it cannot regenerate old goldens or update this manifest in place.
* [Verifier B](verify_content_reference.py) uses its own bounded CBOR reader,
  iterative stack encoder and prefix-recurrence chunker; it does not import A
  or product code. P(n) is independently reconstructed blockwise. B resolves
  every positive tree and chunk closure, rehashes objects and checks the frozen
  manifest against a fresh emission. This is a small fixture checker, not a
  streaming production parser or resource-qualified store.
* [OCaml probe](probe_ocaml_reference.py) compiles exact copied Encoding,
  Chunking and Line_hunks sources externally. It extracts Content payload/store/
  decode with helpers, using fixture adapters to observe writer branch and
  encoded inline bytes. It compares chunk boundaries, table, generic CBOR and
  inline readability. It is **not** a second independent implementation; it
  anchors A/B to actual source. It does not exercise the full store.

A and B share only specified constants, recipes, standard-library SHA-256 and
the expected manifest interface, not encoder/chunker functions. They were
written during the same review, not by independent teams; independent reviewer
sign-off remains desirable. No independent cryptographic implementation or new
signed-record expected hash is claimed. Complete source/extraction/program and
observation hashes are in [evidence](qualification-evidence.json).

For B's chunk recurrence, prefix H[n]=rotl(H[n-1],1) xor table[byte]. At window64,
the rolling window hash is H[n] xor H[n-64], since rotation by64 is identity.
This differs structurally from A's ring-buffer eviction. Both preserve rolling
state across cuts and compare with the source chunker's feed/finish results.

## Deterministic corpus

P(n)[i]=(17*i+floor(i/256)) mod256. `noise(n)` concatenates
SHA256(`b"yeokcham-reference-noise-v1" || u64BE(counter)`) for counters starting0,
then truncates to n. No process RNG or platform newline translation is used.
Every file case also has an exact regular-file tree at raw name `b"file"` and
Snapshot3 closure; all chunk IDs/lengths and full-file hashes are recorded.

| Case | Exact bytes / length | Canonical result / observed cuts |
| --- | --- | --- |
| RC01-empty | empty /0 | Content1 |
| RC01-one | hex00 /1 | Content1 |
| RC01-P65535 | P(65535) | Content1 |
| RC01-P65536 | P(65536) | Content1, inclusive threshold |
| RC01-P65537 | P(65537) | Manifest14; EOF65537 |
| RC02-P200000 | P(200000) | Manifest;131072,200000 |
| RC02-P1048589 | P(1048589) | Manifest; multiples131072 through1048576, then1048589 |
| RC02-zero262145 | NUL repeated262145 | Manifest; multiples16384 through262144, then262145 |
| SUP-repeat1-262145 | byte01 repeated262145 | Manifest;131072,262144,262145 |
| SUP-noise262145 | noise(262145) | Manifest;86659,217731,262145; natural plus forced-max boundaries |
| SUP-crlf | hex610d0a62 /4 | Content1; no newline normalization |
| SUP-lf | hex610a62 /3 | Content1; distinct from CRLF |
| SUP-final-lf | hex610a620a /4 | Content1; distinct final newline |
| SUP-binary | hex00ff /2 | Content1; binary allowed as content |

RC02's three original constructions exercise feed1,63,64,65,16384,65536 and
whole input; the OCaml probe additionally checks whole-input repeated/noise and
the65537 boundary (24 feed comparisons total). This is not an exhaustive test of
all possible segmentation schedules or all rolling states.

Selected **independently re-encoded/rehashed** StoredObjectIds:

| Object | Expected StoredObjectId |
| --- | --- |
| Empty Content1 | `50cd1f564caf33ace22a7be58ac04ba5b4a91acccc2c1e1c0b0bcb05b9d448ed` |
| Content1 P(65536) | `49099cb3030288bcc95fa9f87d5be4ff6d0a8a3b870efcce62978e97ee35809b` |
| Manifest14 P(65537) | `63b02a8bc2e9a25b1f61ed70a342f0e8714d2a67040518b288ecf80effe839de` |
| Legacy inline P(65537) | `814bfac450c0344bf3f665ae528687a058eb1ac77680c52b016ebc340813ccb2` |
| RC03 mixed Tree2 | `b3ce5c213568e765f4c55c2a6bc58031f11a7bb3dc2a4ae9d700aaa127c5a599` |
| RC03 mixed Snapshot3 | `428a11ac0177be7de0f0f0f10d782833b626731d655b08a32c4aa85a3e844ff4` |

The table SHA-256 over256 unsigned BE64 entries is
`2f6ff9d9844a9b987bd6ad9609ee980711be326dd6c96fca120bd9caa273d32f`.
The table seed is0x6a09e667f3bcc909; each next unsigned64 state is
`6364136223846793005*state+1442695040888963407 mod2^64` and becomes the entry.

RC03 exact tree (mode0 regular,1 executable,2 symlink):

```text
b"A"       File(0, b"a\r\nb")
b"bad-\xff" File(0, b"\x00\xff")
b"empty"   Directory(empty)
b"link"    File(2, b"missing/target")
b"nested"  Directory({b"note": File(0, b"end\n")})
b"run"     File(1, b"#!/bin/sh\nexit 0\n")
```

RC04 uses identical `b"same\n"` at positions/modes recorded in the emitter and
machine manifest. Tree/snapshot positions and executable modes differ while
FullContentId stays equal. Content1 and Chunk13 with the same payload have
different StoredObjectIds. Distinct local identities `(b"w"*16,7)` and
`(b"w"*16,8)` reference the same snapshot; only their exact pair encodings are
shown, not a fabricated future local-history record hash.

## Invalid corpus, admission and coverage

There are **109 exact negative cases**, not109 distinct formats. All57 short
envelope prefixes0..56 are counted individually. Objects for some negatives are
well-framed/checksummed but intentionally invalid content. The `objects` inventory
of103 envelopes therefore includes invalid fixtures; it is not103 admitted objects.

| Family | Inputs and expected validation boundary |
| --- | --- |
| RC05 | Missing first chunk; altered bytes/checksum; wrong referenced kind; actual/ref/total lengths; incorrect FullContentId; total<=65536; early noncanonical cut; unsupported chunk parameters/version; bool/int confusion; 2^62 semantic overflow. Exact categories in JSON |
| RC06 names/tree | Empty/dot/dotdot/slash/NUL names; duplicate or descending raw byte names; invalid mode and scalar kinds; wrong array shape and ID lengths |
| RC06 CBOR | Nonminimal integer/length, indefinite, tag, float, malformed UTF-8, duplicate/descending keys, bool as schema integer, trailing bytes; depth65 and aggregate item overflow |
| RC06 envelope | Every short header, magic/version/length/checksum/kind/object-format/features mutations, multiple-fault checksum/kind case, oversized declared length and signed-length overflow |
| RC07 | Canonical-CBOR/checksummed inline65537: strict NoncanonicalRepresentation; explicit inspection LegacyReadableNoncanonical. Equivalent canonical manifest is independently verified |

Nineteen generic positives include depth64, the exact item-budget edge, sparse
integer-key map, signed-int64 boundaries, scalar/byte/text length-header edges,
bool and null. Generic CBOR validity does not waive exact content payload shapes.
Unsupported values, malformed values and local resource refusal remain distinct.

All content byte constructions and retained schema/identity expectations are
proposed normative **reference inputs** for M1a.1 after owner approval. Native
non-UTF-8 names and symlink materialization are unsupported in this reference
stage. New local parsing/traversal work caps and RC07 mutation admission are
specification decisions, not historic V1 wire invariants. Whole-tree/budget
normalization JSON is finite symbolic evidence, not a new normative public format.

## Reproduction without touching fixtures

From checkout root, choose two nonexistent directories **outside** the checkout:

```sh
python3 -B docs/v2/m0/m1a-reference/emit_content_reference.py --out "$REF_OUT"
python3 -B docs/v2/m0/m1a-reference/verify_content_reference.py \
  --emission "$REF_OUT" --manifest docs/v2/m0/m1a-reference/content-vectors.json
python3 -B docs/v2/m0/m1a-reference/probe_ocaml_reference.py \
  --emission "$REF_OUT" --work "$REF_OCAML"
```

Set REF_OUT/REF_OCAML explicitly, e.g. under a disposable `mktemp -d` parent;
neither leaf may already exist. No live Yeokcham data. The emitter/probe enforce
external destinations. The verifier only reads. `-B` avoids checkout pycache.
The probe needs ocamlc but no project dependencies. Do not install one solely
to make a qualification claim. Full project compiler/providers are separate gates.

Fresh reproduction on this review host:14 files,103 envelopes,109 negatives,
mixed tree/identity/legacy agreement;100 source canonical payload roundtrips,
24 chunk-feed comparisons,14 writer branch comparisons,30 bounded source CBOR
comparisons. Three intentionally malformed CBOR payloads are not counted as
canonical source roundtrips. No benchmark or performance result is implied.

`normalization-observations.json` preserves fixture facts, exact finite outputs,
the nonconfluence witness and independent budget/structural observations. The
temporary symbolic programs remained outside the repository, with their hashes
and paths in evidence; only content fixture generators are delivered. Their
pseudocode and exact inputs are sufficient for a new independent implementation,
but the disposable programs themselves are not a maintained test suite.

## Existing and future vectors

No old golden changed. See [M0 complete inventory](../M0_VECTOR_INVENTORY.md)
for74 existing files and historical34 comparisons. This review freshly checks
four existing Core envelopes' length/checksum/old record-ID hash, not their
Ed25519 signatures. Old controls remain inspection references only; new
candidate/accepted semantics cannot reuse old kinds/domains. No retained format
hash here licenses opening an OCaml repository for Python writes.

Before M4, independently generate candidate48/accepted49/branch50/resolution51
vectors **only after** registry re-audit/allocation, payload ordering/bounds,
PublicBasis variants, scope/proof dependencies, OriginRef/choice encoding,
profile/capability and fresh signing-domain freeze. Require full body, signing
input, signature, envelope, logical/stored IDs and malformed/missing/cycle/
cross-repository/authority/version negatives. Proposed numbers remain reservations,
not implemented registration. Before M1b/M2, private plan/action/destination claim
encodings need their own exact vectors. Those byte values remain **OPEN**;
this corpus contains no invented expected signed hashes or public controls.
