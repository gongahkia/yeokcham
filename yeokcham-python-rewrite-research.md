# Yeokcham V2 — Research, Product Thesis, and Architecture Design Baseline

> **Status:** Research and design draft v0.1 — **not an approved implementation specification**  
> **Prepared:** 18 November 2026 (Singapore)  
> **Repository:** <https://github.com/gongahkia/yeokcham>  
> **Source baseline:** `main` at `ce482b2`, as represented in the owner's Codex handoff dated 18 November 2026 and repository documentation read at that commit.  
> **Intended future path:** `docs/v2/RESEARCH_AND_DESIGN.md` (suggested only; not written to the repository).  
> **Evidence notation:** `[Y#]` = Yeokcham source; `[R#]` = external primary/official source; `[T1]` = user-provided Casey Muratori transcript. Links and details are in §17.  
> **Purpose:** Establish a durable, inspectable basis for discussion before authorizing Python implementation.

---

## 0. Executive decision summary

### The product in one sentence

**Yeokcham is a local-first version control system that quietly records on-disk work, keeps independent human and agent contributions safe and accessible, and asks for decisions about combining them only when those decisions matter.**

### An even shorter explanation

**Save without ceremony. Work in parallel without losing work. Decide what to combine when ready.**

These statements are **desired product behavior**, not assertions that the current build delivers it.

### What this project is and is not

- **Is:** A standalone VCS with its own history and exchange model; not a Git wrapper. Source code, documents, and opaque binary assets are first-class data. Small trusted teams, solo developers across devices, and developers running several coding agents are initial users. [Y0][Y1]
- **Is not:** A claim that Git is unable to preserve divergent histories, an automatic semantic merger of all file formats, an agent orchestration platform, or a production substitute for Git today.
- **Distinctive hypothesis:** An end-to-end workflow can be significantly lower-friction than mainstream Git practices by integrating durable capture, deferred acceptance, safe parallel work, and an intentional agent API. The advantage is **unproven until evaluated** against Git *and* Jujutsu.
- **Migration objective:** Reimplement the understandable domain in Python, **simplifying abstractions where justified by observable behavior and safety invariants**. Do not mechanically translate OCaml modules one-for-one.

### Recommended strategic direction

1. **Preserve** the sound conceptual separation already in Yeokcham: private history, explicitly published work, received-but-unapplied data, accepted versions, and unresolved decisions.
2. **Prioritize** reliable background capture and transparent status. A VCS that requires routine manual saving has not delivered the desired “invisible” experience.
3. **Never make preservation depend on successful integration.** A conflict may block adopting a particular result, but should not block independently preserving or exchanging valid, authorized work.
4. **Make agent workspaces first-class, provisionally called _lanes_.** A lane has its own identity, source state, history, and lifecycle; a physical checkout is an *execution option*, not necessarily its identity. Do not claim this is superior to Git worktrees until tested.
5. **Use Python for orchestration and the domain model** while retaining mature compiled implementations for compression, crypto, hashing, and filesystem support where necessary.
6. **Proceed design-first.** Freeze current behavior and invariants before selecting a new on-disk schema or touching the working implementation.

### Critical boundary

“Do not block me from saving” **does not** imply “automatically approve, execute, release, or expose my work to teammates.” Preservation, availability, publication, acceptance, and deployment are different operations.

---

## 1. Research questions and methodology

This document addresses six questions:

1. What is Yeokcham today, based on code-adjacent evidence rather than aspirations?
2. Where is Git genuinely burdensome, and where does it already support the desired semantics?
3. Which principles from the Casey transcript are transferable without inheriting its incidental implementation choices?
4. What does Anthropic's **Scion** demonstrate about agent-scale version control, and what **shouldn't** a local-first system copy?
5. Is a first-class agent-work primitive justified beyond Git worktrees, Jujutsu workspaces, and other known approaches?
6. What architecture and staged OCaml → Python migration make the product easier to explain, test, and maintain?

**Evidence classification.**

- **Verified source/report:** Text from the user-provided repository handoff or from named Yeokcham documentation fetched at the identified commit. Reports record past tests; they are **not fresh test executions**.
- **External primary source:** Original vendor/project documentation linked in §17, consulted on 18 November 2026.
- **Interpretation/proposal:** Reasoned synthesis marked as a proposal, not an implementation fact.
- **Not verified:** No local build or CLI command was run against `/home/gongahkia/coding/projects/yeokcham`; no live two-person session was observed; Casey's video URL was not provided and the supplied speech-to-text transcript has repeats and likely transcription errors.

This document does **not** modify the actual repository, select new wire formats, retire old invariants, or authorize the former P4 phase.

---

## 2. Baseline: what Yeokcham actually has

Yeokcham is a native **OCaml 5.5.0** CLI/VCS using Dune, a pure functional model with adapters, canonical CBOR records in typed binary envelopes, SHA-256 addressed immutable objects, chunked content and snapshot trees, local atomic references, journals, recoverable materialization, Ed25519 signatures, and a self-hosted HTTPS byte relay with resumable/compressed ranges. The repository also has Python test/fixture tooling and small C platform bindings. It has **no required SQL database or browser UI**. [Y0][Y1][Y4]

Its essential conceptual boundaries are important and already largely aligned with the requested product:

| Existing distinction | Why it matters |
|---|---|
| **Snapshot ≠ local history position** | Returning to identical bytes can still represent a distinct editing event and branch of personal history. |
| **Private capture ≠ shared revision** | Local experimentation does not silently publish unfinished material. |
| **Receipt ≠ adoption** | Downloading another person's work does not move one's cursor or change source files. |
| **Shared revision ≠ accepted version** | Available candidate changes are not automatically part of the team's agreed result. |
| **Conflict/decision ≠ lost progress** | A disagreement is representable as data rather than an excuse to discard a candidate. |
| **Relay storage ≠ authority** | A server carrying bytes does not itself decide who is trusted or what is accepted. |

### Delivered versus planned (as of the named baseline)

| Feature | Status supported by the handoff and repository reports |
|---|---|
| Local initialization, capture, native ignores, status/history/diff, named local branches, recoverable local navigation | **Delivered in P2** on the tested paths. |
| Selected explicit sharing, native clone/exchange, deterministic composition and exact integration plans, explicit conflicts, offline accepted history, retry/restart handling | **Delivered in P3** on reported automated journeys using disposable test capabilities. |
| Compact local terminal presentation, connected ASCII history, responsive diffs | **Reported implemented** in the later dogfooding follow-up. |
| Always-running managed background capture, automatic private backup/archive, cross-platform service lifecycle | **Planned / not fully delivered.** A foreground watcher primitive exists; that is not a managed always-on service. |
| Real-user native key onboarding, two-person usability assessment, representative project testing, broad platform qualification | **P4 unstarted.** |
| Native required-review capability, full account backup, retention, Windows readiness, full monorepo/binary performance qualification | **Larger roadmap; not verified complete.** |
| Full CI at latest dogfooding state | **Not green:** a synthetic copy-out restore fixture fails; it also fails at the starting revision and remains unexplained. |

The recorded P3 closeout did pass its scoped CI at its own implementation revision; this does **not** contradict the later, unresolved full-CI failure. Keep revisions and evidence distinct. [Y0][Y2][Y3][Y5]

### What should remain true throughout a rewrite

- Exact bytes for included regular/binary files, symlink targets, empty directories, and executable distinction survive capture/restore within documented platform limits.
- Ignore/exclusion rules are explicit; neither accidental capture of secrets nor broad claims about unsaved editor buffers are acceptable.
- A local draft remains private unless publication is authorized.
- Verified receipt does not mutate ordinary files or imply acceptance.
- Content identities and separate local-history positions are not conflated.
- The system must retain competing causal heads and never choose a winner by arrival time.
- An accepted result is built from exact selected inputs, not from an opportunistic rescan of unrelated private work.
- Concurrent changes, stale previews, broken transfers, crashes, and bad signatures cannot silently lose or endorse work.
- A later background process may signal attention needed but should not silently alter in-progress working files.

These are **behavioral contracts**, not necessarily mandates to reproduce every present-day implementation detail. [Y4][Y6]

---

## 3. From Casey Muratori: remove source-control ceremony

The user-supplied transcript [T1] stresses a small-trusted-team workflow in which the normal act of working is not interrupted by branches, rebases, conflict gates, or repeated version-control bookkeeping. Casey describes a `done`-style operation that records the group's work, gives people competing file versions when they overlap, and lets them settle those differences later. The transcript also emphasizes artists, large binary repositories, and developers switching between personal computers.

### Transferable product principles

**C1. Save first, resolve later.** Two incompatible edits can both be preserved. The fact they cannot be immediately composed does not mean either edit is invalid or disposable.

**C2. Availability is not acceptance.** Make versions accessible without requiring that they immediately become the selected working or team state.

**C3. The routine should be boring.** Editors, artists, and programmers should not need repository concepts to perform ordinary work. Complex commands belong in an advanced lane.

**C4. Ask only necessary questions.** Delay decisions until a user tries to combine, deploy, or intentionally choose a specific candidate.

**C5. Scale the interaction to the team.** Small teams need a simpler collaboration default than workflows optimized for hundreds of approval paths.

**C6. Do not forget non-source-code users.** Binary assets and documents must be retained exactly even when automatic merging is unavailable.

### What not to copy literally

- **Alternate files in the same directory.** Useful as an optional export, but potentially dangerous as the default: duplicate source modules, asset discovery, globbing, tests, and build tools may pick up unintended candidates. **Proposal:** show conflicts in the VCS model and materialize side-by-side only on request.
- **A literal one-command `done` implementation.** A shortcut can be helpful, but a managed capture service is closer to the desired *continuous* recovery experience. It must accurately report on-disk capture and backup acknowledgement.
- **Universal team visibility.** The transcript's trusted-team setting is a valid opt-in; private drafts, secrets, paid code, and independent agents need safer defaults.
- **“Nothing ever blocks.”** Security/policy violations and destructive filesystem replacement must be able to refuse unsafe actions. The key is never making *valid preservation* hostage to an unrelated integration decision.

**Proposed interpretation:** Yeokcham should be *nonblocking in its preservation plane* and *deliberate in its adoption plane*.

---

## 4. From Anthropic Scion: design for cheap, programmatic parallel work

Anthropic's [October 2026 Scion article][R1] describes a monorepo experiencing over 30,000 merged changes per day by September 2026, after roughly 2,500 per day in May. Anthropic replaced its Git-centered source-control infrastructure with **Scion** and emphasizes several deliberate design choices:

1. **Always-online clients**, unlike a local-first distributed VCS.
2. **Client/server asymmetry:** the server handles repository history, merge, and other heavyweight operations; clients mostly manage a bounded cache and working files.
3. **Changesets as cheap, immutable units:** changed paths and content pointers form append-only history; common branch-ref movement is not required for every produced change.
4. **Working copy optional:** history, ancestry, diffs, and some writes are accessible through service APIs without a full checkout.
5. **Incrementally derived indices:** expensive secondary data (path history, blame, graph shortcuts) can be computed separately from the canonical changesets.
6. **Scale by independent immutable objects:** caches and services exploit content addressing, with no universal repository packfile maintenance bottleneck.
7. **Different merge coordination:** high change volume forces a rethink of globally serialized merges, with more validation after changes land.

The article is explicit that Scion is **not generally suitable as a Git replacement** and depends on exceptional workload/infrastructure assumptions. Its reported 200× improvement in certain infrastructure CPU/memory footprints and its checkout improvements are **Anthropic-specific comparisons**, not performance estimates for Yeokcham. [R1]

### Transferable ideas (recommended for research)

- **Change recording separate from shared-head movement.** A new candidate should be cheap to create even when several developers or agents share an ancestor.
- **Query without checkout.** First-class typed APIs for history, change comparisons, ancestry, provenance, and candidate composition.
- **Materialize on demand.** Not every reviewing agent needs an independent 20-GB directory tree; build/test agents often do.
- **Incremental index strategy.** Introduce derived data only when actual benchmarks justify it, and make it reproducible from canonical objects.
- **Bounded caches and resumable transfer.** Keep local resource use predictable while honoring explicitly available offline data.

### Explicit rejections for Yeokcham V2

- **Do not require always-online clients.** Offline capture and later reconciliation are central to the Yeokcham product.
- **Do not move all domain mutations to a mandatory central server.** Local preservation must work without a relay.
- **Do not build Scion's fleet, Spanner architecture, review product, or distributed cache hierarchy.** These solve scale problems Yeokcham has not demonstrated.
- **Do not relax correctness just because agents can repair bad integrations.** Agent-generated repair is useful; it is not a replacement for byte integrity, causal history, or trustworthy published results.

**Synthesis:** Borrow Scion's *data-plane independence and programmable primitives*, not its infrastructure topology.

---

## 5. Prior art: what already exists and why that changes the bar

| System | Relevant demonstrated concepts | Implications for Yeokcham | Important limitation of this comparison |
|---|---|---|---|
| **Git** [R2][R3][R4] | Content-addressed history, offline commits, refs, worktrees, fetch-before-merge, stash/reflog, sparse/partial capabilities | Yeokcham must beat the **everyday workflow**, not falsely claim Git cannot preserve concurrent histories. | Vanilla Git is not the entire Git tooling ecosystem. |
| **Jujutsu (`jj`)** [R5][R6][R7] | Automatically snapshots the working copy around commands; operation log/undo; first-class conflict records; multiple workspaces | **Most important comparator** for preservation and deferrable conflict resolution. A new VCS must produce a clearer end-to-end workflow or agent experience. | `jj` has its own semantics, Git interoperability, and materialization behavior; test actual journeys. |
| **Sapling** [R8] | Usability-oriented commit stacks, mutation history, lazy history, sparse/virtual workspaces, Watchman integration | Valuable for responsiveness, mistakes/recovery, large worktrees and simplified stacked work. | Many large-scale server/VFS capabilities are not available in public client releases. |
| **Pijul** [R9] | A change-centric algebra, independent changes and conflict-preserving representation | Challenges the assumption that every new edit must be described relative to a branch. Read carefully before inventing a new patch calculus. | Its mathematical model is sophisticated; copying it would likely conflict with a readability-first Python MVP. |
| **GitButler** [R10] | Parallel/virtual branches in one working directory, separate change allocation | Shows that parallel work can be modeled above or beside physical worktrees. | This is a different point in the design space from safe isolated concurrent agent execution. |
| **Fossil** [R11] | Self-contained VCS, autosync and multiple checkouts | Useful reference for simplicity, local hosting, and cohesive workflow. | Not evidence that its autosync semantics match Yeokcham's private-first boundary. |
| **Claude Code** [R12][R13] | Parallel sessions via worktrees, documented `WorktreeCreate`/`WorktreeRemove` hooks allowing alternative VCS directory creation | Concrete integration target: a Yeokcham lane should be able to supply a safe working directory. | Claude Code may still use Git assumptions for cleanup; a hook is not a complete VCS-native integration contract. |
| **Codex agent execution** [R14][R15] | Independent agent environments and parallel subagents; separate contexts must coordinate when editing shared files | Reinforces the need to distinguish **agent context** from **filesystem/materialization state** and add a machine-readable change API. | An agent harness is not itself a version-control engine. |

### Strongest competitive challenge: Jujutsu

Jujutsu already records conflicts as structured states and allows later resolution rather than forcing every conflict into a blocked merge operation. Its working-copy model also automatically captures changes on ordinary `jj` commands, and it has multi-workspace support. [R5][R6][R7]

Yeokcham's **testable differentiation** must therefore be more specific:

- Automatic *background* capture even when no VCS command is invoked, with visible durability/retention limits.
- Native private backup and deliberate team availability separated from adoption, ideally with far less ceremony.
- A unified model for a human's two computers and multiple short-lived coding agents.
- A minimal plain-language interface with truthful preservation and recovery messages.
- Cross-machine, conflict-preserving workflows including documents and binary assets.

Whether these are actually superior is an **experiment**, not a conclusion.

---

## 6. Product principles and scope

### P0 — the five rules the user should remember

1. **Edit normally.** Yeokcham captures stable on-disk states at defined points without requiring an explicit `commit` ceremony.
2. **Never lose a valid independent contribution.** Conflicts do not erase a contributor's recorded work.
3. **Being available does not mean being applied.** Incoming data never silently alters an active workspace.
4. **Choose when to combine.** Integration is explicit, exact, reviewable, and consistent with repository policy.
5. **Humans and agents have the same safety model.** An agent may inspect and propose, but publication, authorization, and shared acceptance obey explicit capabilities.

### Target users, ordered for initial validation

1. **Solo programmer, 1–2 machines:** uninterrupted editing, effortless recovery, optional private backup and resumption.
2. **Small trusted team (2–5 people):** save and exchange without merge ceremony; resolve overlap only when adopting a shared state.
3. **One developer, several coding agents:** independent candidate work, comparison, testing, selection, and retention without branch/worktree bookkeeping.
4. **Source-plus-assets teams:** preserve documents/binaries; never claim automatic binary semantic merging.

Large enterprise monorepos, gigantic globally distributed agent swarms, semantic merge engines, sophisticated code-review governance, and hosted SaaS can be separate future research tracks.

### Proposed product-success tests

A novice can explain **saved vs backed up vs shared vs accepted**. A developer can edit on two computers without either machine being forced to throw away work. Three agents can work concurrently and provide inspectable candidates. A file conflict does not prevent future independent snapshots. A crash during restore cannot silently destroy the last valid content copy. A user can find a version from yesterday without knowing hashes or ref syntax.

---

## 7. Proposed conceptual model (discussion draft)

**Do not turn each noun into a separate command, daemon, or storage file.** The conceptual model needs to be clear even when the implementation is compact.

| Entity | Semantics | Identity/lifetime |
|---|---|---|
| **Repository** | Scope for trust, objects, and shared history | Stable repository ID |
| **Blob/chunk** | Exact file bytes, optionally chunked | Immutable content-addressed ID |
| **Snapshot** | Exact named tree of included filesystem states | Immutable content-addressed ID |
| **Capture** | One recorded occurrence in a workspace's history | Unique causal node; distinct from snapshot ID |
| **Workspace** | A local user's active editing context and file selection | Stable local identity and movable position |
| **Lane** *(provisional)* | Independently evolving candidate work from a human or agent | Stable lane ID; base, own captures, current candidate, lifecycle |
| **Published change** | Chosen candidate explicitly made visible under a publication policy | Immutable revision; does not leak unrelated private ancestry |
| **Conflict set** | Incompatible candidates with base, affected scope, provenance and unresolved choices | Durable record or derived view; no implicit winner |
| **Accepted version** | Deliberate team-level selected result with exact parents and evidence | Immutable result; mutable head references select current accepted states |
| **Transfer receipt** | Evidence that selected objects are verified and available at a destination | Durable, idempotent exchange metadata |
| **Policy/capability** | Who may publish, adopt, review, or administer | Verifiable scoped authority |

### Data separation

```text
               private local capture and history
                             |
                +------------+-------------+
                |                          |
          human workspace               agent lane(s)
                |                          |
                +------- candidate changes-+
                             |
                 policy-authorized publish
                             |
               available shared revisions
                             |
           explicit adoption / validation plan
                             |
                  accepted shared version
```

**Normal capture is not a commit to a shared branch.** Publishing makes a chosen candidate available. Accepting records the team's chosen composition. Each step can be independently observable.

### Concurrent-write rule

- New valid private captures may be appended without coordinating a shared branch head.
- New authorized published candidates may coexist against the same base.
- Shared accepted heads use explicit causal-parent references and atomic compare-and-set or equivalent durable reconciliation semantics; a concurrent offline advance must not disappear under “last writer wins.”
- If composition is not safely determined, record a conflict set and preserve the candidates; do not produce a false accepted version.
- A clean byte-level merge does **not** prove semantic correctness (e.g., incompatible API and test changes). Validation is a separate, configurable stage.

### What “conflict” actually means

1. **Content conflict:** overlapping edits or incompatible file types/modes, deletions/renames, opaque binaries.
2. **Candidate ambiguity:** several heads/versions are available; no single selection was requested.
3. **Policy conflict:** an otherwise valid content plan lacks authorization or approvals.
4. **Workspace obstruction:** applying a result would overwrite current local/private disk changes.
5. **Data unavailability:** a needed immutable dependency is missing or archived-only.

These must not collapse into a vague `merge failed`. Different conditions have different safe next actions. “Defer” is always a legitimate option when no shared acceptance is required immediately.

### Working-directory policy

**Default proposal:** Preserve variants inside the object store. Keep an active user's current files unchanged when a new candidate arrives. A `variants`, `compare`, or equivalent command shows alternate candidates and offers export/copy-out. Optionally create side-by-side copies under a user-specified staging path. Do not insert duplicate `.py` files automatically into a project's import/build path.

### The retention paradox

“Keep every state forever” conflicts with finite device storage. Distinguish **preservation guarantee** (a recorded state has verified reachable bytes or explicit unavailability) from **local cache residency** (what is physically on this machine). A future retention policy may archive old captures and evict local copies only *after verified durable backup*, with pinned history and offline expectations explicit. The existing project has draft 30-day / 5-GiB / 20-GiB preferences but not a completed product. [Y1][Y6]

---

## 8. Agent-native VCS: should a lane be a new primitive?

### The problem, precisely

Git worktrees isolate working directories and share an underlying repository; `jj` workspaces give distinct working-copy commits. These already solve a substantial portion of “two agents editing at once.” [R2][R6]

**Potential gap:** worktree management exposes filesystem directories, branches/commits, cleanup policy, and explicit coordination to agent harnesses. It does not by itself give the VCS a durable concept of an agent's task, candidate set, ephemeral lifetime, structured review/selection, or cheap no-checkout read operations.

### Three options to evaluate

| Option | Design | Strength | Cost/risk |
|---|---|---|---|
| **A. Worktree-compatible orchestration** | Keep VCS semantics unchanged, create separate directories on request | Minimal invention; fast integration with existing agent CLIs | Limited differentiator; little native task provenance or conflict management |
| **B. First-class lane + optional materialized workspace** **(recommended prototype)** | Lane ID with base, capture history, provenance, status, share/accept boundaries; materialize when a process needs a tree | Explicit concurrent candidates; programmatic inspection without checkout; safe lifecycle | New model complexity and lifecycle rules; must outperform simple worktree scripts |
| **C. Fully virtual/overlay workspaces** | Agents interact with virtual files/patches via API; lazily materialize for tests | Potentially very cheap forks and queries | Hard compatibility with real editors, compilers, package managers, watchers, symlinks, filesystem semantics; high implementation cost |

**Recommendation:** Prototype **B**, built initially on ordinary materialized directories and shared immutable objects. Add overlay/no-checkout capabilities **only after** demonstrating a measurable use case. Do not start with a filesystem driver or virtual mount.

### Proposed lane contract

A lane comprises:

```text
lane_id                  stable ID, independent of directory path
repository_id            host repository
base_accepted_version    immutable chosen starting point
owner                   human identity or agent capability + optional task label
captures                 lane-local causal history and latest candidate
materialization          none | directory path | ephemeral execution checkout
visibility               private | publishable | published (policy controlled)
status                   active | paused | completed | abandoned
retention                protected until safe handoff/archive rules permit cleanup
provenance               optional agent run/task metadata, not a source of truth
```

**Security and correctness:** The owner field does not automatically confer authority. Agent sessions may receive narrow write scopes; a lane cleanup cannot delete the last durable record of changes; and the system must not trust an LLM's verbal “tests passed” without actual validation receipts when such evidence is required.

### Candidate lane API (conceptual, not a stable public contract)

```python
lane = repo.create_lane(base="accepted/main", label="refactor-auth", actor=agent)
repo.capture(lane, materialized_path)            # explicit API; service may auto-capture
changes = repo.compare(lane.head, "accepted/main")
proposal = repo.propose(lane.head, target="main")
plan = repo.plan_accept(proposal, target="main")  # inspect; no filesystem changes
repo.accept(plan, authorization=capability)        # CAS + policy + validation
```

A real implementation needs typed structured results/errors, snapshot consistency, timeouts, cancellation, and a safer split between read and write authority. The illustration explains the intended interaction only.

### Example: three coding agents

1. Human picks a base accepted snapshot.
2. Agent A works on tests, B on API, C on docs. Each receives a lane (possibly with a separate directory).
3. They capture independently; B finishing does not force A or C to rebase.
4. The human or coordinator inspects the three candidate diffs via API and asks for a composition preview.
5. Nonoverlapping candidates can produce a proposed combined result. Overlap yields an explicit conflict set without deleting candidates.
6. Run tests on a materialized proposed result. Successful checks remain **evidence**, not a general guarantee.
7. Authorized acceptance advances a chosen shared version; abandoned lanes may be collected only after preservation/retention checks.

### Minimum proof that lanes add value

Compare a Yeokcham prototype to `git worktree add` + scripted coordination and `jj workspace add` under the *same* workload: 3–5 agents, independent and overlapping edits, failed agents, interrupted processes, and repeated restarts. Count setup steps, manual ref management, recovery interventions, disk duplication, contamination, time-to-inspect and time-to-integrate. If lanes do not improve a real metric or simplify the mental model, **do not ship the additional primitive**.

### Existing integration opportunity

Claude Code's documented `WorktreeCreate` hook can replace its default Git worktree creation by returning a directory from an alternative VCS. `WorktreeRemove` must be implemented carefully: Claude Code's cleanup may rely on Git-centric checks, so Yeokcham must independently verify preserved content before deleting anything. [R13]

A Codex integration should initially use a clear directory-based adapter plus a documented API/CLI; do not assume Codex automatically speaks Yeokcham. [R14][R15]

---

## 9. Everyday workflow and candidate CLI

**Important:** The commands below are interface sketches, not current commands or a final vocabulary. Minimize commands that users must remember; keep advanced inspection commands available to power users and agents.

### Experience A: one developer, one computer

```bash
yeokcham init                # register project; start local capture if service installed
# edit normally
yeokcham status              # captured here / privately backed up / needs attention
yeokcham history             # meaningful versions, readable titles, alternative paths
yeokcham restore <version>   # preview; preserve current work; exact recoverable replace
```

### Experience B: same person, two computers

```bash
# Mac and ThinkPad independently edit the same file while offline.
# Both capture locally. Later, both exchange with an authorized destination.
yeokcham status              # "2 independent versions available" is not an error
yeokcham variants engine.py  # show origin and diff information
yeokcham use <candidate>     # explicit local selection; preserve current state
```

**Neither machine should have to reconcile before uploading valid recorded changes.** Shared acceptance is a separate action.

### Experience C: small trusted team

```bash
yeokcham share               # private-first default: publish chosen edits
yeokcham available           # inspect others' candidate work
yeokcham accept <candidate>  # exact preview; policy and conflict validation
```

In a separately configured **trusted team** mode, an authorized lane's changes may become team-visible automatically. This must never be a silent global-default change because it changes privacy semantics.

### Experience D: multiple agents

```bash
yeokcham lane create --name api-refactor
yeokcham lane list
yeokcham compare lane:api-refactor accepted:main
yeokcham propose lane:api-refactor
yeokcham accept <proposal>  # requires appropriate capability/validation
```

Avoid a required `done`, `commit`, `push`, `fetch`, `share`, `accept` ceremony for ordinary local saving. A convenient `done` alias may request a fresh snapshot/backup but must not imply that backup finished merely because it was queued.

### Status must never lie

A status line must distinguish **captured locally** (durable local state), **backed up remotely** (verified complete acknowledgement), **published to teammates** (authorized shared closure), **accepted** (exact recorded team result), and **available offline** (present dependency closure). A pending transfer cannot be called safely backed up. Unsaved editor buffers cannot be called captured. [Y5]

---

## 10. Proposed Python architecture

### Main architectural principle

**A readable functional core, bounded effectful adapters, and a small public interface.** Retain OCaml's strongest architectural boundary without reproducing its module proliferation or large command dispatcher.

### Suggested package shape (not a module-by-module port)

```text
src/yeokcham/
    model/          # typed immutable domain records and pure state transitions
    objects/        # canonical encoding, hashing, chunking, trees, reads
    repository/     # mutable refs, causal heads, index/reachability, transactions
    workspace/      # reliable capture, excludes, materialize, restore journal
    collaboration/  # publication, receipt, variants, composition, acceptance
    lanes/          # lane lifecycle and optional checkout/materialization
    transport/      # native relay client and resumable verified object exchange
    identity/       # signing, scoped permissions, key adapters
    service/        # watchers, scheduling, background retry, state inspection
    api/            # structured Python interface and machine-readable outcomes
    cli/            # thin parsing and human-readable presentation

tests/
    unit/           # pure model and serialization
    property/       # invariants, state-machine tests
    fault/          # crash boundaries, interrupted copy/restore/sync
    journeys/       # real CLI multi-process and multi-workspace scenarios
    vectors/        # byte identities/golden independent fixtures
```

The eventual project may use fewer directories. Prefer modules grouped by a stable responsibility, not dozens of narrowly named layers merely because those layers exist in OCaml.

### Language and dependency policy

- **Python:** strongly typed data classes and enums for model records; `pathlib` for paths; `hashlib` for digests; explicit result/error types for operations that are expected to fail; contextual exceptions for programmer errors.
- **Tests:** `pytest` and `Hypothesis`; check behavior at process boundaries, not just pure functions.
- **Quality:** `ruff` plus `pyright` or `mypy` with strictness appropriate for domain modules. Document invariants in docstrings and tests.
- **Serialization:** evaluate a maintained canonical CBOR library if retaining CBOR. Do not assume regular JSON is a safe replacement for canonical signed bytes.
- **Compression:** use mature zstd bindings or codecs. Do not hand-write compression/crypto in Python.
- **Signatures/keys:** vetted Ed25519 implementations and OS-native custody adapters; same authority semantics, simpler user-facing onboarding.
- **CLI:** begin with the standard library if adequate; use a small CLI dependency only if it improves usability and testability. Avoid a UI framework before evidence calls for one.
- **Background work:** start with a portable foreground worker and reliable polling/reconciliation; add watchers as hints, not canonical sources of truth; platform-managed launch comes later.

### SQLite or filesystem metadata? **Open architecture decision**

**Option 1: Retain filesystem-managed immutable objects and atomic head files.** Best continuity with existing design and straightforward object inspection; potentially more custom journaling/index logic.

**Option 2: Immutable object files + SQLite for mutable metadata, ref heads, indexes, and operation records.** Could simplify transactional bookkeeping, indexing, and queries; creates cross-boundary consistency concerns between SQL commits and object files, requiring verified staged writes and recovery.

**Initial recommendation:** Keep immutable objects as files; **prototype SQLite only for mutable metadata after a fault-model review**. SQLite is not inherently simpler if source-to-object and object-to-database durability cannot be proved. Do not switch formats for aesthetic reasons.

### Performance rules

- Stream large files and chunk reads; never require loading multi-gigabyte blobs in a single Python `bytes` object.
- Hash/compress using mature native libraries.
- Use bounded queues and resource budgets for background capture.
- Debounce edits and verify stable file content; watchers are *hints* and full reconciliation is still needed after missed events/restarts.
- Protect against symlink loops, path traversal, file deletion during scans, replacement races, and weird filenames.
- Index what benchmarks show is slow; never build global fleet-style indices by default.

### Durable write ordering (conceptual)

1. Read a stable, scoped file state into immutable staged objects.
2. Verify the content/snapshot closure and fsync staged objects as required for the filesystem contract.
3. Commit the immutable objects into their durable object location.
4. Atomically advance the appropriate mutable pointer or SQL head while retaining sufficient recovery information.
5. Expose success only once the requested durability guarantee has actually been met.
6. On restart, recover or quarantine incomplete operations without losing the previous committed state.

Filesystem rename, directory sync, and SQLite transaction semantics vary by platform. The precise protocol requires design and fault-injection tests before implementation.

---

## 11. Simplification audit: preserve, simplify, defer, or drop

| Capability / complexity | Recommendation | Rationale |
|---|---|---|
| Immutable snapshots and exact byte fidelity | **Preserve** | Non-negotiable VCS correctness. |
| Separate local captures, publication, receipt and acceptance | **Preserve** | Central product value. |
| Durable journals, safe restore, stale-plan checks | **Preserve invariant; simplify implementation if proved safe** | Removing reliability to make Python code shorter is unacceptable. |
| Large V1/V2 coexistence and historic development formats | **Retire behind an explicit transition plan** | Project design already does not require obsolete development-format compatibility; do not delete live user data by assumption. |
| Main CLI dispatcher and large service orchestration | **Simplify** | Small adapters and clear workflow coordination are easier to understand. |
| Manual `save` as primary action | **De-emphasize** | Continuous capture is the proposed normal path. |
| Branches as obligatory unit of work | **Reconsider** | Lanes and direct candidate history may serve common cases without manual branches. Advanced branching remains useful. |
| Conflict variants stored as ordinary sibling source files | **Do not default to this** | Can disturb builds; expose via model and optional export. |
| Separate “delivery” after accepted integration | **Do not restore** | Existing accepted design already removes this ceremony. |
| Comprehensive PR/review-policy product | **Defer** | Small teams need simple initial acceptance. Preserve essential authorization and option for later required reviews. |
| LSP/semantic sidecar, AI-assisted conflict merge | **Defer** | Advisory AI is not needed for exact preservation. |
| Advanced key recovery, account-wide archive/quotas | **Separate later milestone** | Valuable but must not dominate first Python-native product; ensure no untrue backup claims. |
| Windows/virtual FS/huge monorepo optimizations | **Defer until correctness and measured need** | Focus first on Linux/macOS everyday journeys. |
| Every existing OCaml abstraction mirrored in Python | **Reject** | Migration goal is clarity, not syntactic translation. |

**Review warning:** “Simplify” is not synonymous with removing security. A smaller v2 feature set may simply *decline an unsupported operation* until there is a safe implementation, without weakening the promise of operations it does expose.

---

## 12. Migration strategy: design stages, then small Codex tranches

### Design gate D0 — Inventory the real baseline (read-only)

Deliver: a repository map and evidence inventory of current P1–P3 behavior, V1/Core overlap, test suite and failure status; list of observable guarantees with concrete file/function/test references; current CLI trace examples; no changes. Include the unresolved copy-out restore failure separately and avoid attributing its cause without reproduction.

**Exit criterion:** Every claimed current behavior has at least one code location and verification or a conspicuous evidence gap.

### Design gate D1 — Product contract and scope choices

Deliver: a one-page product promise, 5–8 representative user journeys, comparison against Git and jj, privacy modes, acceptance/conflict rules, candidate lane semantics, and explicit non-goals. Record any divergence from existing `docs/PRODUCT_DESIGN.md` and `docs/TECHNICAL_CONTRACTS.md` as an intentional proposal, not a quiet override.

**Exit criterion:** A novice can explain what Yeokcham does and why it exists in under one minute. A knowledgeable Git/jj user can name a real differentiator worth testing.

### Design gate D2 — Python model and persistence RFCs

Deliver: canonical domain records/state machine; concurrency and trust rules; object format decision; safe write/restore protocol; API and error schema; proposed Python module boundaries; dependency policy; risk register and acceptance tests.

**Exit criterion:** Two independent reviewers can explain crash behavior and the lifecycle of conflicting versions without inspecting runtime implementation code.

### Implementation tranche I0 — Python domain spike (not a port)

Small in-memory implementation and tests for snapshots, distinct capture identities, divergent candidates, conflict preservation, and explicit accepted heads. No network, daemon, signing or broad CLI yet.

**Gate:** Pure invariant tests and independent state-machine cases pass; the model stays intelligible.

### I1 — Durable local Python VCS

Streaming object storage, capture, inspect, ignore, history, exact restore, safe crash replay. Baseline `init/status/history/diff/restore` journeys; do not move the existing `.yeokcham` directory until explicit migration strategy chosen.

**Gate:** Exact-byte mixed-file restore, interrupted-operation safety, and no-loss local branching histories.

### I2 — Managed local capture, then private backup

Foreground worker first; watcher hints and reconciliation; platform lifecycle later. Honest durability statuses. Add private backup only when encryption, acknowledgement, recovery and eviction invariants are proven.

**Gate:** Edits are captured without VCS commands; missed events and restarts reconcile; no false “backed up” state.

### I3 — Native share/receipt/accept/conflicts

Selected publication, resumable verified exchange, causal candidates, precise composition, explicit confirmation and acceptance, authority, safe offline divergence and reconciliation.

**Gate:** Two-device and two-person paths work with valid, stale, malicious, missing and interrupted inputs; receiving does not touch working files.

### I4 — Agent lane experiment

Lane lifecycle and typed API; concrete directory adapter for Claude Code/Codex; compare three-agent experiments against Git and jj; measure whether a no-checkout query API creates meaningful savings.

**Gate:** Benefits shown empirically; no auto-cleanup data loss; lifecycle and permissions understandable.

### I5 — User-facing polish, packaging, benchmarks, dogfooding

Linux/macOS native installation, approachable CLI, representative solo/team/agent projects, restart and power-loss tests where feasible, reproducible benchmark matrix and user comprehension sessions. Decide which advanced features warrant reintroduction.

**Gate:** Users can complete target journeys without expert coaching, and all claims have measured evidence.

### What to do with existing OCaml code

**Do not rewrite in place.** Keep it as the behavioral oracle and golden-vector generator during the transition. Keep comparison fixtures reproducible and pin the exact OCaml revision used. Parallel-check Python behavior against independent vectors wherever semantics are intentionally conserved; document any changed semantics. The repository's D10 direction permits breaking obsolete experimental formats, but must not be misconstrued as permission to discard valuable work or sample history without explicit decision. Consider an **export-only one-way converter** after the new model stabilizes.

### Rule for future Codex prompts

Each prompt will specify: **(a)** exact current baseline and predecessor report, **(b)** allowed files, **(c)** hard invariants, **(d)** one focused deliverable, **(e)** negative/fault tests, **(f)** evidence/report format, **(g)** stop conditions. No multi-tranche “implement the whole VCS” prompts. A design gate is read-only or documentation-only until separately approved. Preserve unrelated work and do not unilaterally modify `README.md`.

---

## 13. Evaluation: how to prove the value proposition

### Everyday workflow study

For each scenario, run plain Git (with realistic documented scripts/plugins where applicable), Jujutsu, and Yeokcham under the same data, hardware, network and participant instructions:

| Scenario | Primary outcome to measure |
|---|---|
| Solo editing for one day | Number of obligatory VCS interactions; successfully recoverable intermediate on-disk states |
| Restore an abandoned experiment | Time-to-find and time-to-restore with no unrelated bytes lost |
| Two computers edit same file offline | Whether valid captures/exchange proceed without forced resolution; missing-data and winner-loss events |
| Small-team code handoff | Time to make candidate available, understand changes, and record accepted result |
| Two users replace one binary asset | Exact preservation, explanation quality, safe selection/copy-out |
| Three coding agents, independent tasks | Setup/cleanup steps, materialization time, total disk space, manual coordination |
| Three agents edit overlapping lines | Integrity of all variants; time to create safe candidate and diagnose conflict |
| Crash during capture, restore and sync | Number of irrecoverably lost acknowledged states; recovery path correctness |
| Disconnected capture and delayed backup | Honest local/private remote statuses and safe retention while upload is pending |

### Core metrics

- **Safety:** exact-byte fidelity; 0 acknowledged states silently lost in tested fault scenarios; no private-state leak in shared closure; invalid inputs refused.
- **UX:** commands, prompts, conflict interruptions, user mistakes, time to complete tasks, novice comprehension.
- **Resource cost:** idle CPU/memory, disk amplification, metadata cost, p50/p95 foreground latency, bytes transferred, resume efficiency.
- **Agent cost:** checkout/materialization time, number of shared-directory collisions, API calls/round trips, interrupted lane cleanup, ability to query without checkout.
- **Portability:** Linux/macOS file mode, symlink, empty-directory, case-sensitivity, filename and fsync edge cases; Windows when supported.

Use the existing benchmark design and G01 evidence as historical starting points, but make **Python-specific baselines** and task-level comparisons instead of declaring speedups from raw isolated timings. [Y7]

### Non-negotiable adversarial cases

- Malformed/oversized canonical records; wrong hashes/signatures; resource-exhaustion payloads.
- Symlink escape/path traversal; file changed between scan and apply; deletion/replacement races.
- Concurrent actors editing the same accepted head; inconsistent or stale approval/plan.
- Interrupted copy-out/restore, partial fsync and checkpoint ref advancement.
- Duplicate/reordered transfer receipts and acknowledgements; partially available dependencies.
- Ignored secrets or private draft bytes accidentally included in selected publication.
- Untrusted agent attempting to publish, accept, delete lane objects, or bypass a required review.
- Missing remote backup or quota exceeded before local retention/eviction.

A good performance number cannot substitute for passing these cases.

---

## 14. Preliminary decision register (all proposals, not final authorization)

| ID | Proposal | Confidence | Decision status |
|---|---|---|---|
| V2-01 | Python for domain, adapters, CLI and tests; native mature crypto/compression libraries allowed | High | **Proposed** |
| V2-02 | Local-first; no always-online requirement | High | **Proposed** |
| V2-03 | Automatic stable on-disk capture as a core product experience | High | **Proposed** |
| V2-04 | Preserve private/shared/available/accepted distinctions | High | **Proposed** |
| V2-05 | Nonblocking candidate preservation; explicit acceptance | High | **Proposed** |
| V2-06 | Private-first default; optional explicit trusted-team auto-publication | Medium | **Open — privacy/UX tradeoff** |
| V2-07 | First-class lane with materialized checkout initially | Medium | **Experiment before adoption** |
| V2-08 | Variants held in object store; copy-out only on request | High | **Proposed** |
| V2-09 | No automatic AI semantic merges or virtual filesystem in first release | High | **Proposed** |
| V2-10 | Immutable file objects; exact on-disk serialization and mutable metadata format TBD | Medium | **Open — RFC required** |
| V2-11 | Preserve full byte/trust/recovery guarantees on supported operations | High | **Proposed** |
| V2-12 | Read-only repository audit and design RFCs before Python implementation | High | **Proposed first action** |
| V2-13 | Baseline against Git, jj and scripted worktree workflows | High | **Proposed** |
| V2-14 | Do not retrofit obsolete OCaml-format compatibility by default; decide one-way export later | Medium | **Open — data inventory first** |

### Three decisions worth discussing after reading this document

1. **Default sharing:** Should solo/trusted teams automatically exchange eligible candidate work, or should automatic operation stop at **private backup** until the user explicitly shares? *Recommended starting default: private-first, with an opt-in trusted-team mode.*
2. **Agent lanes:** Should a new lane be visible as a normal named working context, or mostly hidden as an agent session detail? *Recommended starting default: visible through `lane list`, otherwise quiet; APIs retain full detail.*
3. **Who chooses accepted work:** Should the initial team model require deliberate `accept`, or allow an opt-in auto-accept policy for proven nonconflicting changes? *Recommended starting default: deliberate acceptance, with no mandatory review bureaucracy.*

These questions affect implementation, but **do not block the read-only design/audit work**.

---

## 15. Anti-goals and risks

**Risk: reinventing Jujutsu but with more bugs.** Mitigation: mandatory side-by-side tasks, focus on background capture/private backup/agent-lane experience rather than simply a different CLI.

**Risk: reducing code while weakening durability.** Mitigation: preserve explicit invariants, independent test vectors, fault injection, process-kill experiments, no “successful” operation before specified durable state.

**Risk: Python large-file inefficiency.** Mitigation: streaming, chunking, profiled caches, native libraries, no full-tree rescans on every keystroke, explicit memory budgets.

**Risk: a busy daemon causes more overhead than it saves.** Mitigation: debounce, watcher hints, reconciliation on restart, no-op detection, idle resource budgets, visible pause/resume, priorities for active editor processes.

**Risk: overcomplicated identity and review UX.** Mitigation: simple local/offline bootstrapping, transparent identity status, optional advanced governance; never silently bypass authorization.

**Risk: publishing secrets or unfinished agent output.** Mitigation: private-first capture, `.yeokchamignore`, exact selected scopes, capability-based publishing, no default team-wide private scratch export.

**Risk: “agent-native” becomes an agent orchestration platform.** Mitigation: the VCS owns durable candidate data, provenance and API; scheduling agents, model selection and prompt execution remain external.

**Risk: no tool ecosystem adoption.** Mitigation: add directory-based compatibility adapters for existing agent CLIs and a future one-time Git import/export story; do not promise bidirectional Git hosting in the first product.

**Risk: users confuse backed up with synced or accepted.** Mitigation: explicit states and concrete recovery availability in every interface.

**Risk: premature new format breaks the current pilot.** Mitigation: parallel implementation, pinned baseline, separate test stores, explicit cutover decision.

---

## 16. Working summary for future Codex sessions

> Yeokcham V2 is a **design-first** effort to rewrite a standalone OCaml VCS in **readable Python** while simplifying the product around invisible on-disk capture, conflict-preserving exchange, explicit accepted versions, and first-class human/agent lanes. It is not a Git wrapper and must not claim general performance superiority. Preserve exact bytes, trust, privacy, safe recovery, offline behavior and truthful status. Treat the existing P1–P3 implementation as the evidence-backed baseline; P4 is unstarted and latest full CI has an unresolved copy-out restore fixture failure. Casey Muratori's supplied transcript motivates a low-friction small-team UX; Anthropic Scion motivates cheap independent changes and APIs but not always-online architecture; Jujutsu is the mandatory comparator. **No code changes until the behavioral audit and design RFCs are reviewed.**

Recommended use: include this document as a reference in future scoped prompts; ask Codex to identify *exact* source files/tests and deviations before it edits. Do not ask it to implement a multi-phase rewrite in one run.

---

## 17. Source register and annotated references

### Yeokcham — repository-specific evidence

- **[Y0] User-provided Codex handoff**, checked against local repository on 18 November 2026 at `ce482b2` (uploaded into this conversation). Baseline project, stack, implementation and verification claims. It is a handoff, not independent reproduction.
- **[Y1] [Product design](https://github.com/gongahkia/yeokcham/blob/ce482b2/docs/PRODUCT_DESIGN.md)**. Historical product agreements (D01–D30), privacy/backup defaults, pilot ordering. Decisions in this document are not automatically new approvals.
- **[Y2] [Pilot plan](https://github.com/gongahkia/yeokcham/blob/ce482b2/docs/PILOT_PLAN.md)**. Clear distinction between P0/P1/P2/P3 delivered scope and P4 unstarted.
- **[Y3] [Implementation progress](https://github.com/gongahkia/yeokcham/blob/ce482b2/docs/IMPLEMENTATION_PROGRESS.md)**. Full roadmap ledger, per-revision verification, and latest unresolved CI observation.
- **[Y4] [Architecture](https://github.com/gongahkia/yeokcham/blob/ce482b2/docs/ARCHITECTURE.md)**. Current V1 pure model/effect boundaries, storage, relay and custody. Not an authoritative description of every newer Core detail.
- **[Y5] [CLI design](https://github.com/gongahkia/yeokcham/blob/ce482b2/docs/CLI_DESIGN.md)**. Exact plain-language status distinctions, preview and failure UX, planned default commands.
- **[Y6] [Technical contracts](https://github.com/gongahkia/yeokcham/blob/ce482b2/docs/TECHNICAL_CONTRACTS.md)**. TC01/TC02 accepted behavioral invariants, planned TC03–TC08 contracts.
- **[Y7] [Benchmark design](https://github.com/gongahkia/yeokcham/blob/ce482b2/docs/BENCHMARK_DESIGN.md)**. Exact-byte performance and portability workload matrix.
- **[Y8] [P3 implementation report](https://github.com/gongahkia/yeokcham/blob/ce482b2/docs/implementation/reports/P03-attempt-01.md)**. Reported automated two-member exchange/integration journeys and scoped CI at the named implementation revision.
- **[Y9] [P1–P3 interfaces](https://github.com/gongahkia/yeokcham/blob/ce482b2/docs/implementation/INTERFACES.md)**. Canonical record schemas and tested Core contracts to inventory before a Python rewrite.

### Supplied talk

- **[T1] Casey Muratori discussion transcript supplied by the user**, in this conversation on 18 November 2026. Source video was not linked; transcript contains likely speech-to-text errors and duplicated phrases. Treat as thematic input, not as independently verified exact quotations or formal specification.

### External primary sources (consulted 18 November 2026)

- **[R1] [Anthropic — Redesigning source control at Anthropic](https://www.anthropic.com/research/redesigning-source-control)** (13 October 2026, updated 15 October). Original account of Scion's always-online client/server design, cheap changesets, optional worktrees, API access and scaling limits. **Most important agent-scale architecture source.**
- **[R2] [Git — git-worktree](https://git-scm.com/docs/git-worktree)**. Linked working trees, per-worktree state, detached worktrees and cleanup; mandatory baseline for agent-lane comparisons.
- **[R3] [Git — git-merge](https://git-scm.com/docs/git-merge)**. Exact pre-merge checks, stage conflict behavior and non-destructive fetch/merge distinction; prevents caricaturing Git.
- **[R4] [Git — git-stash](https://git-scm.com/docs/git-stash)**. Local unfinished-work protection in native Git.
- **[R5] [Jujutsu — First-class conflicts](https://docs.jj-vcs.dev/latest/conflicts/)**. Structured, durable conflict states and delayed resolution; must-have conceptual comparator.
- **[R6] [Jujutsu — Working copy](https://docs.jj-vcs.dev/latest/working-copy/)**. Automatic snapshots around commands and treatment of conflict materialization.
- **[R7] [Jujutsu — CLI / workspaces](https://docs.jj-vcs.dev/latest/cli-reference/)** and [operation-log tutorial](https://docs.jj-vcs.dev/latest/tutorial/). Separate workspaces and operation history/undo.
- **[R8] [Meta — Sapling: source control that's user-friendly and scalable](https://engineering.fb.com/2022/11/15/open-source/sapling-source-control-scalable/)** and [Sapling overview](https://github.com/meta/sapling/blob/main/website/docs/introduction/introduction.md). Stacks, recovery, Watchman, sparse/virtual file system; public/internal feature boundaries matter.
- **[R9] [Pijul — Why Pijul?](https://pijul.org/manual/why_pijul.html)**. Change commutation and conflict-preserving graph semantics; theoretical prior art.
- **[R10] [GitButler — Parallel branches](https://docs.gitbutler.com/features/branch-management/virtual-branches)**. Multiple virtual branches in a single workdir; alternative to physical-worktree-first design.
- **[R11] [Fossil — Quick Start](https://www.fossil-scm.org/home/doc/trunk/www/quickstart.wiki)**. Cohesive VCS interface, independent checkouts and autosync.
- **[R12] [Claude Code — Common workflows](https://code.claude.com/docs/en/common-workflows)**. `claude --worktree` parallel session baseline.
- **[R13] [Claude Code — Hooks reference](https://code.claude.com/docs/en/hooks)**. `WorktreeCreate`/`WorktreeRemove` integration surface and non-Git cleanup pitfalls; direct practical integration target.
- **[R14] [OpenAI — Agent architecture](https://developers.openai.com/api/docs/guides/agents-api/architecture)**. Separation of agent harness, environment and app server; helps avoid conflating a VCS with agent execution.
- **[R15] [OpenAI — Multi-agent](https://developers.openai.com/api/docs/guides/agents-api/multi-agent)**. Parallel agents and the explicit need to coordinate edits to shared files.

### Next targeted investigation (not yet performed)

- Record real hands-on Git/jj/Yeokcham scripts and screen/terminal captures for representative tasks.
- Audit the latest exact OCaml code and failing restore fixture using the first **read-only Codex prompt**.
- Map current object layouts, restore journals and signing boundaries to the candidate Python modules.
- Prototype lane-versus-worktree behavior on a controlled 3-agent task before promising a genuinely new primitive.
- Revisit the exact Casey video when its original link or accurate transcript is available; this draft uses the supplied speech-to-text version.

---

### Reference link definitions

[Y1]: https://github.com/gongahkia/yeokcham/blob/ce482b2/docs/PRODUCT_DESIGN.md
[Y2]: https://github.com/gongahkia/yeokcham/blob/ce482b2/docs/PILOT_PLAN.md
[Y3]: https://github.com/gongahkia/yeokcham/blob/ce482b2/docs/IMPLEMENTATION_PROGRESS.md
[Y4]: https://github.com/gongahkia/yeokcham/blob/ce482b2/docs/ARCHITECTURE.md
[Y5]: https://github.com/gongahkia/yeokcham/blob/ce482b2/docs/CLI_DESIGN.md
[Y6]: https://github.com/gongahkia/yeokcham/blob/ce482b2/docs/TECHNICAL_CONTRACTS.md
[Y7]: https://github.com/gongahkia/yeokcham/blob/ce482b2/docs/BENCHMARK_DESIGN.md
[Y8]: https://github.com/gongahkia/yeokcham/blob/ce482b2/docs/implementation/reports/P03-attempt-01.md
[Y9]: https://github.com/gongahkia/yeokcham/blob/ce482b2/docs/implementation/INTERFACES.md
[R1]: https://www.anthropic.com/research/redesigning-source-control
[R2]: https://git-scm.com/docs/git-worktree
[R3]: https://git-scm.com/docs/git-merge
[R4]: https://git-scm.com/docs/git-stash
[R5]: https://docs.jj-vcs.dev/latest/conflicts/
[R6]: https://docs.jj-vcs.dev/latest/working-copy/
[R7]: https://docs.jj-vcs.dev/latest/cli-reference/
[R8]: https://engineering.fb.com/2022/11/15/open-source/sapling-source-control-scalable/
[R9]: https://pijul.org/manual/why_pijul.html
[R10]: https://docs.gitbutler.com/features/branch-management/virtual-branches
[R11]: https://www.fossil-scm.org/home/doc/trunk/www/quickstart.wiki
[R12]: https://code.claude.com/docs/en/common-workflows
[R13]: https://code.claude.com/docs/en/hooks
[R14]: https://developers.openai.com/api/docs/guides/agents-api/architecture
[R15]: https://developers.openai.com/api/docs/guides/agents-api/multi-agent

---

*End of research/design baseline v0.1. Its job is to make the next design discussion sharper, not to approve implementation.*
