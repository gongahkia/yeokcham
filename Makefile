CARGO ?= cargo

SBOM_OUTPUT ?= artifacts/sbom
FUZZ_SECONDS ?= 3600
FUZZ_OUTPUT ?=
BENCHMARK_BASELINE ?=
BENCHMARK_CANDIDATE ?=
MAX_REGRESSION_PERCENT ?=

.PHONY: help build server-release check fmt fmt-check lint test doc fixtures sbom audit fuzz-smoke fuzz-campaign benchmark-results performance-check ci

help:
	@echo "make build      build all workspace targets"
	@echo "make server-release build the standalone release server binary"
	@echo "make check      type-check all workspace targets"
	@echo "make fmt        format Rust sources"
	@echo "make fmt-check  verify Rust formatting"
	@echo "make lint       run Clippy with warnings denied"
	@echo "make test       run all tests and doctests"
	@echo "make doc        build documentation with warnings denied"
	@echo "make fixtures   regenerate and verify temporary Git fixtures"
	@echo "make sbom       generate CycloneDX SBOMs into $$(SBOM_OUTPUT)"
	@echo "make audit      audit workspace and fuzz dependencies"
	@echo "make fuzz-smoke run bounded libFuzzer smoke campaigns"
	@echo "make fuzz-campaign FUZZ_SECONDS=<seconds> FUZZ_OUTPUT=<absent-directory> run an isolated bounded fuzz campaign"
	@echo "make benchmark-results validate all committed benchmark result files"
	@echo "make performance-check BENCHMARK_BASELINE=<file> BENCHMARK_CANDIDATE=<file> MAX_REGRESSION_PERCENT=<percent> compare equivalent measurements"
	@echo "make ci         run the complete local CI gate"

build:
	$(CARGO) build --workspace --all-targets --all-features --locked

server-release:
	$(CARGO) build --release -p yeokcham-server --locked

check:
	$(CARGO) check --workspace --all-targets --all-features --locked

fmt:
	$(CARGO) fmt --all

fmt-check:
	$(CARGO) fmt --all -- --check

lint:
	$(CARGO) clippy --workspace --all-targets --all-features --locked -- -D warnings

test:
	$(CARGO) test --workspace --all-features --locked

doc:
	RUSTDOCFLAGS="-D warnings" $(CARGO) doc --workspace --all-features --no-deps --locked

fixtures:
	scripts/verify-git-fixtures.sh
	scripts/verify-pinned-history-fixture.sh
	scripts/verify-sparse-workspace-fixture.sh

sbom:
	scripts/generate-sbom.sh "$(SBOM_OUTPUT)"

audit:
	scripts/audit-dependencies.sh

fuzz-smoke:
	scripts/fuzz-smoke.sh

fuzz-campaign:
	@test -n "$(FUZZ_OUTPUT)" || { echo "FUZZ_OUTPUT=<absent-directory> is required" >&2; exit 2; }
	scripts/fuzz-campaign.sh "$(FUZZ_SECONDS)" "$(FUZZ_OUTPUT)"

benchmark-results:
	$(CARGO) test -p yeokcham-core --test benchmark_schema --locked

performance-check:
	@test -n "$(BENCHMARK_BASELINE)" && test -n "$(BENCHMARK_CANDIDATE)" && test -n "$(MAX_REGRESSION_PERCENT)" || { echo "BENCHMARK_BASELINE, BENCHMARK_CANDIDATE, and MAX_REGRESSION_PERCENT are required" >&2; exit 2; }
	scripts/check-benchmark-regression.sh "$(BENCHMARK_BASELINE)" "$(BENCHMARK_CANDIDATE)" "$(MAX_REGRESSION_PERCENT)"

ci: fixtures fmt-check check lint test doc audit
