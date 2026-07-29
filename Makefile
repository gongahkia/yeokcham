SHELL := /bin/sh
OPAM ?= opam
DUNE := $(OPAM) exec -- dune
OCAML_VERSION := 5.5.0
OCAMLFORMAT_VERSION := 0.29.0
LOCAL_SWITCH := $(CURDIR)

.PHONY: setup deps build test property-test lint check format workflow-lint ci

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

PROPERTY_TEST_SEED ?= 20260729

property-test:
	PROPERTY_TEST_SEED=$(PROPERTY_TEST_SEED) $(DUNE) build @property-test

lint:
	$(DUNE) build @opam @fmt @lint @all
	$(OPAM) lint paengi.opam

check: lint test

format:
	$(DUNE) fmt

workflow-lint:
	actionlint .github/workflows/ci.yml

ci: check workflow-lint
