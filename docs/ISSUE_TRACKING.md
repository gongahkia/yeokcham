# GitHub issue tracking

GitHub Issues is Yeokcham’s authoritative historical migration record and future
backlog. Live state is intentionally not duplicated here: inspect it with
`gh issue list --repo gongahkia/yeokcham --state open` or the
[issue tracker](https://github.com/gongahkia/yeokcham/issues). At the 2026-08-07
audit baseline, all 120 then-existing issues were closed; later work may create
new issues, so that count is evidence rather than a standing claim.

Historical migrated issues retain their immutable hidden
`<!-- paengi-todo-id: ID -->` marker, including [#44](https://github.com/gongahkia/yeokcham/issues/44).
Native Yeokcham follow-up issues use `<!-- yeokcham-todo-id: ID -->`; [#120](https://github.com/gongahkia/yeokcham/issues/120)
is the first such record. Issue [#119](https://github.com/gongahkia/yeokcham/issues/119)
predates that convention and has no marker. Do not rewrite, reuse, or infer a
marker; inspect the issue body when a precise linkage matters. Implementation
agents must inspect an issue’s body, labels, milestone, and GitHub blocking
relationships before selecting it. Close or update it only after its acceptance
criteria and verification evidence are complete. Architecture and
`needs-decision` blockers require approval before dependent implementation
begins.

## Migration map

| Former TODO ID | GitHub issue | Milestone | Disposition |
| --- | --- | --- | --- |
| M3-D01 | [#32](https://github.com/gongahkia/yeokcham/issues/32) | M3 Deferred | implemented; verified by deterministic budget selection, retained restore, and seeded compaction properties |
| M3-D02 | [#33](https://github.com/gongahkia/yeokcham/issues/33) | M3 Deferred | implemented; verified by retained-gap replay, exact inverse reduction, and seeded compaction properties |
| M3-D03 | [#35](https://github.com/gongahkia/yeokcham/issues/35) | M3 Deferred | implemented; verified by versioned host evidence, guarded restores, and seeded benchmark properties |
| M3-D04 | [#37](https://github.com/gongahkia/yeokcham/issues/37) | M3 Deferred | implemented; verified by linked versioned evidence, retained-pin restores, and seeded benchmark properties |
| M6-D01 | [#39](https://github.com/gongahkia/yeokcham/issues/39) | M6 Deferred | implemented; verified by passed-evidence restart/compaction coverage, structured failure cases, and seeded policy properties |
| M8-01 | [#44](https://github.com/gongahkia/yeokcham/issues/44) | M8 Git Bridge | closed; consult the issue for its historical acceptance evidence |
| M8-02 | [#47](https://github.com/gongahkia/yeokcham/issues/47) | M8 Git Bridge | implemented; verified |
| M8-03 | [#49](https://github.com/gongahkia/yeokcham/issues/49) | M8 Git Bridge | implemented; verified |
| M8-04 | [#51](https://github.com/gongahkia/yeokcham/issues/51) | M8 Git Bridge | implemented; verified |
| M8-05 | [#42](https://github.com/gongahkia/yeokcham/issues/42) | M8 Git Bridge | closed; consult the issue for its historical acceptance evidence |
| M8-06 | [#55](https://github.com/gongahkia/yeokcham/issues/55) | M8 Git Bridge | implemented; verified |
| M8-07 | [#58](https://github.com/gongahkia/yeokcham/issues/58) | M8 Git Bridge | implemented; verified |
| M8-08 | [#62](https://github.com/gongahkia/yeokcham/issues/62) | M8 Git Bridge | implemented; verified |
| M8-09 | [#65](https://github.com/gongahkia/yeokcham/issues/65) | M8 Git Bridge | implemented; verified |
| M8-10 | [#67](https://github.com/gongahkia/yeokcham/issues/67) | M8 Git Bridge | implemented; verified |
| M8-11 | [#70](https://github.com/gongahkia/yeokcham/issues/70) | M8 Git Bridge | implemented; verified by ADR-032–ADR-034 export ref policy |
| M8-12 | [#73](https://github.com/gongahkia/yeokcham/issues/73) | M8 Git Bridge | implemented; verified by ADR-028 export mappings |
| M8-13 | [#76](https://github.com/gongahkia/yeokcham/issues/76) | M8 Git Bridge | implemented; verified by M8 export fsck fixtures |
| M8-14 | [#79](https://github.com/gongahkia/yeokcham/issues/79) | M8 Git Bridge | implemented; verified by M8 export checkout oracles |
| M8-15 | [#82](https://github.com/gongahkia/yeokcham/issues/82) | M8 Git Bridge | implemented; documented interchange contract |
| M8-16 | [#85](https://github.com/gongahkia/yeokcham/issues/85) | M8 Git Bridge | implemented; verified |
| M8-17 | [#88](https://github.com/gongahkia/yeokcham/issues/88) | M8 Git Bridge | implemented; verified by M8 release export fixture |
| M8-18 | [#91](https://github.com/gongahkia/yeokcham/issues/91) | M8 Git Bridge | implemented; verified |
| M8-19 | [#94](https://github.com/gongahkia/yeokcham/issues/94) | M8 Git Bridge | implemented; verified |
| M9-01 | [#108](https://github.com/gongahkia/yeokcham/issues/108) | M9 Rust Semantic Sidecar | implemented; verified by ADR-035 and focused/property coverage |
| M9-02 | [#110](https://github.com/gongahkia/yeokcham/issues/110) | M9 Rust Semantic Sidecar | implemented; verified by ADR-036 module-path goldens and focused/property coverage |
| M9-03 | [#112](https://github.com/gongahkia/yeokcham/issues/112) | M9 Rust Semantic Sidecar | implemented; verified by ADR-037 fallback goldens and focused/property coverage |
| M9-04 | [#114](https://github.com/gongahkia/yeokcham/issues/114) | M9 Rust Semantic Sidecar | implemented; verified by bounded Rust fixture oracles and focused/property coverage |
| M9-05 | [#116](https://github.com/gongahkia/yeokcham/issues/116) | M9 Rust Semantic Sidecar | implemented; verified by language-separated schema report and focused/property coverage |
| M9-06 | [#118](https://github.com/gongahkia/yeokcham/issues/118) | M9 Rust Semantic Sidecar | implemented; verified by focused Rust adapter/fixture coverage and checked comparison schemas |
| M10-01 | [#1](https://github.com/gongahkia/yeokcham/issues/1) | M10 Local Synchronisation | implemented; verified by ADR-038 frame/local-store fixtures and seeded restart properties |
| M10-02 | [#2](https://github.com/gongahkia/yeokcham/issues/2) | M10 Local Synchronisation | implemented; verified by ADR-039 Ed25519 fixtures, unchanged-ref local-store coverage, and seeded chain properties |
| M10-03 | [#3](https://github.com/gongahkia/yeokcham/issues/3) | M10 Local Synchronisation | implemented; verified by ADR-040 public-record fixtures, unchanged-ref local-device coverage, and seeded restart properties |
| M10-04 | [#4](https://github.com/gongahkia/yeokcham/issues/4) | M10 Local Synchronisation | implemented; verified by bounded HTTP frame/TCP restart coverage and seeded state-machine properties |
| M10-05 | [#5](https://github.com/gongahkia/yeokcham/issues/5) | M10 Local Synchronisation | implemented; verified by ADR-041 set/binding goldens, local merge/reopen rejections, and seeded delivery properties |
| M10-06 | [#6](https://github.com/gongahkia/yeokcham/issues/6) | M10 Local Synchronisation | implemented; verified by ADR-042 encrypted-bundle fixtures and seeded properties |
| M10-07 | [#7](https://github.com/gongahkia/yeokcham/issues/7) | M10 Local Synchronisation | implemented; verified by two-device integration and seeded restart properties |
| M10-08 | [#8](https://github.com/gongahkia/yeokcham/issues/8) | M10 Local Synchronisation | implemented; verified by ADR-043 directory fixtures and seeded properties |
| M10-09 | [#9](https://github.com/gongahkia/yeokcham/issues/9) | M10 Local Synchronisation | implemented; verified by deterministic missing-only exchange and seeded properties |
| M10-10 | [#10](https://github.com/gongahkia/yeokcham/issues/10) | M10 Local Synchronisation | implemented; verified by workspace/release divergence fixtures |
| M10-11 | [#11](https://github.com/gongahkia/yeokcham/issues/11) | M10 Local Synchronisation | implemented; verified by self-contained two-repository direct/offline fixture and seeded restart/corruption properties |
| M11-01 | [#12](https://github.com/gongahkia/yeokcham/issues/12) | M11 Demonstration and Reporting | implemented; verified by guarded scripted fixture and focused creation/failure/cleanup coverage |
| M11-02 | [#13](https://github.com/gongahkia/yeokcham/issues/13) | M11 Demonstration and Reporting | implemented; verified by exact restore/safety-checkpoint fixture coverage |
| M11-03 | [#14](https://github.com/gongahkia/yeokcham/issues/14) | M11 Demonstration and Reporting | implemented; verified by retained-ID exact-restore and explicit-prune fixture coverage |
| M11-04 | [#20](https://github.com/gongahkia/yeokcham/issues/20) | M11 Demonstration and Reporting | implemented; verified by stable-ID, immutable-revision, replay, and unconfirmed-plan fixture coverage |
| M11-05 | [#23](https://github.com/gongahkia/yeokcham/issues/23) | M11 Demonstration and Reporting | implemented; verified by deterministic order, independent selection, and read-only base-resolution fixture coverage |
| M11-06 | [#25](https://github.com/gongahkia/yeokcham/issues/25) | M11 Demonstration and Reporting | implemented; verified by persistent-conflict, independent-continuation, explicit-skip, and unsupported-action fixture coverage |
| M11-07 | [#27](https://github.com/gongahkia/yeokcham/issues/27) | M11 Demonstration and Reporting | implemented; verified by nonpersistent uncertainty, fallback, ambiguity, textual-result, and structured-error fixture coverage |
| M11-08 | [#30](https://github.com/gongahkia/yeokcham/issues/30) | M11 Demonstration and Reporting | implemented; verified by immutable release, logical evidence identity, invalid-parent, and post-release scratch fixture coverage |
| M11-09 | [#97](https://github.com/gongahkia/yeokcham/issues/97) | M11 Demonstration and Reporting | implemented; verified by local fsck, exact byte/mode/symlink, no-remote, and invalid-destination fixture coverage |
| M11-10 | [#117](https://github.com/gongahkia/yeokcham/issues/117) | M11 Demonstration and Reporting | implemented; verified by versioned evidence index, direct Git-export fixture, and seeded repository checks |
| M11-11 | [#100](https://github.com/gongahkia/yeokcham/issues/100) | M11 Demonstration and Reporting | implemented; verified by source-labelled comparative-report and Git-export fixture coverage |
| M11-12 | [#103](https://github.com/gongahkia/yeokcham/issues/103) | M11 Demonstration and Reporting | implemented; verified by architecture-boundary report and Git-export fixture coverage |
| M12-01 | [#120](https://github.com/gongahkia/yeokcham/issues/120) | M12 Inspectable CLI and durable capsule operations | implemented; verified by read-only inspection, durable-retarget conflict/reopen, stale-publication inventory, seeded state-machine, and full repository checks |
| M12-02 | [#121](https://github.com/gongahkia/yeokcham/issues/121) | M12 Maintenance and documentation reconciliation | implemented; verified by live GitHub reconciliation, CLI help exit checks, project checks, and workflow lint |

## Migration verification

The former `TODO.md` had 53 unchecked actionable items: all map one-to-one to
the 53 primary issues above. The table records migration linkage and disposition,
not live issue state; consult GitHub for the latter. No source item was stale,
deduplicated, or split. During remote migration, 65 duplicate issue artifacts
caused by interrupted replay were marked GitHub duplicates of their canonical
issue and closed; they are not backlog items. This is the documented deviation
from 53 total created issue records.
