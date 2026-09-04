# Installation and support

## Availability

Yeokcham V4 is experimental. There is no published stable release, opam
publication, support matrix, compatibility promise, or source-release tag to
install. A successful main-branch development-client workflow may expose a
short-lived signed CI artifact for a Linux tester; it is neither a public
release nor a package-manager publication. Verify it using
[development-artifact guidance](DEVELOPMENT_ARTIFACTS.md). Do not treat a
source checkout or CI artifact as a signed stable release. The separate
[source-release procedure](RELEASING.md) applies only when maintainers publish
an actual annotated signed tag, archive digest, and public fingerprint.

The repository currently declares OCaml 5.5.0 and Dune 3.23 or newer. Its
Makefile is the supported source-build boundary:

```sh
git clone https://github.com/gongahkia/yeokcham.git
cd yeokcham
make setup
make build
./_build/default/bin/yeokcham_v4.exe --version
./_build/default/bin/yeokcham_v4.exe --help
```

`make setup` initialises opam without shell setup, creates a local switch at
the checkout when needed, and installs the project test dependencies and
formatter. It changes that checkout's development environment. The executable
above is the source-build command; a future release may provide a different
installation path.

To avoid repeatedly spelling the build path during an evaluation, set a shell
variable for the current shell:

```sh
YEOKCHAM=./_build/default/bin/yeokcham_v4.exe
"$YEOKCHAM" --help
```

Run the [local recovery tutorial](GETTING_STARTED.md) next. Run the broader
developer checks only if you are evaluating or changing the source:

```sh
make ci
```

## Platform and custody boundary

The native signer used by `init` and ordinary signed operations is platform
specific. Its private key is outside `.yeokcham` and V4 history.

| Environment | Native signing | Optional capture | Scope |
| --- | --- | --- | --- |
| Linux | Secret Service | foreground `watch`; Linux-only `daemon` | Supported implementation path; Secret Service must be available to the logged-in session. |
| macOS | Keychain | foreground `watch` | `daemon` is deliberately unavailable. |
| Other platforms | unavailable | `watch` unavailable | Native V4 signing is unavailable. |
| WSL | unsupported | unsupported | Not planned. |

An existing device may instead be explicitly attached to one `ssh-ed25519`
key in `SSH_AUTH_SOCK`, or use an Ed25519 PKCS#11 token. Those are local custody
choices, not authority changes; read the device help and
[ADR-093](adr/093-v4-device-custody-providers.md) before relying on either.

`watch` and the Linux `daemon` are advisory ways to request the ordinary exact
`save` path. They never infer an operation or publish intent. Start with
explicit `save` while evaluating the tool.

## What installation does not provide

A source build does not create an account, relay, team, administrator quorum,
or clone of another repository. A second replica must be explicitly enrolled
and joined from an offline package or explicitly bootstrapped from a named,
verified relay basis. Relay use requires an operator-managed HTTPS reverse
proxy and repository-scoped access credential. Git import/export, generic
clone, and automatic remote discovery are not V4 features.

## First-run checks

`--version` should identify an unreleased V4 source build and `--help` should
list only implemented commands. Before `init`, use a disposable empty directory
and make sure the platform signer is usable. `init` deliberately creates local
device custody and prints a 12-word public root-verification phrase plus a
24-word recovery mnemonic. The phrase is for independent comparison during a
join; the mnemonic decrypts recovery material and must be recorded offline.
Neither is a username or password.

If the command cannot access the native signer, do not work around that by
copying private material into `.yeokcham`. See [Troubleshooting](TROUBLESHOOTING.md).
