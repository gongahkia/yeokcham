# Experiment 099 — V2 transfer wire-core scaled benchmark

- Date: 2026-09-04
- Host: Fedora Linux 43, Linux 7.1.10-100.fc43.x86_64
- CPU: 13th Gen Intel Core i7-1355U (12 logical CPUs reported)
- Memory reported by `free -h`: 15 GiB total, 8.8 GiB used, 340 MiB free
- Network: none; this is a local V2 zstd wire-core measurement, not an HTTPS
  relay throughput test
- Toolchain: project-local OCaml 5.5.0, opam `zstd` 0.4, system curl 8.15.0

## Purpose and command

The V2 relay imposes a 64 MiB maximum raw object size. This experiment measures
that maximum object as 64 independently compressed/decompressed one-MiB ranges,
using deterministic high-entropy bytes. It creates neither a source tree nor a
relay session and deliberately does not claim the ticklist's 5 GiB/100,000-path
representative capacity target.

```sh
opam exec -- dune build bench/v2_transfer_wire_benchmark.exe
/usr/bin/time -f 'elapsed_seconds=%e\nuser_cpu_seconds=%U\nsystem_cpu_seconds=%S\nmax_rss_kib=%M' \
  opam exec -- dune exec bench/v2_transfer_wire_benchmark.exe
```

## Results

| Metric | Result |
| --- | ---: |
| Raw bytes | 67,108,864 (64 MiB) |
| Raw ranges | 64 |
| Independently framed zstd wire bytes | 67,110,976 |
| Resume work avoided after one accepted range | 1,048,576 raw bytes / 1,048,609 wire bytes |
| Wall time | 0.86 s |
| User CPU | 0.73 s |
| System CPU | 0.10 s |
| Maximum RSS | 28,304 KiB |

The run confirms the bounded-frame code can encode and decode the enforced
per-object maximum without allocating the full object at once. It is not
network, relay-disk, multi-object closure, source-scanning, 100,000-path, or
5 GiB evidence. EVIDENCE-001 remains responsible for any capacity claim.
