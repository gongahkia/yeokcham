# M0 identity and vector inventory

Version: `m0-reference-1`. Recorded 2026-11-20.
Status: existing-byte inventory and future vector specification, not a new wire
freeze. No old fixture is modified and no V2 expected digest is fabricated.

Read with [baseline](M0_BASELINE.md), [semantic cases](M0_SEMANTIC_REFERENCE.md)
and [consumer gates](M0_SAFETY_AND_TRANCHE_GATES.md). Exact expected old bytes
remain in their original files; a fixture's existence does not establish a
successful current decoder test. Every digest below says what it hashes.

## Identity and retained formats

Authoritative sources: [encoding](../../../lib/yeokcham_encoding/yeokcham_encoding.ml),
[envelope registry](../../../lib/yeokcham_envelope/yeokcham_envelope.ml),
[store](../../../lib/yeokcham_store/yeokcham_store.ml),
[snapshot](../../../lib/yeokcham_snapshot/yeokcham_snapshot.ml),
[chunker](../../../lib/yeokcham_chunking/yeokcham_chunking.ml),
[old signed codec](../../../lib/yeokcham_v1_record/core_record.ml), and
[actual interfaces](../../implementation/INTERFACES.md#registry-and-canonical-bytes).
Do not use symbolic S/A labels as byte IDs or interchange these types:

| Identity | Exact formula / representation | M0 disposition |
| --- | --- | --- |
| StoredObjectId, 32 bytes | SHA256(`ASCII("yeokcham:object:v1") || 00 || canonical_envelope`) | Retain for unchanged object kinds |
| FullContentId, 32 bytes | SHA256(`ASCII("yeokcham:content:v1") || 00 || exact_file_bytes`) | Retain; distinct from stored inline/manifest ID |
| SnapshotId | StoredObjectId of a Snapshot envelope referencing a Tree | Retain exact bytes, not every old repository wrapper |
| RecordId, 32 bytes | SHA256(complete signed canonical envelope) | Old vectors prove old schema bytes; V2 envelopes intentionally new |
| RepositoryId | 32 opaque random bytes bound by authenticated genesis | Proposed V2 typed identity; not a path or content hash |
| Workspace/Branch/Change/OperationId | Distinct typed 16-byte random IDs | Existing widths retained; no lane ID |
| CaptureId | `[workspace_b16, sequence]`, `0..2^63-1` | Identity distinct from SnapshotId; SQL atomic allocation is later |
| PlanId | Proposed SHA256(`ASCII("yeokcham/plan/v2") || 00 || canonical_private_control`) | Formula retained for planning; control bytes OPEN, no valid expected ID yet |
| RequestKey | Opaque 1–128 bytes, scoped by action/caller/repository | Not authority/content identity; argument digest and retained result required |

`00` denotes one NUL byte; `||` means concatenation. Physical compression never
changes the canonical identity. Current global raw-object bound is 128 MiB;
this is not a total-file limit. Streaming manifests/chunks represent larger files.

| Format | Exact source-defined content | Compatibility / future check |
| --- | --- | --- |
| Restricted CBOR profile 1 | signed-int64 integer, bytes, strict UTF-8 text, arrays, nonnegative integer-key maps, bool/null; minimal encodings, strictly increasing map keys on decode; no floats/tags/indefinite/trailing forms | Retain. **Generic maps need not have consecutive keys**; old Core payload maps additionally require exact consecutive fields. Do not conflate these layers |
| Parser bounds | Generic construction nesting 64; old Core decoder depth 8, items 131,200, controls 8 MiB and reference sets 16,384 | Not a universal allocation budget for every kind. Proposed V2 depth 16 and same item/control/ref scalar bounds await complete schema/provider qualification |
| Envelope-1 / object format 1 | `YEOK`, u8 envelope version, u8 kind, u16be object format, u64be mandatory features, u8 checksum algorithm, u64be payload length; 25-byte prefix, 32-byte SHA256(prefix+payload), payload; 57-byte header | Retain framing/checksum/version axes; allocated kinds 1–47 unchanged; unknown features/type/version refuse |
| Content / code 1 | CBOR `[1, file_bytes]`, canonical storage for length <=65,536 | Retain; exact inline boundary required |
| Chunk / code 13 | CBOR `[1, chunk_bytes]`, separate envelope kind/domain-derived stored ID | Retain; equal payload alone does not equal Content object ID |
| File_manifest / code 14 | CBOR `[1,total_length,1,64,16384,65536,131072,full_content_b32,[[chunk_object_b32,length],...]]`; total >65,536 | Retain ordered chunk references, lengths/full digest and canonical boundary verification, not merely successful concatenation |
| Buzhash-v1 | Table seed `0x6a09e667f3bcc909`, 256 unsigned-64 recurrence values `state=state*6364136223846793005+1442695040888963407 mod 2^64`; rotate-left rolling hash; window 64, min/avg/max 16/64/128 KiB | Retain exact source recurrence and rolling/reset behavior. Full table/boundaries/stream feed corpus missing; a similarly named library is not compatibility |
| Tree / code 2 | `[1, entries]`; File `[0,name_bytes,mode,content_object_b32]`, Directory `[1,name_bytes,tree_object_b32]`; raw-byte name order; modes Regular=0, Executable=1, Symlink=2 | Retain, including empty tree/directory objects. No case/Unicode normalization. Symlink content is target bytes, not followed contents |
| Snapshot / code 3 | `[1, root_tree_object_b32]` | Retain full closure and wrong-kind/missing/corrupt negatives |
| Old Core controls | Codes 41 revision, 42 accepted, 43 branch, 47 resolution; body schema 1; domain directly followed by canonical body **without NUL** | Old inspection/regression only for changed semantics. Do not emit Model A in those old codes/domains |
| Scope/pages/private plan | Codes 44/45/46; scope/page schema 1; old private integration plan schemas 1/2 | Scope/page reuse only if exact semantics retained; plan bytes are not the new SQL plan contract |
| Local wrappers | History schema 2, restore journal schemas 1–5 in existing code/tests, versioned transport/clone controls | Semantics useful; no private SQL compatibility promised |

The CBOR generic-map distinction is source-backed, not a new relaxed public parser.
Any V2 payload schema still requires its exact ordered keys. Likewise, constructor
sorting is not permission to repair noncanonical signed input during decoding.

## Existing families and fresh comparison coverage

There are **74** files in seven existing golden directories. Family manifest
hashes bind file names and literal file bytes, including hex-file newline. For
each family, sort immediate file names lexicographically, concatenate
`UTF8(name) || NUL || SHA256(file_bytes)` (raw 32-byte digests), then SHA256 that
concatenation. These are inventory checksums, **not object or record IDs**.

| Family / files | Manifest SHA-256 | M0 comparison / V2 use |
| --- | --- | --- |
| [composition](../../../test/golden/composition), 4 | `a2cb4ad52c39fce97530786552fa2039b5dee7cd4d79559ae44e703a99048860` | 4 fresh comparisons; unchanged scope/page bytes potentially reusable |
| [core](../../../test/golden/core), 17 | `291d977065fdfea8cd27abd0fd6e879615ecc076e7631b7f160c0f23c0d79421` | 17 regenerated externally and equal; old controls/historical inspection, history pair width reusable |
| [core-package](../../../test/golden/core-package), 7 | `9d7e68b3ef011d6ce5970ba93a586075a8e8c77a79127e0e309a7d2a9e0b4ee4` | 7 fresh comparisons; old transport/wrappers, generic hashing reference only |
| [integration](../../../test/golden/integration), 4 | `beb8df178dd06e382c5e389ab326e4a7424ba4449438bdc175d9bce5090ac0ad` | 4 fresh comparisons; old private plans not new PlanId/schema |
| [local](../../../test/golden/local), 4 | `3d7109f46e33654ca0988059fe9a657b9c5de54268703f2f55d9ef2f8fbc3ba6` | 2 journal comparisons fresh; history-v2/CLI JSON only inventoried |
| [v1](../../../test/golden/v1), 28 | `5304e34410c729e41930dae352775905a16846b9a476c06d17135bba30f0f57d` | Inventoried; old codecs/security/recovery regression only, not V2 wire promises |
| [inspection](../../../test/golden/inspection), 10 | `3d08c7d453ccf35ed5e9a6bf64cdc2092ba3a57f81bb117b4e0dbb0337e69331` | Inventoried presentation outputs, not cryptographic or semantic normalization proof |

Thus **34/74** files received fresh independent generation/comparison; the
remaining 40 received inventory/preservation checks, not fresh runtime passes.
No new retained-content corpus or V2 public-control vectors were generated.

### Generators, exact inputs and existing expected outputs

| Source / side effects | Exact input specification | Expected output reference / future test |
| --- | --- | --- |
| [Core generator](../../../test/generate_core_vectors.py): **always writes** `test/golden/core` relative to its own path and invokes OpenSSL; no read-only flag | Public seed `b"a"*32`; repo `q*32`, author cert `c*32`, authority `{h*32,i*32}`, time 1234. Four explicit `records` entries define kind/code/parents/payload; history uses bytes 00..0f and max int64 | Four kinds × body/signing-input/envelope/RecordId plus history-id, 17 files. Exact fields below; copy generator+goldens outside checkout before any execution |
| [Composition generator](../../../tools/generate_composition_vectors.py): default compares; `--write` overwrites | Scope code44 `[1,0,[[b"a",b"b"],[b"bad-\xff"],[b"z"]]]`; page45 `[1,b"pages-v1",0,[[b"a",[0,b"A"]],[b"bad-\xff",[0,b"B"]]]]` | `edit-scope-{envelope,id}.hex`, `metadata-page-{envelope,id}.hex`; source subset CBOR/emission independent of OCaml |
| [Package generator](../../../tools/generate_core_package_vectors.py): default compares; `--write` mkdir/write | Manifest `[2,a*32,b*16,r*32,u*32,t*32,o*32]`; stream `byte(i%251)` for i=0..1,048,582; exact old courier from v1/transport-publication fixture; endpoint `https://relay.invalid`; clone/control arrays in source | Seven listed files. Input courier remains old signed bytes; decode helper is a fixture reader, not bounded production admission |
| [Integration generator](../../../tools/generate_integration_vectors.py): default compares; `--write` mkdir/write; imports package `encode` | Request `[q*32,b*16,[e*32],[a*32],[r*32],[z*32],[h*32],[],[],[w*16,7,a*32,v*32,o*32,p*32],"line-hunks-v1"]`; fields request,s*32,d*32,k*32,v*32,`[0,v*32,t*32]`,false; schema2 adds `[[[b"note.txt"],x*32]]` | `plan-v{1,2}.hex` and corresponding `-id.hex`, code46. Existing old plan ID is SHA256(envelope), not the proposed new private domain |
| [Local generator](../../../tools/generate_local_vectors.py): default compares; `--write` writes | v4 `[4,"a"*64,"snapshot-target","snapshot-target",0,0,null,p*32,null,b"/fixture/copy"]`; v5 `[5,"a"*64,"snapshot-target","snapshot-target",0,0,2,p*32,null,s*32]` | `restore-copyout-v4.cbor.hex`, `restore-selection-v5.cbor.hex`. New absent-only contract intentionally differs from old executor allowance |

Here `a*32` etc. mean repeated ASCII bytes, except quoted strings which are text.
They are intentionally fake references for **codec shape fixtures**, not valid
repository closures or fabricated verified production records. A new semantic
test must build genuine matching closure before treating its records as valid.

Old Core generator payload arrays, encoded as consecutive integer maps:

| Kind | Code / exact parents / payload fields |
| --- | --- |
| shared-revision | 41; `[p*32]`; `[c*16,[p*32],b*32,r*32,s*32,[d*32,e*32]]` |
| accepted-version | 42; `[a*32,b*32]`; `[m*16,[a*32,b*32],[r*32],[],z*32,"line-hunks-v1",[],[]]` |
| resolution-revision | 47; `[a*32,b*32,r*32]`; `[m*16,[a*32,b*32],[r*32],[a*32,b*32,r*32],s*32,b*32,z*32]` |
| branch-event | 43; `[a*32,b*32]`; `[m*16,[a*32,b*32],3,[v*32],null]` |

Fixed old expected identifiers below were read from existing fixtures and
independently reproduced, not invented for new controls:

| Existing file / meaning | Expected raw bytes, rendered hex |
| --- | --- |
| core/shared-revision-id.hex; old RecordId | `8a7510d30ac1cb18797274a60ac3e9ca6d6e0ee230b794604976364c64db8813` |
| core/accepted-version-id.hex; old RecordId | `edb53c97a6c29cf7c6a6b702e2daee27c8bdc3abccb649d4a75e0d15637561ca` |
| core/branch-event-id.hex; old RecordId | `7292358dee379aa3653ccbaabe32005909bd2381b712bbf10bd6dcfec4e6358c` |
| core/resolution-revision-id.hex; old RecordId | `a07fb4b8ace08d8a375156b638f80070d18fde19904429b444f0b314468fe1e6` |
| core/history-id.hex; **CBOR pair, not a hash** | `8250000102030405060708090a0b0c0d0e0f1b7fffffffffffffff` |
| composition/edit-scope-id.hex; StoredObjectId | `3784bffcb00d8c41b0475d05692ff6d828d770357c47a7aa0e2ddf49553e152b` |
| composition/metadata-page-id.hex; StoredObjectId | `e26ffa3f5c5b97677977ef5a98de75ddfedf05c7921f7062028aadc386a251e3` |
| core-package/courier-manifest-id.hex; plain manifest SHA256 | `a484658ff6eea03058f17f577f6ba69e667c1e224feba92a3fae2734c08423ae` |
| core-package/hash-stream-id.hex; plain stream SHA256 | `9e037498ddbb955fba0752812031c14ba299a4875cb400e8b8c1d77b3962c90e` |
| core-package/clone-request-id.hex; old domain-separated intent hash | `ad1b3fdb26a5b333c284f4efaf2d4aa578972de4a5b8954f83bcca061fa3fed6` |
| integration/plan-v1-id.hex; old envelope SHA256 | `9adc27738f7d07484092205d6a51b6aa9142686c4e9a77f22badab70a506af66` |
| integration/plan-v2-id.hex; old envelope SHA256 | `47ab4484547e30f08ac276dfd91d6289560cef798efb6b4822b1719a84485baf` |

The copied Core generator result does not exercise an independent OCaml decoder
in M0; its consumers were historically tested in P1/P3. No existing test with a
golden-refresh helper is run casually: e.g. `test/test_v1_hook.ml` can refresh a
fixture through its helper. Neither absence of `--write` nor a test label proves
read-only behavior. Future comparison commands must audit their actual paths.

## Required coverage by identity/fidelity property

| Property | Existing exact input / expected behavior / source | Coverage status and future test |
| --- | --- | --- |
| Object ID and envelope | Two independent scope/page envelopes and IDs above; existing checksums/hash formulas | Fresh positive vectors; M1a must independently decode/re-encode unchanged kinds, distinguish RecordId/StoredObjectId |
| FullContentId and inline | [content tests](../../../test/test_content_verification.ml), `bytes(n)[i]=((i*17)+(i//256)) mod256`, n=0,1,65536,65537,1048589; store/verify/load must reproduce exact bytes and add no objects during verify | Source/test-backed, not fresh OCaml execution; no complete independent fixed full-content/inline digest corpus found in inventoried goldens |
| Chunked manifests | Same bytes(200000), canonical chunker/manifest source; wrong first cut 1/rest, wrong full digest z*32, altered first chunk length, missing first chunk must fail | Useful adversarial source tests, **independent chunk boundary/manifest expected-ID corpus missing**; M1a prerequisite |
| Empty directories / trees | [capture](../../../test/test_capture_consistency.ml), `fidelity_and_special_file`; [materialization](../../../test/test_snapshot_materialize.ml); Tree source `[1,[]]` | Fidelity requirement/test existence; no independently reviewed complete tree/snapshot golden corpus found here |
| Symlinks / executable | Same capture tests: dangling target `missing/target`, executable distinction; composition mixed-tree includes link `../dir/note` | Source-backed; M1a logical codec fixtures, M2 native round-trip/invalid-target/case representation separately |
| Byte-exact names | Scope/page positives `bad-ff`; tree source rejects empty/dot/dotdot/slash/NUL, sorts raw bytes | Existing scope byte-name vector does **not** prove full tree filename codec; add full closure raw 0xff tree fixture |
| Canonical CBOR invalid inputs | [Core record tests](../../../test/test_core_record.ml), [V1 record tests](../../../test/test_v1_record.ml); nonminimal/truncated/wrong map/set/version/type/depth/item negatives | Source and historical codec evidence; new bounded Python decoder must reproduce exact rejection class without coercing bool to integer |
| Old signed records | Four complete fixed-seed kinds above; body/message/signature/envelope/ID artifacts | Fresh independent byte agreement for old schema; cross-kind/domain/repository/signature negatives still need Python consumer tests if supported |
| Leaf composition | [composition tests](../../../test/test_composition.ml): `a\nb\na\n` -> `a\na\nb\n` has deletion hunk [1,2), then insertion at [3,3) of `b\n`; CRLF/final-newline reconstruction; insertion/overlap negatives | Exact inline expected values; no new path-frontiers behavior implied by old hunk tests |
| Integration / private choices | Old plans schema1/2 with exact request inputs above; [control tests](../../../test/test_integration_control.ml) and [CLI tests](../../../test/test_native_integration_cli.py) | Old-byte references reusable for old inspection, not new canonical private-plan bytes |
| Local history | [history tests](../../../test/test_history_identity.ml), schema2 golden; max-int64 pair independent above; exhaustion/collision/restart/root publication cases | Capture identity semantics retained; history wrapper/counter publication replaced by future SQL transitions |
| Invalid snapshot representations | Content tests' false full ID/length/noncanonical boundaries; snapshot decoders enforce names/modes/kinds/canonical payload | Source-backed negatives, not a fixed independent malformed-content corpus or a current pass |

## Retained-content corpus specification: OPEN outputs, exact future inputs

This table is a **vector input plan**, not newly generated golden data. The
content schemas/formulas above are source-defined; independently reviewed complete
bytes/IDs and decoder agreement are still required before their Python consumer.
Do not calculate an expected hash using the proposed production encoder itself.

| Future ID | Exact input | Expected property / required artifacts |
| --- | --- | --- |
| RC01 inline boundaries | `b""`, `b"\x00"`, and `P(n)` at n=65535,65536,65537, where `P(n)[i]=((i*17)+(i//256))%256` | <=65536 Content1, >65536 canonical Manifest14; preserve bytes. Capture payload/envelope/StoredObjectId/FullContentId, all chunk envelopes/lengths/IDs and tree/snapshot closure |
| RC02 chunk boundaries | P(200000), P(1048589), `b"\x00"*262145`; feed sizes 1,63,64,65,16384,65536 and whole input | Identical canonical cuts/IDs regardless of feed segmentation; exact 256-entry table, rolling-window wrap and min/max/EOF boundaries reviewed independently |
| RC03 mixed complete tree | raw names `b"A"`, `b"bad-\xff"`, `b"empty"`, `b"link"`, `b"nested"`, `b"run"`; Regular A=`b"a\r\nb"`, Regular bad-ff=`b"\x00\xff"`, empty directory, Symlink link target=`b"missing/target"`, nested/note=`b"end\n"`, Executable run=`b"#!/bin/sh\nexit 0\n"` | Exact byte-name order, nested/empty tree IDs, every content and Snapshot3 ID. Native representability is a separate M2 refusal test |
| RC04 identity distinctions | Same file bytes under two names, Regular vs Executable, Content vs Chunk kind with same payload; two distinct capture IDs referencing one snapshot | FullContentId equal where bytes equal; correct distinct stored/tree/snapshot/history identities; no fake causal edge |
| RC05 invalid content | RC01/02 closure with missing/corrupt chunk, wrong total/individual lengths/full ID, manifest for <=65536, noncanonical cut/parameters, wrong referenced kind | Exact expected typed rejection before availability claim, including bounded-display reads that request zero bytes |
| RC06 malformed names/CBOR/envelope | RC03 with empty/dot/dotdot/slash/NUL/duplicate/unordered name or invalid mode; envelope prefixes 0..56/truncations, flipped checksum/type/version/features/length; nonminimal args, indefinite/tag/float/duplicate or unordered keys, malformed UTF-8, bool-as-int, trailing data | Strict bounded failures; sparse nonnegative generic maps are not incorrectly rejected merely for nonconsecutive keys, while exact record payload shape is enforced |

Independent method: one small reference emitter/chunker written from the source-
backed specification without importing production code, plus a separately written
bounded decoder/verifier and matching OCaml comparison on unchanged semantics.
Run any OCaml helper on disposable exported fixtures outside live stores. Freeze
complete expected bytes only after disagreements are resolved and source/build
identities recorded. Reference code/dependency/fixture additions require a later
authorization; M0 adds none. The incomplete corpus is an explicit M1a gate.

## New public controls: input inventory, wire outputs OPEN

Actual source registry still ends at 47. D3 proposes, but does not allocate,
48 candidate-revision, 49 accepted-version, 50 branch-event, 51 shared-resolution.
Retain Envelope-1/object-format1; proposed body schema2 is separate. Proposed
domains are exactly these ASCII strings followed by **one NUL** then canonical body:

```text
yeokcham/record/candidate-revision/v2
yeokcham/record/accepted-version/v2
yeokcham/record/branch-event/v2
yeokcham/record/shared-resolution/v2
```

No expected signature/body/envelope/ID bytes are frozen or generated. Revised
accepted/Compose/resolution payload order, OriginRef, exact profile/bounds,
authority carriage and dependency canonicalization remain OPEN. D4 removes D3's
redundant direct-input set and arbitrary proof override: an encoder must not
revive those old draft keys as if an implementation decision settled them.

| Future vector family | Precise logical input specification | Blocker / consumer and independent obligation |
| --- | --- | --- |
| V2-CANDIDATE | Semantic S01–09, S19: exact change/predecessor/null, public basis/result/scope, repo/certificate/authority and display time null; fixed public seeds selected only when schema freezes | Candidate ordered basis fields/trust carriage/profile encoding; M4. Complete body, signing input, signature, envelope, logical/stored IDs; predecessor-alone-not-basis negative |
| V2-BASIS | S13's exact Compose inputs/result and S14 incomparable comparisons; variants missing input, wrong claimed T11, cycle and cross-repository ref | Profile work charging before normalization consumer; exact Compose array/control bytes before M4. Independent evaluator plus codec, no supplied arbitrary proof override |
| V2-ACCEPTED | Empty G, S0 selecting R0, S04 direct A2, S05 incremental, S15 reconcile/equal heads; exact parents/selected/resolution/result/policy contexts | Revised consecutive payload schema/profile/reference closure, M4/M5. Wrong result, omitted accepted parent in local commit, dependency-not-selection, equal snapshot/distinct record negatives |
| V2-BRANCH | Exact create/fork/rename/advance/reconcile actions 0..3, concurrent event/name heads and targets, acceptance+advance atomicity | Revised event/body/trust schema and independent signed vectors before M4; transport completeness before M5 |
| V2-RESOLUTION | S10/S12/S15/S20 actual conflict context, one exact path, choose source versus literal replacement/deletion, rejected inputs context-only | OriginRef/choice encoding, context coverage/nonconfluence resolution support OPEN before M4. Unused/overlap/stale/incomplete/hidden-private replacements must fail |
| V2-PARSER/SIGNATURE | Each frozen positive with one field/version/type/domain/NUL/signature/ID/set/null corruption, truncated prefixes and resource bombs | Proposed 8 MiB, depth16/items131200/refs16384 do not freeze unresolved graph budget. Two independent encode/decode/signature verification paths before admission |
| PRIVATE-PLAN/ACTION/CLAIM | S17/S18 exact dependencies/stale inputs, same request/plan replay; D4 DestinationClaim-v1 exact role0/1, repo32/op16/plan32/target32/token16 | Plan/request/native observation and action/recovery encodings before M1b/M2; claim byte vectors/native identities before M2. No private plan/public proof or second execution journal |
| NEGOTIATION | Exact public-control2 + normalization/leaf pair, type/mandatory feature support, fresh repository scope; unsupported and old peer | Bounded handshake/routes/media/capability schema before M5. Integrity/auth failures never downgrade to old semantics |

Before generating signed V2 vectors, select reviewed fixed **public test** seeds,
certificate/authority fixture closure and deterministic display fields, and derive
referenced IDs topologically from actual prior bytes. Never use placeholder hash
patterns as verified dependencies or create a hash cycle through a future accepted
ID/plan. Freeze an independent CBOR emitter/decoder and Ed25519 verification method;
provider agreement alone is not independent schema evidence. No registry mutation
is authorized by this inventory.

## Compatibility claims kept separate

1. **Exact byte compatibility:** unchanged kinds/formulas only, once corpus verifies.
2. **Semantic continuity:** retain named fidelity/privacy/recovery rules; intentionally
   change continuation, subset selection, normalization and private persistence.
3. **Read-only inspection:** retain the matching OCaml reader. A limited new content
   decoder is not a full old repository or interrupted-operation reader.
4. **Full migration:** separately designed explicit export/import including private
   facts/identity mapping/pending physical scope; not an implicit upgrade.
5. **Native protocol interoperability:** not promised with old controls. New scope,
   versions and negotiation are required even if some content objects match.

Old readers, bytes, goldens and recovery tools remain available. No writer may
open an OCaml store, share mutable object directories or manage an overlapping
working tree. No new implementation silently becomes the default `yeokcham`.
