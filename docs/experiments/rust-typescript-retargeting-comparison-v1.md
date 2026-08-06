# Rust and TypeScript retargeting comparison v1

## Scope

This is a language-separated research report. It preserves the checked
`semantic-retargeting-v1` TypeScript baseline by reference and reports the
independent six-case `yeokcham_rust_fixtures` workload. The workloads have
different languages, datasets, adapters, and capabilities. They are not a
benchmark, a success-rate comparison, or a cross-language generalisation.

## TypeScript baseline preserved

The existing 40-case TypeScript v1 report remains unchanged. Its semantic
strategy records zero false-confident applications, six false negatives, and
zero false applications; its byte-only textual baseline records zero
false-confident applications, one false negative, and zero false applications.
Those values are referenced from `semantic-retargeting-v1`, not recomputed or
combined with Rust data here.

## Rust workload

The Rust dataset has six bounded virtual-source-map fixtures. Five produce the
checked exact result through `yeokcham_textual_patch`; one duplicate declaration
returns a safe structured conflict. Two of the five exact textual cases require
Rust fallback evidence: one macro-heavy map and one parser-damaged map.

Rust semantic retargeting attempts are zero. Consequently this report records
zero Rust false-confident semantic applications by absence of such attempts,
not as a claim that a Rust semantic engine is safe. The two fallback-required
results remain independently byte/text-only; no reported fact identifies a
macro-generated declaration, resolves a move, or authorizes a rewrite.

## Reproduction

```sh
make rust-retargeting-comparison
python3 -m jsonschema \
  --instance docs/experiments/results/rust-typescript-retargeting-comparison-v1.json \
  docs/experiments/schema/rust-typescript-retargeting-comparison-v1.schema.json
```

The JSON result is a versioned documentation artifact. It is not a Yeokcham
object, persistent semantic sidecar, model result, or correctness gate.
