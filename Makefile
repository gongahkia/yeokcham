SHELL := /bin/sh
OPAM ?= opam
DUNE := $(OPAM) exec -- dune
OCAML_VERSION := 5.5.0
OCAMLFORMAT_VERSION := 0.29.0
LOCAL_SWITCH := $(CURDIR)

.PHONY: setup deps build test property-test rust-adapter-build rust-adapter-test benchmark-encoding benchmark-large-content semantic-experiment semantic-experiment-verify marshal-audit lint check format workflow-lint ci

setup:
	$(OPAM) init --bare --no-setup --yes
	$(OPAM) switch list --short | grep -Fqx '$(LOCAL_SWITCH)' || $(OPAM) switch create . ocaml-base-compiler.$(OCAML_VERSION) --no-install --yes
	$(MAKE) deps

deps:
	$(OPAM) install . --deps-only --with-test --yes
	$(OPAM) install ocamlformat.$(OCAMLFORMAT_VERSION) --yes

build:
	$(DUNE) build @all

rust-adapter-build:
	cd tools/paengi-rust-adapter && cargo build --locked --release

rust-adapter-test:
	cd tools/paengi-rust-adapter && cargo fmt --check
	cd tools/paengi-rust-adapter && cargo test --locked

test: rust-adapter-build rust-adapter-test
	PAENGI_RUST_ADAPTER=$(CURDIR)/tools/paengi-rust-adapter/target/release/paengi-rust-adapter $(DUNE) runtest

PROPERTY_TEST_SEED ?= 20260729

property-test: rust-adapter-build
	PAENGI_RUST_ADAPTER=$(CURDIR)/tools/paengi-rust-adapter/target/release/paengi-rust-adapter PROPERTY_TEST_SEED=$(PROPERTY_TEST_SEED) $(DUNE) build @property-test

benchmark-encoding:
	BENCHMARK_DUNE_PROFILE=release $(DUNE) exec --profile release bench/encoding_benchmark.exe -- --output bench/results/canonical-codec-v1.json

benchmark-large-content:
	BENCHMARK_DUNE_PROFILE=release $(DUNE) exec --profile release bench/large_content_benchmark.exe -- --output bench/results/large-content-v1.json

semantic-experiment:
	$(DUNE) exec test/semantic_retargeting_experiment.exe -- --output docs/experiments/results/semantic-retargeting-v1.json
	python3 -m jsonschema --instance docs/experiments/results/semantic-retargeting-v1.json docs/experiments/schema/semantic-retargeting-v1.schema.json

semantic-experiment-verify:
	python3 -m jsonschema --instance docs/experiments/results/semantic-retargeting-v1.json docs/experiments/schema/semantic-retargeting-v1.schema.json

marshal-audit:
	sh tools/check_persistent_format.sh

lint:
	$(DUNE) build @opam @fmt @lint @all
	$(OPAM) lint paengi.opam

check: lint test marshal-audit semantic-experiment-verify

format:
	$(DUNE) fmt

workflow-lint:
	actionlint .github/workflows/ci.yml

ci: check workflow-lint
