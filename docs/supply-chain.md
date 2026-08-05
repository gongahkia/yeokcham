# Local supply-chain checks

These commands are local and provider-neutral. They do not publish an artefact or use GitHub Actions.

## Dependency audit

Install the pinned tool once:

```text
cargo install cargo-audit --version 0.22.2 --locked
```

Run:

```text
make audit
```

The check denies RustSec vulnerability, unmaintained, unsound, and yanked-package warnings for both `Cargo.lock` and `fuzz/Cargo.lock`. It refreshes the advisory database by default. `YEOKCHAM_AUDIT_OFFLINE=1 make audit` uses an existing database and permits it to be stale; use that only when a fresh advisory fetch is unavailable.

## SBOM

Install the pinned tool once:

```text
cargo install cargo-cyclonedx --version 0.5.9 --locked
```

Generate a release input into an absent directory:

```text
make sbom SBOM_OUTPUT=artifacts/sbom-<release-id>
```

The generator pins `SOURCE_DATE_EPOCH` to the checked-out commit timestamp, emits CycloneDX 1.5 JSON for every workspace package and validates the expected four files before publishing the directory. `SHA256SUMS` covers the emitted JSON files. The output is ignored by Git and can contain local path metadata, so inspect it before external publication. The script refuses an existing output directory and rejects an unexpected tool version or lockfile mutation.

The SBOM describes the current checked-out workspace dependency graph. Generate it only from a reviewed checkout; Cargo tooling can execute build-script-adjacent project metadata workflows.
