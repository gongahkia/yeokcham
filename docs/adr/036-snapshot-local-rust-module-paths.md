# ADR-036 — Snapshot-local Rust module paths

- Status: Accepted
- Date: 2026-08-05
- Deciders: maintainer (approved 2026-08-05)
- Supersedes: None
- Superseded by: None

## Context and problem statement

M9-02 extends ADR-035's optional Rust syntax evidence with bounded module and
item-path evidence. ADR-035 deliberately excluded module resolution and paths.
Rust source-file module placement depends on a crate root selected outside that
source file; invoking Cargo, `rustc`, Rust Analyzer, workspace configuration,
or host files would violate the existing snapshot-only boundary. The Rust
Reference defines standard external module candidates but also supports
attributes and conditional/module-macro behaviour beyond a syntax-only helper.

Current milestone: M9 Rust Semantic Sidecar. Vertical slice: resolve only an
explicit caller-selected virtual root set and its standard, non-attributed Rust
module declarations inside one verified immutable snapshot. Return transient
module/item path facts or structured incompleteness. It excludes Cargo/workspace
discovery, crate/package names, `use`/name/type resolution, macro expansion,
`#[path]`, conditional/module macro attributes, generated modules, persistence,
semantic operations, rewrites, and CLI changes.

## Decision drivers

- Module evidence must be deterministic from request bytes alone.
- A source path must not be mistaken for a Rust crate root through ambient
  project configuration or an undocumented convention.
- Standard `foo.rs` and `foo/mod.rs` alternatives must not silently select an
  ambiguous target.
- Unsupported Rust mechanisms must retain syntax facts and byte/text fallback.
- Module/item paths must remain evidence, never Yeokcham or compiler identity.

## Considered options

### Infer roots from `lib.rs`, `main.rs`, and `src/` conventions

- Requires no new invocation input.
- Misidentifies multi-crate, generated, test, or non-Cargo snapshots and makes
  an implicit project-layout claim that the snapshot cannot prove.

### Read Cargo metadata or invoke Rust compiler tooling

- Can select compilation roots and configuration accurately for one project.
- Reads mutable external state, may run build scripts/proc macros or dependency
  resolution, and violates ADR-035's isolated parser boundary.

### Require explicit snapshot-local virtual roots and resolve only standard modules

- Makes root selection inspectable, replayable for one invocation, and bounded
  without assigning a crate name or reading outside the verified snapshot.
- Leaves attributes, macros, conditional configuration, and semantic name
  resolution explicit incomplete/unsupported outcomes.

## Decision outcome

Select explicit snapshot-local virtual roots and standard module resolution.

M9-02 adds a bounded sorted nonempty `root_files` list to the Rust adapter
analysis request. Every root must be an exact safe `.rs` path in the supplied
verified snapshot virtual map. A root identifies an anonymous virtual crate
root by its source-file path, not by Cargo package/crate metadata. Multiple
roots remain distinct even when their textual module segments match. A root
list is invocation input only: it creates no Yeokcham object, ref, workspace
state, or persistent configuration.

For a supported external `mod name;` in a reachable module file, the helper
derives exactly two snapshot-map candidates: `<child-base>/name.rs` and
`<child-base>/name/mod.rs`. `child-base` is the parent file's directory when
the parent filename is `mod.rs` or the selected root file; otherwise it is the
parent file's directory joined with the parent filename stem. Exactly one
candidate resolves. Both candidates produce `ambiguous-module`; neither
candidate produces `missing-module`. No host path is inspected. This matches
the standard layout described by the [Rust module reference](https://doc.rust-lang.org/stable/reference/items/modules.html)
without claiming compiler-equivalent configuration handling.

An inline `mod name { ... }` is resolved from its parent module without a file
lookup. Module nesting is bounded by 256 reachable modules; the request has
ADR-035's file/path/byte bounds and additionally permits at most 4,096 module
facts and 4,096 item-path facts. Repeated module names under one parent,
cycles, unsafe/missing root paths, module depth excess, and duplicate roots are
structured adapter errors or incomplete facts before a path is exposed.

The helper explicitly does not resolve an external module carrying `path`,
`cfg`, `cfg_attr`, a macro attribute, or other unsupported outer attribute. It
returns its parsed module item with an `unsupported-module-attribute` or
`conditional-module` incompleteness fact. Macro invocations and macro-generated
items remain path-deferred for M9-03. A parse-damaged source, unreachable
supplied `.rs` file, anonymous/unnamed item, `impl`, `use`, or unsupported item
form has no item path and a structured status; it is not given a guessed name.

A resolved item fact contains: the exact root-file path; a module segment list
whose empty list denotes that root's anonymous module; the item kind; optional
syntactic item name; and a candidate item segment list only where syntax
declares a supported name. The complete `(snapshot ID, root-file path, module
segments, item segments)` tuple is transient evidence, not a Yeokcham ID,
compiler canonical path, resolved symbol, type, alias, intent, or claim of
behavioural equivalence. Returned facts are canonically ordered by root path,
module segments, source path, and byte span. `module_paths_complete` is false
if any selected root's reachable graph has parser damage, ambiguity, missing or
unsupported module input, depth/item bounds, or unreachable supplied source.

## Consequences

- Callers explicitly choose the virtual compilation roots they want analysed.
- Standard source layout is supported only inside the supplied snapshot map.
- Module results explain missing, ambiguous, conditional, attributed,
  unreachable, unnamed, and deferred cases instead of fabricating a path.
- Cargo workspaces, package names, configurations, macro output, and imports
  remain outside M9-02 and exact bytes/text remain authoritative.
- The TypeScript adapter, M7 comparative experiment, and M9-01 syntax evidence
  remain independent and compatible.

## Model and invariant impact

New transient values are virtual root selection, module fact, item-path fact,
and path status. They are separate from canonical snapshot, capsule, revision,
workspace, release, and conflict types.

- Every root/source/module/item fact names the exact requested snapshot.
- A root and every resolved external source are members of the supplied sorted
  virtual file map; no host path is consulted.
- A resolved external module has exactly one standard candidate and one parent
  module fact; an inline module has one syntactic parent.
- Every item path is scoped by root source path, byte span, and parser
  completeness; a status other than resolved grants no application authority.
- Missing helper, timeout, crash, malformed protocol, parse damage, ambiguity,
  unsupported input, and all bounds leave repository state and byte/text
  operations unchanged.

## Persistent-format and migration impact

No Yeokcham object, ref, schema, envelope, mapping, migration, or persistent
golden changes. Root choices, protocol-v1 module/item facts, and helper lockfile
bytes are transient tool artifacts. Any semantic-path persistence or use in a
canonical operation requires a separate ADR and format version.

## Verification

Required before issue closure:

- Unit and exact protocol-golden tests for explicit roots, `foo.rs`,
  `foo/mod.rs`, inline nesting, multiple roots, canonical ordering, UTF-8 byte
  spans, and root-scoped item facts.
- Failure tests for absent/duplicate/unsafe roots; both/neither external module
  candidate; duplicate module name; depth/fact bounds; attributes, conditional
  modules, macro items, damaged syntax, unreachable source, helper absence,
  timeout, crash, malformed protocol, and output limits.
- Snapshot-boundary tests that modify live source after scanning and prove that
  only stored root/module bytes were analysed; unavailable/incomplete outcomes
  must leave an independent byte/text operation available.
- Seeded generated nested virtual module maps proving canonical ordering, one
  parent per resolved module, exact candidate membership, and no automatic
  authority from incomplete facts.
- Focused adapter/fixture tests, comparative result-schema validation, `make
  check`, and `make property-test PROPERTY_TEST_SEED=17`.

## CLI and user impact

Not applicable in M9-02: no CLI command is added. Library callers pass root
source paths explicitly and may inspect root-scoped module/item evidence and
structured incompleteness. They cannot infer a Cargo package, resolve imports,
expand macros, persist path evidence, request a rewrite, or claim semantic
equivalence.
