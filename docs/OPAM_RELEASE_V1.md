# opam source release v1

Yeokcham distributes source only through opam. The installed package must place
the `yeokcham` executable in the opam switch; it does not distribute a native
binary, installer, cache, or custom repository.

## Preflight

The local package preflight builds Dune's package-scoped install target and
asserts that the installed executable exists:

```sh
make stability-opam-package-test
opam install . --with-test
yeokcham --help
```

The first command is a deterministic checkout check. The second and third are
the source-install smoke test to repeat in a fresh switch after the package is
available from the official repository.

## Publication boundary

Only after #242 records all required field trials and #243 records a signed tag
and source archive checksum may the maintainer use the normal upstream process:

```sh
opam publish
```

`opam-publish` validates package metadata, adds the archive URL/checksum, and
opens a reviewable pull request to `ocaml/opam-repository`; it requires the
maintainer's GitHub/SSH authority. The resulting PR URL and accepted package
version are release evidence, not facts this repository can manufacture.

The intended command comes from the official [opam packaging guide](https://opam.ocaml.org/doc/Packaging.html).
The current checkout is not an accepted opam release: it has no corresponding
signed release tag, WSL evidence, archive URL/checksum, or upstream review.

No canonical Yeokcham model or persistent storage format changes. No ADR change
is required.
