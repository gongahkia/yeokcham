# Yeokcham quick guide website

Current milestone: V4-009 website documentation. Vertical slice: one original,
static, responsive quick guide for the implemented Yeokcham CLI. It is guided
by the concise, progressive teaching shape of a command-line quick-start, but
does not reproduce another guide's copy, artwork, or Git-centric model.

## Content invariants

- A checkpoint, capsule, workspace, conflict, and release remain distinct
  values throughout the guide.
- Commands must match `docs/CLI.md`; examples may use placeholders but never
  invent a capability.
- Exact bytes remain canonical. Semantic evidence, imported Git provenance, and
  peer publications are never presented as automatic intent or release truth.
- The site has no third-party font, script, image, tracker, or analytics
  dependency. It can be served as ordinary static files.
- The guide makes no claim that a signed/public Yeokcham release has shipped.

## Local preview and verification

Preview with any static server from the repository root, for example:

```sh
python3 -m http.server 4173 --directory site
```

Then open `http://127.0.0.1:4173`. Run the static structural check with:

```sh
make website-test
```

`make ci` includes that check. Visual verification covers a desktop viewport
and a narrow mobile viewport, keyboard navigation, the colour-theme control,
and copy controls.

## GitHub Pages enablement

The source is Pages-compatible, but this change deliberately does not enable
or publish a Pages site. When the maintainer decides to publish, configure
GitHub Pages to serve the `site/` directory from the selected deployment branch
and verify the resulting public URL before adding it to product documentation.

No algebraic type, model invariant, persistent format, or ADR changes in this
slice.
