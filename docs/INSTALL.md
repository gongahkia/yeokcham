# Installation and support

## Availability

Yeokcham V1 is experimental. GitHub has a
[1.0.0 source release](https://github.com/gongahkia/yeokcham/releases/tag/1.0.0),
but that tag is lightweight and the release has no attached binary assets as
of the October 2026 repository review. Current `main` is later development
source and its executable identifies itself as an unreleased source build.
There is no compatibility promise or opam publication. Pin the exact commit
you evaluate. A successful main-branch development-client workflow may expose a
short-lived signed CI artifact for a Linux tester; it is neither a public
release nor a package-manager publication. Verify it using
[development-artifact guidance](DEVELOPMENT_ARTIFACTS.md). Do not treat a
source checkout or CI artifact as a signed stable release. The separate
[source-release verification](RELEASING.md) requires an annotated signed tag,
archive digest, and independently trusted public fingerprint; the existing
lightweight `1.0.0` tag does not satisfy that procedure.

Before building, install Git, make, opam, a C development toolchain,
`pkg-config`, and the zstd development headers/library using your platform's
package manager or development tools. The setup below then initializes opam
and installs the declared OCaml dependencies.

The repository currently declares OCaml 5.5.0 and Dune 3.23 or newer. Its
Makefile is the source-build entrypoint:

```sh
git clone https://github.com/gongahkia/yeokcham.git
cd yeokcham
make setup
make build
./_build/default/bin/yeokcham_v1.exe --version
./_build/default/bin/yeokcham_v1.exe --help
```

`make setup` initialises opam without shell setup, creates a local switch at
the checkout when needed, and installs the project test dependencies and
formatter. It changes that checkout's development environment. The executable
above is the source-build command; a future release may provide a different
installation path.

To avoid repeatedly spelling the build path during an evaluation, set a shell
variable for the current shell:

```sh
YEOKCHAM="$PWD/_build/default/bin/yeokcham_v1.exe"
"$YEOKCHAM" --help
```

Run the [local recovery tutorial](GETTING_STARTED.md) next. Run the broader
developer checks only if you are evaluating or changing the source. These
also need Python 3, Ruby, GnuPG, OpenSSL, curl, socat, Bash, Zsh, and Fish.
The [CI workflow](../.github/workflows/ci.yml) records the Linux/macOS test-tool
setup, including a disposable SoftHSM token for PKCS#11 coverage. Docker and
Buildx are needed for the separate container and package smoke targets.

```sh
make ci
```

## Platform and custody boundary

The native signer used by `init` and ordinary signed operations is platform
specific. Its private key is outside `.yeokcham` and V1 history.

| Environment | Native signing | Optional capture | Scope |
| --- | --- | --- | --- |
| Linux | Secret Service | foreground `watch`; Linux-only `daemon` | Supported implementation path; Secret Service must be available to the logged-in session. |
| macOS | Keychain | foreground `watch` | `daemon` is deliberately unavailable. |
| Other platforms | unavailable | `watch` unavailable | Native V1 signing is unavailable. |
| WSL | unsupported | unsupported | Not planned. |

The Linux signer invokes `/usr/bin/secret-tool` and `/usr/bin/busctl`; both
must be installed in addition to a running Secret Service with an unlocked
default collection in the user's session. A successful source build alone
does not establish that this runtime custody environment is available.

An existing device may instead be explicitly attached to one `ssh-ed25519`
key in `SSH_AUTH_SOCK`, or use an Ed25519 PKCS#11 token. Those are local custody
choices, not authority changes; read `yeokcham help device attach`,
`yeokcham help device custody`, and the custody boundary in
[Architecture](ARCHITECTURE.md) before relying on either.

`watch` and the Linux `daemon` are advisory ways to request the ordinary exact
`save` path. They never infer an operation or publish intent. Start with
explicit `save` while evaluating the tool.

## What installation does not provide

A source build does not create an account, relay, team, administrator quorum,
or clone of another repository. A second replica must be explicitly enrolled
and joined from an offline package or explicitly bootstrapped from a named,
verified relay basis. Relay use requires an operator-managed HTTPS reverse
proxy and repository-scoped access credential. Git import/export, generic
clone, and automatic remote discovery are not V1 features.

## First-run checks

`--version` should identify an unreleased V1 source build and `--help` should
list only implemented commands. Before `init`, use a disposable empty directory
and make sure the platform signer is usable. `init` deliberately creates local
device custody and prints a 12-word public root-verification phrase plus a
24-word recovery mnemonic. The phrase is for independent comparison during a
join; the mnemonic decrypts recovery material and must be recorded offline.
Neither is a username or password.

If the command cannot access the native signer, do not work around that by
copying private material into `.yeokcham`. See [Troubleshooting](TROUBLESHOOTING.md).
