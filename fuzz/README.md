# Decoder fuzzing

`fuzz_encoding.exe` receives one arbitrary CBOR byte stream from AFL++ and runs `Paengi_encoding.decode` directly. Rejection is expected. Acceptance must re-encode to the identical stream; an exception or non-canonical acceptance is a fuzzer finding.

Run deterministic seeds:

```sh
make fuzz-smoke
```

Run AFL++ with an instrumented OCaml 5.5.0 switch:

```sh
opam switch create paengi-afl ocaml-variants.5.5.0+options ocaml-option-afl
opam install --switch=paengi-afl . --deps-only --with-test --yes
make fuzz FUZZ_OPAM_SWITCH=paengi-afl FUZZ_SECONDS=60
```

`make fuzz` rejects an existing output path and leaves findings under `_build/fuzz/encoding` by default. The current ordinary project switch is intentionally not accepted as coverage evidence because it lacks AFL instrumentation.
