CARGO ?= cargo

.PHONY: help build check fmt fmt-check lint test doc fixtures ci

help:
	@echo "make build      build all workspace targets"
	@echo "make check      type-check all workspace targets"
	@echo "make fmt        format Rust sources"
	@echo "make fmt-check  verify Rust formatting"
	@echo "make lint       run Clippy with warnings denied"
	@echo "make test       run all tests and doctests"
	@echo "make doc        build documentation with warnings denied"
	@echo "make fixtures   regenerate and verify temporary Git fixtures"
	@echo "make ci         run the complete local CI gate"

build:
	$(CARGO) build --workspace --all-targets --all-features --locked

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

ci: fixtures fmt-check check lint test doc
