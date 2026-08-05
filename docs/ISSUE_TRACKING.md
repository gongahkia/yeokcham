# GitHub issue tracking

GitHub Issues is Paengi’s authoritative backlog: [open issues](https://github.com/gongahkia/paengi/issues). To inspect it locally, run `gh issue list --repo gongahkia/paengi --state open`.

Each migrated issue has an immutable hidden marker, `<!-- paengi-todo-id: ID -->`, linking it to the former backlog entry. Do not reuse a marker. Implementation agents must select an open issue only after inspecting its body, labels, milestone, and GitHub blocking relationships. Close or update that issue only when its acceptance criteria and verification evidence are complete. Architecture and `needs-decision` blockers require approval before dependent implementation begins.

## Migration map

| Former TODO ID | GitHub issue | Milestone | Disposition |
| --- | --- | --- | --- |
| M3-D01 | [#32](https://github.com/gongahkia/paengi/issues/32) | M3 Deferred | created |
| M3-D02 | [#33](https://github.com/gongahkia/paengi/issues/33) | M3 Deferred | created |
| M3-D03 | [#35](https://github.com/gongahkia/paengi/issues/35) | M3 Deferred | created |
| M3-D04 | [#37](https://github.com/gongahkia/paengi/issues/37) | M3 Deferred | created |
| M6-D01 | [#39](https://github.com/gongahkia/paengi/issues/39) | M6 Deferred | created |
| M8-01 | [#44](https://github.com/gongahkia/paengi/issues/44) | M8 Git Bridge | created |
| M8-02 | [#47](https://github.com/gongahkia/paengi/issues/47) | M8 Git Bridge | implemented; verified |
| M8-03 | [#49](https://github.com/gongahkia/paengi/issues/49) | M8 Git Bridge | implemented; verified |
| M8-04 | [#51](https://github.com/gongahkia/paengi/issues/51) | M8 Git Bridge | implemented; verified |
| M8-05 | [#42](https://github.com/gongahkia/paengi/issues/42) | M8 Git Bridge | created |
| M8-06 | [#55](https://github.com/gongahkia/paengi/issues/55) | M8 Git Bridge | implemented; verified |
| M8-07 | [#58](https://github.com/gongahkia/paengi/issues/58) | M8 Git Bridge | implemented; verified |
| M8-08 | [#62](https://github.com/gongahkia/paengi/issues/62) | M8 Git Bridge | implemented; verified |
| M8-09 | [#65](https://github.com/gongahkia/paengi/issues/65) | M8 Git Bridge | implemented; verified |
| M8-10 | [#67](https://github.com/gongahkia/paengi/issues/67) | M8 Git Bridge | implemented; verified |
| M8-11 | [#70](https://github.com/gongahkia/paengi/issues/70) | M8 Git Bridge | implemented; verified by ADR-032–ADR-034 export ref policy |
| M8-12 | [#73](https://github.com/gongahkia/paengi/issues/73) | M8 Git Bridge | implemented; verified by ADR-028 export mappings |
| M8-13 | [#76](https://github.com/gongahkia/paengi/issues/76) | M8 Git Bridge | implemented; verified by M8 export fsck fixtures |
| M8-14 | [#79](https://github.com/gongahkia/paengi/issues/79) | M8 Git Bridge | implemented; verified by M8 export checkout oracles |
| M8-15 | [#82](https://github.com/gongahkia/paengi/issues/82) | M8 Git Bridge | implemented; documented interchange contract |
| M8-16 | [#85](https://github.com/gongahkia/paengi/issues/85) | M8 Git Bridge | implemented; verified |
| M8-17 | [#88](https://github.com/gongahkia/paengi/issues/88) | M8 Git Bridge | implemented; verified by M8 release export fixture |
| M8-18 | [#91](https://github.com/gongahkia/paengi/issues/91) | M8 Git Bridge | implemented; verified |
| M8-19 | [#94](https://github.com/gongahkia/paengi/issues/94) | M8 Git Bridge | implemented; verified |
| M9-01 | [#108](https://github.com/gongahkia/paengi/issues/108) | M9 Rust Semantic Sidecar | implemented; verified by ADR-035 and focused/property coverage |
| M9-02 | [#110](https://github.com/gongahkia/paengi/issues/110) | M9 Rust Semantic Sidecar | ADR-036 accepted; implementation in progress |
| M9-03 | [#112](https://github.com/gongahkia/paengi/issues/112) | M9 Rust Semantic Sidecar | created |
| M9-04 | [#114](https://github.com/gongahkia/paengi/issues/114) | M9 Rust Semantic Sidecar | created |
| M9-05 | [#116](https://github.com/gongahkia/paengi/issues/116) | M9 Rust Semantic Sidecar | created |
| M9-06 | [#118](https://github.com/gongahkia/paengi/issues/118) | M9 Rust Semantic Sidecar | created |
| M10-01 | [#1](https://github.com/gongahkia/paengi/issues/1) | M10 Local Synchronisation | created |
| M10-02 | [#2](https://github.com/gongahkia/paengi/issues/2) | M10 Local Synchronisation | created |
| M10-03 | [#3](https://github.com/gongahkia/paengi/issues/3) | M10 Local Synchronisation | created |
| M10-04 | [#4](https://github.com/gongahkia/paengi/issues/4) | M10 Local Synchronisation | created |
| M10-05 | [#5](https://github.com/gongahkia/paengi/issues/5) | M10 Local Synchronisation | created |
| M10-06 | [#6](https://github.com/gongahkia/paengi/issues/6) | M10 Local Synchronisation | created |
| M10-07 | [#7](https://github.com/gongahkia/paengi/issues/7) | M10 Local Synchronisation | created |
| M10-08 | [#8](https://github.com/gongahkia/paengi/issues/8) | M10 Local Synchronisation | created |
| M10-09 | [#9](https://github.com/gongahkia/paengi/issues/9) | M10 Local Synchronisation | created |
| M10-10 | [#10](https://github.com/gongahkia/paengi/issues/10) | M10 Local Synchronisation | created |
| M10-11 | [#11](https://github.com/gongahkia/paengi/issues/11) | M10 Local Synchronisation | created |
| M11-01 | [#12](https://github.com/gongahkia/paengi/issues/12) | M11 Demonstration and Reporting | created |
| M11-02 | [#13](https://github.com/gongahkia/paengi/issues/13) | M11 Demonstration and Reporting | created |
| M11-03 | [#14](https://github.com/gongahkia/paengi/issues/14) | M11 Demonstration and Reporting | created |
| M11-04 | [#20](https://github.com/gongahkia/paengi/issues/20) | M11 Demonstration and Reporting | created |
| M11-05 | [#23](https://github.com/gongahkia/paengi/issues/23) | M11 Demonstration and Reporting | created |
| M11-06 | [#25](https://github.com/gongahkia/paengi/issues/25) | M11 Demonstration and Reporting | created |
| M11-07 | [#27](https://github.com/gongahkia/paengi/issues/27) | M11 Demonstration and Reporting | created |
| M11-08 | [#30](https://github.com/gongahkia/paengi/issues/30) | M11 Demonstration and Reporting | created |
| M11-09 | [#97](https://github.com/gongahkia/paengi/issues/97) | M11 Demonstration and Reporting | created |
| M11-10 | [#117](https://github.com/gongahkia/paengi/issues/117) | M11 Demonstration and Reporting | created |
| M11-11 | [#100](https://github.com/gongahkia/paengi/issues/100) | M11 Demonstration and Reporting | created |
| M11-12 | [#103](https://github.com/gongahkia/paengi/issues/103) | M11 Demonstration and Reporting | created |

## Migration verification

The former `TODO.md` had 53 unchecked actionable items: all map one-to-one to the 53 open primary issues above. No source item was stale, deduplicated, or split. During remote migration, 65 duplicate issue artifacts caused by interrupted replay were marked GitHub duplicates of their canonical issue and closed; they are not backlog items. This is the documented deviation from 53 total created issue records.
