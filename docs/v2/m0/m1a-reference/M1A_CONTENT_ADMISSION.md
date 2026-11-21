# Retained content admission contract

Version: `m1a-content-reference-1`, 2026-11-20. **DRAFT / OWNER APPROVAL PENDING**.
Applies to the pure retained content subset, not V2 public-control encoding.
Status distinctions and scope: [closure](M1A_REFERENCE_CLOSURE.md).

## The discrepancy, established from source

In [Snapshot](../../../../lib/yeokcham_snapshot/yeokcham_snapshot.ml),
`inline_file_limit = 64 * 1024`; `Content.store` emits Content for **file byte
length <=65536** and delegates larger bytes to `Manifest.store_bytes`.
`Content.decode` verifies version/shape/bytes but does not check this threshold.
`Content.load_bounded` decodes the inline object before applying its display
bound. `Manifest.check_representation`, unlike Content.decode, refuses total
length <=65536. Manifest decoding alone is not full chunk/hash/cut verification;
`verify_stream` checks that closure. Regular-file capture uses the same file
length threshold. These are actual source behaviors, not inferred encoder sizes.

The extracted OCaml functions reproduce both writer branching and oversized
inline readability. Fixture adapters do not prove native storage or all reader
paths. The exact source/extraction hashes are in the evidence JSON.

Let P(n)[i]=(17*i+floor(i/256)) mod 256. The observed canonical writer choices:

| File bytes | Construction | Writer | Encoded inline envelope length if constructed | Proposed strict reader |
| ---: | --- | --- | ---: | --- |
| 0 | empty | Content1 | 60 | Canonical |
| 1 | NUL | Content1 | 61 | Canonical |
| 65535 | P(65535) | Content1 | 65597 | Canonical |
| 65536 | P(65536) | Content1 | 65600 | Canonical |
| 65537 | P(65537) | Manifest14, one EOF chunk | 65601 | Manifest closure canonical; inline form is NoncanonicalRepresentation |
| 200000 | P(200000) | Manifest14 | not emitted inline | Verify exact chunks at 131072/200000 |
| 1048589 | P(1048589) | Manifest14 | not emitted inline | Verify forced maximum cuts and final 13 bytes |

The two-byte jump in CBOR length-header width at 65536 explains the encoded
lengths, not the admission discrepancy. No inclusive/exclusive writer ambiguity
remains. The mismatch is **canonical writer representation versus reader
admission**, not a checksum limit, compression, filename or envelope limit.
The store's 128 MiB envelope cap is separate from both file size and inline limit.

## Recommended Python policy (CLOSED_BY_SPECIFICATION, pending owner choice)

1. Canonical writer: <=65536 bytes emits Content1, larger content emits exactly
   the existing chunk algorithm and Manifest14. No alternative writer cutoff.
2. Strict content admission: validate complete envelope, payload and closure;
   require that canonical writer representation, including canonical cuts. A
   valid oversized inline object returns **NoncanonicalRepresentation**.
3. Explicit legacy inspection: validate framing/checksum/identity/canonical CBOR
   and shape under the same resource limits, then return bytes labelled
   **LegacyReadableNoncanonical** for oversized Content1. No verified-mutation
   admission, availability promotion or automatic conversion follows. This is
   read-only and never an implicit fallback from strict validation.
4. Corrupt/truncated/noncanonical CBOR/unsupported/missing inputs still refuse in
   inspection mode. “Legacy” is not a bypass for malformed encodings or false IDs.
5. Retain the original bytes/StoredObjectId of any inspected legacy object.
   A later explicit export/import conversion may produce a manifest and new
   StoredObjectId with a mapping, never overwrite or relabel the old object.

This preserves canonical identities from the existing writer. It intentionally
narrows verified admission relative to the permissive OCaml inline reader;
legacy repositories containing manually produced oversized inline objects are
**inspectable**, not automatically writable/migrated. The proposed choice must
be approved before exposing the M1a.1 reader API. It is not a V1 contract edit.

## Exact retained bytes and identities

All integers below use the existing restricted canonical CBOR, not a new wire
schema. Envelope object-format=1, encoding-profile=1, feature bits=0.

| Kind | Canonical payload / context |
| --- | --- |
| 1 Content | `[1, file_bytes]`; canonical length 0..65536 |
| 13 Chunk | `[1, chunk_bytes]`; separate kind/domain even for equal payloads. Standalone legacy Chunk decoding is not by itself proof of canonical placement in a manifest. |
| 14 Manifest | `[1,total,1,64,16384,65536,131072,full_content_id,[[chunk_id,length],...]]` |
| 2 Tree | `[1,entries]`; File entry `[0,name_bytes,mode,content_id]`, Directory entry `[1,name_bytes,tree_id]` |
| 3 Snapshot | `[1,root_tree_id]` |

Envelope prefix is `YEOK` + u8 envelope version1 + u8 kind + u16BE object
format1 + u64BE features0 + u8 encoding1 + u64BE payload length. Prefix length25;
checksum32=`SHA256(prefix || payload)`; full envelope=`prefix || checksum || payload`.
`StoredObjectId=SHA256(b"yeokcham:object:v1\0" || envelope)`.
`FullContentId=SHA256(b"yeokcham:content:v1\0" || complete_file_bytes)`.
These are different typed identities. Existing Core record-ID hashes need not
equal StoredObjectId: the old Core vectors hash their envelope directly. Do not
unify ID wrappers just because both carry 32 bytes.

Retained algorithm1 uses window64/min16384/average65536/max131072, the existing
256-entry table and continuous rolling state across chunk boundaries. Cut at
max size or after min when low16 rolling bits are zero; emit nonempty EOF
remainder, never a trailing empty chunk. File content IDs ignore chunk layout;
strict manifest admission does not. Exact generators and table hash are in
[manifest](M1A_VECTOR_MANIFEST.md).

Manifest total/ref lengths use **1..2^62-1**, the established 64-bit OCaml native
integer semantic range, and total must exceed65536. A canonical chunk is positive
and at most131072; the last can be shorter than16384. Reference lengths sum
exactly to total; every referenced object has kind13, exact schema/length and
matching ID/checksum; concatenated bytes have the claimed FullContentId and
recomputed canonical cuts. Repeated chunk IDs are valid for repeated data;
reference **order and multiplicity** are material, not a set. A forged total,
validly hashed wrong-kind object or missing chunk is never empty content.

`ContentId` permits Content1 or Manifest14 only; Tree/Snapshot/Chunk/FullContent
IDs remain distinct wrappers and must be checked at resolution. Workspace16 /
public record32 identities in symbolic cases are not content-ID aliases.
No V2 candidate/accepted/resolution or plan wire type is chosen here.

## Structural validation and work bounds

These are proposed M1a.1 test requirements. Retained format rules are separated
from **local operational limits**, whose refusal does not assert format invalidity.

| Layer | Exact requirement |
| --- | --- |
| Bytes/envelope | Bound input before materializing it: maximum envelope128*1024*1024 bytes; header57; check declared length <=signed-int64 and <=cap-57 without arithmetic overflow; require exact length, no trailing bytes. Check checksum and requested object hash before interpreting payload semantics. |
| Framing/version | Unknown envelope/object-format/encoding version, feature bits or known-but-unimplemented kind -> UnsupportedFormat. No retry using another schema, no new registry allocation. M1a.1 supports only kinds1/2/3/13/14. |
| Generic CBOR | Minimal additional arguments, definite lengths, strict UTF-8 text, signed int64 values (-2^63..2^63-1), bytes distinct from text. Permit only integer/bytes/text/array/nonnegative-integer-key map/bool/null. Reject tag/float/simple-other/indefinite/reserved arguments, duplicate or descending keys, invalid UTF-8 and trailing data. Sparse increasing keys are valid generic CBOR. |
| Generic work | Maximum64 nested containers, 131200 total decoded items including containers and map keys/values, counted before entering/allocating. Root scalar depth0; an empty container at depth64 would exceed the container bound. Before a container allocation, arity must fit remaining input (at least one byte/item) and remaining item budget. Before a byte/text allocation, length must fit remaining input and input cap. Never trust a huge declared count for preallocation. These numeric work limits are operational, not a changed historic hash format. |
| Exact payloads | Positional arrays and entry lengths exactly as above, schema1, exact scalar kinds, no extras/nulls/optional omissions. Bool is not integer even in Python. IDs exactly32 bytes. Generic null support does not make null a valid content field. Wrong concrete scalar/arity -> InvalidContent; integer schema versions other than1 -> UnsupportedFormat. |
| Names/paths | Raw byte component nonempty, not dot/dotdot, no slash or NUL. Entries strictly ascending unsigned byte lexicographic order; no duplicates. Do not casefold/normalize/decode names for identity. Empty directory has a real Tree object. A path is a tuple of valid components, not an unchecked joined platform string; root is empty tuple. |
| Modes/tree | mode0 regular,1 executable,2 symlink. An entry is file OR directory; no file with descendants, no silently synthesized/deleted parents. Symlink target is logical content bytes, not host Unicode; native path/target/NUL and representability restrictions belong to M2/M8. |
| Resolver closure | Requested identity/type/schema/bytes must match; DFS colors reject cycles as InvalidContent and distinguish completed shared subtrees from active recursion. Missing object -> Unavailable. Same object at two paths is legal. |
| Tree traversal work | For the first implementation, explicit request budget: maximum65536 distinct resolved objects, dependency depth256, maximum1048576 expanded entries/paths and 64MiB cumulative raw path-component bytes. Charge expanded occurrences, not just unique tree IDs, before enqueuing children/output paths. Exhaustion -> ResourceLimit. No recursive flattening before guards. These are conservative proposed local limits; no claim all existing huge trees are invalid. |
| Streaming | Never allocate manifest.total bytes merely because the manifest says so. Stream chunks with incremental full hash and cut verifier; require finite source/sink backpressure. Display bound governs returned bytes only, not validation coverage. Bound zero must still validate every dependency; a resource/missing/corrupt result may never be returned as successful None. |

The parser corpus exercises depth64/65, item-count limits and int64 boundaries;
manifest negatives exercise the smaller2^62 bound. It does not establish peak
RSS or throughput at128MiB. Production tests must add cap-1/cap/cap+1 via bounded
streams, declared gigantic lengths without allocation, deep/broad shared-tree
expansion, cycle injection, budget-before-read and streaming/zero-display checks.
These are implementation exit tests; the finite corpus is not runtime certification.

## Deterministic refusal classification

Process one layer at a time: input-work guard; envelope fixed header/declared
length/version; exact framing; checksum/requested ID; bounded CBOR; exact payload
shape; representation and dependency closure in declared order. Do not suppress
an earlier failure to prefer a later category. For the supplied ambiguous
multi-fault bytes, the JSON expected category is the precise test oracle.

| Result | Meaning |
| --- | --- |
| InvalidEncoding | Malformed/truncated/nonminimal bytes, illegal generic kinds/key order/UTF-8, impossible signed length |
| UnsupportedFormat | Structurally readable unsupported version/kind/features/profile/algorithm parameters; no guessed interpretation |
| InvalidContent | Wrong concrete payload shape/types/mode/name/ID length, impossible length totals or cycle |
| NoncanonicalRepresentation | Canonical CBOR/envelope but wrong canonical content representation/cuts (including oversized inline and short manifest) |
| IntegrityFailure | Checksum/requested-object-ID/actual chunk length/full-content hash or claimed derived result differs |
| Unavailable | Required verified bytes/facts absent; never synonymous with Absent path |
| ResourceLimit | Operational byte/depth/item/traversal budget exhausted before unsafe work |

Semantic composition additionally returns Conflicted, ChoiceRequired or Stale;
those are not parser errors. Unsupported algorithm parameters are deliberately
not retried as a permissive arbitrary chunk profile. Validating content says
nothing about authority, publication, receipt or acceptance.

## Required first Python tests

Consume the frozen corpus using an independently implemented production codec;
do not import either fixture implementation into product code. Assert exact
positive envelopes/IDs/cuts/tree bytes; all109 finite negative classifications;
strict/legacy separation; bool/int and sparse-map behavior. Add the streaming,
zero-display, resource-preallocation and resolver/tree bounds above. Exercise
names, modes, empty directories and logical links entirely in memory. Keep
non-UTF-8/native filesystem qualification separate. No old fixture is rewritten
when a new implementation disagrees: report the smallest discrepancy first.
