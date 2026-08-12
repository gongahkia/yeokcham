SHELL := /bin/sh
OPAM ?= opam
DUNE := $(OPAM) exec -- dune
OCAML_VERSION := 5.5.0
OCAMLFORMAT_VERSION := 0.29.0
LOCAL_SWITCH := $(CURDIR)

.PHONY: setup deps build test property-test secret-service-integration keychain-integration rust-adapter-build rust-adapter-test secure-runtime-build secure-runtime-test typescript-adapter-deps typescript-adapter-test browser-vault-deps browser-vault-test benchmark-encoding benchmark-large-content compaction-retention-benchmark compaction-retention-benchmark-verify semantic-experiment semantic-experiment-verify rust-retargeting-comparison rust-retargeting-comparison-verify marshal-audit lint check format workflow-lint ci

setup:
	$(OPAM) init --bare --no-setup --yes
	$(OPAM) switch list --short | grep -Fqx '$(LOCAL_SWITCH)' || $(OPAM) switch create . ocaml-base-compiler.$(OCAML_VERSION) --no-install --yes
	$(MAKE) deps

deps:
	$(OPAM) install . --deps-only --with-test --yes
	$(OPAM) install ocamlformat.$(OCAMLFORMAT_VERSION) --yes
	$(MAKE) typescript-adapter-deps
	$(MAKE) browser-vault-deps

build:
	$(DUNE) build @all

rust-adapter-build:
	cd tools/yeokcham-rust-adapter && cargo build --locked --release

rust-adapter-test:
	cd tools/yeokcham-rust-adapter && cargo fmt --check
	cd tools/yeokcham-rust-adapter && cargo test --locked

secure-runtime-build:
	cd tools/yeokcham-secure-runtime && cargo build --locked --release

secure-runtime-test:
	cd tools/yeokcham-secure-runtime && cargo fmt --check
	cd tools/yeokcham-secure-runtime && cargo test --locked

typescript-adapter-deps:
	cd tools/yeokcham-typescript-adapter && npm ci --ignore-scripts --no-audit --no-fund

typescript-adapter-test:
	cd tools/yeokcham-typescript-adapter && npm test

browser-vault-deps:
	cd tools/yeokcham-browser-vault && npm ci --ignore-scripts --no-audit --no-fund

browser-vault-test:
	cd tools/yeokcham-browser-vault && npm test

test: rust-adapter-build rust-adapter-test secure-runtime-build secure-runtime-test typescript-adapter-test browser-vault-test
	YEOKCHAM_RUST_ADAPTER=$(CURDIR)/tools/yeokcham-rust-adapter/target/release/yeokcham-rust-adapter YEOKCHAM_MLS_RUNTIME=$(CURDIR)/tools/yeokcham-secure-runtime/target/release/yeokcham-secure-runtime $(DUNE) runtest

PROPERTY_TEST_SEED ?= 20260729

property-test: rust-adapter-build secure-runtime-build browser-vault-test
	YEOKCHAM_RUST_ADAPTER=$(CURDIR)/tools/yeokcham-rust-adapter/target/release/yeokcham-rust-adapter YEOKCHAM_MLS_RUNTIME=$(CURDIR)/tools/yeokcham-secure-runtime/target/release/yeokcham-secure-runtime PROPERTY_TEST_SEED=$(PROPERTY_TEST_SEED) $(DUNE) build @property-test

secret-service-integration:
	test "$$YEOKCHAM_RUN_SECRET_SERVICE_INTEGRATION" = 1
	$(DUNE) exec test/v2_secret_service_native.exe

keychain-integration:
	test "$$(uname)" = Darwin
	test "$$YEOKCHAM_RUN_KEYCHAIN_INTEGRATION" = 1
	$(DUNE) exec test/v2_macos_keychain_native.exe

benchmark-encoding:
	BENCHMARK_DUNE_PROFILE=release $(DUNE) exec --profile release bench/encoding_benchmark.exe -- --output bench/results/canonical-codec-v1.json

benchmark-large-content:
	BENCHMARK_DUNE_PROFILE=release $(DUNE) exec --profile release bench/large_content_benchmark.exe -- --output bench/results/large-content-v1.json

compaction-retention-benchmark:
	BENCHMARK_DUNE_PROFILE=release $(DUNE) exec --profile release test/compaction_retention_benchmark.exe -- --output docs/experiments/results/scratch-retention-benchmark-v1.json --repetitions 5
	python3 -m jsonschema --instance docs/experiments/results/scratch-retention-benchmark-v1.json docs/experiments/schema/scratch-retention-benchmark-v1.schema.json

compaction-retention-benchmark-verify:
	python3 -m jsonschema --instance docs/experiments/results/scratch-retention-benchmark-v1.json docs/experiments/schema/scratch-retention-benchmark-v1.schema.json

semantic-experiment:
	$(DUNE) exec test/semantic_retargeting_experiment.exe -- --output docs/experiments/results/semantic-retargeting-v1.json
	python3 -m jsonschema --instance docs/experiments/results/semantic-retargeting-v1.json docs/experiments/schema/semantic-retargeting-v1.schema.json

semantic-experiment-verify:
	python3 -m jsonschema --instance docs/experiments/results/semantic-retargeting-v1.json docs/experiments/schema/semantic-retargeting-v1.schema.json

rust-retargeting-comparison:
	$(DUNE) exec test/rust_typescript_retargeting_comparison.exe -- --output docs/experiments/results/rust-typescript-retargeting-comparison-v1.json
	python3 -m jsonschema --instance docs/experiments/results/rust-typescript-retargeting-comparison-v1.json docs/experiments/schema/rust-typescript-retargeting-comparison-v1.schema.json

rust-retargeting-comparison-verify:
	python3 -m jsonschema --instance docs/experiments/results/rust-typescript-retargeting-comparison-v1.json docs/experiments/schema/rust-typescript-retargeting-comparison-v1.schema.json

marshal-audit:
	sh tools/check_persistent_format.sh

lint:
	$(DUNE) build @opam @fmt @lint @all
	$(OPAM) lint yeokcham.opam

check: lint test marshal-audit compaction-retention-benchmark-verify semantic-experiment-verify rust-retargeting-comparison-verify

format:
	$(DUNE) fmt

workflow-lint:
	actionlint .github/workflows/ci.yml

ci: check workflow-lint
