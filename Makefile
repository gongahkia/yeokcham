SHELL := /bin/sh
OPAM ?= opam
DUNE := $(OPAM) exec -- dune
OCAML_VERSION := 5.5.0
OCAMLFORMAT_VERSION := 0.29.0
LOCAL_SWITCH := $(CURDIR)
RELEASE_REPOSITORY ?= .

.PHONY: setup deps build test lint format ci workflow-security-test workflow-ci-test evidence-fixture-test evidence-workspace-benchmark-test evidence-workspace-summary-test linux-watch-test relay-container-test development-artifact-test development-build-record-test release-verify release-verify-test

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

linux-watch-test:
	test "$$(uname)" = Linux
	$(DUNE) exec test/test_v4_watch.exe

relay-container-test: build
	sh test/test_relay_container.sh

development-artifact-test: build
	sh test/test_development_artifacts.sh

development-build-record-test: build
	sh test/test_development_build_record.sh

lint:
	$(DUNE) build @fmt @lint @all
	$(OPAM) lint yeokcham.opam

format:
	$(DUNE) fmt

workflow-security-test:
	sh test/test_workflow_security.sh

workflow-ci-test:
	sh test/test_workflow_ci.sh

evidence-fixture-test: build
	sh test/test_evidence_fixture.sh

evidence-workspace-benchmark-test: build
	sh test/test_evidence_workspace_benchmark.sh

evidence-workspace-summary-test:
	sh test/test_evidence_workspace_summary.sh

ci: lint test workflow-security-test workflow-ci-test evidence-fixture-test evidence-workspace-benchmark-test evidence-workspace-summary-test

release-verify:
	tools/verify-v4-source-release.sh --repo "$(RELEASE_REPOSITORY)" --tag "$(RELEASE_TAG)" --commit "$(RELEASE_COMMIT)" --fingerprint "$(RELEASE_FINGERPRINT)" --archive "$(RELEASE_ARCHIVE)" --sha256 "$(RELEASE_SHA256)"

release-verify-test:
	sh test/test_release_verify.sh tools/verify-v4-source-release.sh
