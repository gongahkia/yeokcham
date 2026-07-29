SHELL := /bin/sh
OPAM ?= opam
DUNE := $(OPAM) exec -- dune
OCAML_VERSION := 5.5.0
OCAMLFORMAT_VERSION := 0.29.0
LOCAL_SWITCH := $(CURDIR)

.PHONY: setup deps build test lint check format workflow-lint ci fuzz-smoke fuzz

setup:
	$(OPAM) init --bare --no-setup --yes
	$(OPAM) switch list --short | grep -Fqx '$(LOCAL_SWITCH)' || $(OPAM) switch create . ocaml-base-compiler.$(OCAML_VERSION) --no-install --yes
	$(MAKE) deps

deps:
	$(OPAM) install . --deps-only --with-test --yes
	$(OPAM) install ocamlformat.$(OCAMLFORMAT_VERSION) --yes

build:
	$(DUNE) build @all

test:
	$(DUNE) runtest

lint:
	$(DUNE) build @opam @fmt @lint @all
	$(OPAM) lint paengi.opam

check: lint test

format:
	$(DUNE) fmt

workflow-lint:
	actionlint .github/workflows/ci.yml

ci: check workflow-lint

fuzz-smoke:
	$(DUNE) build @fuzz-smoke

FUZZ_SECONDS ?= 60
FUZZ_OUTPUT ?= _build/fuzz/encoding
FUZZ_INPUT ?= fuzz/corpus
FUZZ_OPAM_SWITCH ?=
FUZZ_DUNE = $(if $(FUZZ_OPAM_SWITCH),$(OPAM) exec --switch=$(FUZZ_OPAM_SWITCH) -- dune,$(DUNE))
FUZZ_BINARY = _build/default/fuzz/fuzz_encoding.exe

fuzz:
	@test ! -e "$(FUZZ_OUTPUT)" || { echo "refusing existing fuzz output: $(FUZZ_OUTPUT)" >&2; exit 2; }
	$(FUZZ_DUNE) build --profile afl fuzz/fuzz_encoding.exe
	@mkdir -p "$(dir $(FUZZ_OUTPUT))"
	AFL_I_DONT_CARE_ABOUT_MISSING_CRASHES=1 AFL_SKIP_CPUFREQ=1 afl-fuzz -V $(FUZZ_SECONDS) -i $(FUZZ_INPUT) -o $(FUZZ_OUTPUT) -- ./$(FUZZ_BINARY) @@
