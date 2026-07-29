# Decoder robustness testing

`fuzz_encoding.exe` receives one generated CBOR byte stream from the instrumented runner and runs `Paengi_encoding.decode` directly. Rejection is expected. Acceptance must re-encode to the identical stream; an exception or non-canonical acceptance is a test finding.

Run deterministic seeds:

```sh
make fuzz-smoke
```

Run instrumented path exploration with an OCaml 5.5.0 AFL switch:

```sh
opam switch create paengi-afl ocaml-variants.5.5.0+options ocaml-option-afl
opam install --switch=paengi-afl . --deps-only --with-test --yes
make fuzz FUZZ_OPAM_SWITCH=paengi-afl FUZZ_SECONDS=60
```

`make fuzz` rejects an existing output path and leaves results under `_build/fuzz/encoding` by default. The current ordinary project switch is intentionally not accepted as path-exploration evidence because it lacks instrumentation. On macOS the target permits the system crash reporter; delayed signal reporting may reduce finding accuracy during this bounded run.
