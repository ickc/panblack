---
title: panblack 1.0 design---Haskell rewrite
---

Status: draft, on branch `haskell-rewrite`.

# Goals

- Keep the core idea of 0.x: format with pandoc, and trust the result only if it passes a *guard* (see [Philosophy]).
- Ship one static binary that bundles pandoc. The output then depends only on the panblack version, as with black.
- Offer a minimal wasm build for editor format-on-save, where latency matters.
- Use a YAML config that reuses pandoc's defaults-file format, and pull in no new parsing dependencies.
- Give 0.x users an obvious migration path.

# Philosophy

## Why a guard is needed

pandoc is a converter, not a formatter. Its readers don't model the source format faithfully. A reader maps the source into pandoc's own AST, and that AST keeps only what pandoc can express and needs for its writers. Anything else about the source is discarded: syntax choices, and constructs pandoc reads differently from the format's own tools. So a pandoc round trip `markdown → AST → markdown` carries no promise by itself. It is only pandoc's reading of the source, written back out.

panblack adds the promise through a guard: after formatting, **pandoc must produce the same result from the formatted source as from the original** (see [Terminology] for what "same" means). The guarantee is therefore relative to pandoc as the processor. It holds when pandoc is the tool that consumes your sources.

## Limits (by design)

If something other than pandoc consumes your source (JupyterLab, nbconvert, GitHub, MkDocs, ...), panblack promises nothing about how that tool sees the result. The guard runs pandoc, not your processor, so a change pandoc considers equivalent may still change the output elsewhere. This is inherent to the approach. panblack does not try to model other processors or work around their differences from pandoc. If you don't process your sources with pandoc, use a formatter built on the same parser as your processor.

## Delegating to purpose-built tools

Tools like ruff, black, isort and jupytext are different: each one is built to transform its format *while preserving what that format means*. ruff and black parse Python into Python's own AST and check that formatting preserved it. jupytext is built around round-tripping notebooks through text formats. They don't need panblack's guard because they carry their own guarantee. panblack hands such work to them (see [External hooks]) instead of reimplementing or wrapping it.

Non-goals, therefore:

- Formatting code (code blocks, code cells). Delegated to code formatters.
- Guarantees for processors other than pandoc.

# Terminology

0.x used "idempotence" for two different checks. 1.0 separates them:

stability
:   `fmt(fmt(x)) == fmt(x)`. The formatter reaches a fixed point. In 0.x this was `require_idempotence_format = ["input_format"]` (the default).

preservation
:   pandoc treats the original and the formatted source the same. This is the guard. It has two strengths:

    - **AST-equal**: `parse(x) == parse(fmt(x))`. Strict, and cheap because it needs no extra writer.
    - **target-equal**: `render(parse(x), t) == render(parse(fmt(x)), t)` for every configured target `t` (html, latex, ...). This is the relaxed rule from the 0.x README: the source is what you convert *to* those targets, so identical targets are what matters.

A file is written only if it passes preservation. Stability is checked too; a failure is reported as a panblack bug, or as a pandoc bug worth filing upstream.

# Guard algorithm

```
A   = parse(src)
out = write(A)
A'  = parse(out)
if A == A'                          -> preserved (fast path; no target writers run)
elif all(render(A,t) == render(A',t) for t in targets) -> preserved
else                                -> reject, report a diff (AST diff and/or target diff)
# stability: write(A') == out, which is cheap because A' is already parsed
```

Compared with 0.x (1 + 2N pandoc processes, each re-parsing), this parses twice, writes once, and runs the target writers only when the fast path fails.

Open question: AST equality may need a small normalization pass first, for example merging adjacent `Str` or `Space`, or ignoring a table column width drift. Measure the fast-path hit rate on real corpora before deciding.

# Architecture

## `panblack-core` (library)

- Runs purely in `PandocPure`: no IO, deterministic, sandboxed by construction (this replaces `--sandbox`).
- Templates and resources are provided through PureState's in-memory file tree. The markdown template (`$titleblock$` + `$body$`) is embedded.
- API sketch: `format :: Profile -> Text -> Either GuardFailure Formatted`.

## `panblack` (CLI, native static binary)

- Handles file discovery, parallelism (GHC threads, `-j`), IO and hooks.
- Built through `pandoc-forge/pandoc-feedstock` alongside pandoc and pandoc-crossref.

## `panblack-wasm` (editor build)

- Imports concrete readers and writers directly (`Text.Pandoc.Readers.Markdown`, `Text.Pandoc.Writers.Markdown`, optionally `Writers.HTML`), never `Text.Pandoc.App` or the reader/writer registries. `-split-sections` plus linker GC can then drop the unused formats.
- Tiers:
    - `md`: markdown reader and writer, AST-equal guard only.
    - `md+html`: adds the target-equal fallback for html. Watch the cost of skylighting's syntax definitions, which the HTML writer pulls in.
- A guard failure makes the editor skip formatting and show a diagnostic. The guard is never dropped.
- Target use is format on save, so latency needs to be interactive, not per-keystroke.

Spike first: check that a markdown-only pandoc links on the GHC wasm backend, and record its size against the full pandoc-wasm.

# Config

The file is `.panblack.yaml` (the name is still open). It holds a list of profiles, like the 0.x array of tables.

```yaml
- paths: [pages, README.md]
  exts: [md]
  excludes: []
  check: [html]            # target-equal fallbacks; AST-equal is always tried first
  pandoc:                  # inline pandoc defaults file (alternatively: defaults: path/to/file.yaml)
    from: markdown-raw_attribute-latex_macros+east_asian_line_breaks+autolink_bare_uris
    wrap: preserve
    columns: 120
    reference-location: block

- paths: [src]
  exts: [ipynb]
  excludes: ['.ipynb_checkpoints/']
  check: [html]
  pandoc:
    wrap: preserve
    columns: 120
    reference-location: block
    ipynb-output: all
  ipynb:
    cell-format: gfm+tex_math_dollars    # default; see "Markdown flavour for notebooks"
    drop-jupytext-encoding: true
  hooks:
    - [jupytext, --sync, --pipe, 'ruff check --select I --fix-only -', --pipe, 'ruff format -', '{path}']
```

- `pandoc:` is parsed with pandoc's own defaults-file machinery, so any per-document option pandoc understands works here. Options that make no sense for a formatter (`to`, `output-file`, filters, `standalone`) are rejected.
- For ipynb profiles, `pandoc.from` is not used; the cell format comes from `ipynb.cell-format`.
- `excludes`: provisionally gitignore-style globs, and `.gitignore` is respected (see [Open questions]).

# ipynb

## Recommended: format the text side of a jupytext pair

The recommended workflow is to pair each notebook with a text file using jupytext, format the text side with a normal markdown profile, and let `jupytext --sync` carry the changes into the `.ipynb`. jupytext keeps markdown cells verbatim, so panblack never has to write notebook JSON.

Rule: **a pair has exactly one side formatted by panblack.** If both sides are in panblack's paths, two serializers fight: panblack formats `.md`, jupytext regenerates `.md` from `.ipynb` in its own form, and the pair may never converge. panblack should detect paired files (from the jupytext metadata in the notebook) and warn when both sides match a profile.

## Best effort: notebooks without a pair

For `.ipynb` files with no pair, panblack formats the notebook directly, as a best effort.

pandoc's ipynb round trip normalizes more than a formatter should. For example, running 0.x with pandoc 3.10.2 on `tests/ipynb/example_1.ipynb` changed `language_info.codemirror_mode.version` from the number `3` to the string `"3"`. Metadata, nbformat minor version, cell ids and attachments are all at risk in the same way, and 0.x already needed the `del_jupytext_encoding` workaround. 1.0 therefore does **cell-level formatting**:

- Parse the JSON with aeson (already a pandoc dependency). Pass only the markdown cells' `source` through the markdown pipeline and leave every other byte untouched. This reuses the same code path as the wasm/editor build.
- Guard: per cell, plus a whole-notebook check. The whole-notebook check joins all markdown cells (with block separators) into one document, parsed with the *same* cell format, and compares before and after. This catches things that span cells, such as a reference-link definition in another cell, which a per-cell parse would otherwise escape into literal text. panblack implements this check itself instead of going through pandoc's ipynb reader, so the reader and writer always agree on the markdown flavour.

Fallback, if cell-level formatting turns out to be insufficient: a whole-notebook pandoc round trip, as in 0.x.

## Markdown flavour for notebooks

In 0.x the flavour was `input_format`, which served as both reader and writer format. For ipynb this meant spelling out the full pandoc-markdown extension list on top of `ipynb`.

Notebook authors usually write for JupyterLab (marked, roughly GFM, plus `$...$` math), not pandoc markdown. So cell markdown gets its own key, `ipynb.cell-format`, defaulting to `gfm+tex_math_dollars`, the pandoc flavour closest to how notebooks are written. Users who process notebooks with pandoc (for example with pannb) can set it to a pandoc-markdown variant.

Choosing a flavour does not change what is guaranteed. The guard still runs pandoc, so the [Limits] above apply as they do to any other source.

# External hooks

`hooks:` is a list of argv templates run in the CLI after a file is written successfully (`{path}` is substituted). A missing executable gives a clear error and a non-zero exit. There are no hooks in the wasm build. `--check` and `--diff` report panblack's own changes only, and don't run hooks.

Hooks are how panblack delegates to the purpose-built tools described in [Delegating to purpose-built tools]. panblack's guard doesn't apply to hooks because they don't need it: the tools carry their own guarantee. It also couldn't apply: a code formatter intends to change code text, which any target-equal check (html renders code blocks) would reject.

Hooks run in order after the write, so `jupytext --sync` sees the freshly written file as the newest one and syncs in the right direction.

## Code formatting: ruff

The recommended code formatter is ruff, replacing black and isort:

```yaml
hooks:
  - [jupytext, --sync, --pipe, 'ruff check --select I --fix-only -', --pipe, 'ruff format -', '{path}']
```

This was verified with jupytext 1.19.5 and ruff: jupytext pipes each notebook through ruff as a py:percent script over stdin. Don't use jupytext's `{}` placeholder with ruff's `-` stdin argument: jupytext then passes a temp file and ruff waits on stdin forever.

Differences from the 0.x black + isort setup:

- ruff's import sorting has no equivalent of isort's `--float-to-top`. Imports are sorted within each cell but not moved into the first cell. Users who want that keep isort in the hook.
- For a notebook with no pair, ruff can format `.ipynb` directly, without jupytext: `[ruff, format, '{path}']`.

Since hooks are plain commands, black and isort (or anything else) stay possible; `panblack init` emits the ruff version.

An alternative is to leave all of this to pre-commit (`panblack` → `jupytext --sync` → `ruff`) and have no hooks. That's simpler, but profiles then no longer describe the whole workflow.

# CLI

```
panblack [PATH...]          # format in place using .panblack.yaml profiles
  --check                   # exit 1 if any file would change
  --diff                    # print a unified diff, write nothing
  --config FILE
  -j N
panblack init               # print a starter .panblack.yaml
panblack --version          # includes the bundled pandoc version
```

Exit codes: 0 means OK. 1 means `--check` found changes. 2 means a guard failure (preservation or stability). 3 means an error in usage, config or IO. A guard failure is never downgraded to a warning (0.x logged it and exited 0).

# Versioning

- Each panblack release pins one exact pandoc version.
- panblack has its own version number, following the Haskell PVP (see [Publishing]): `A.B.C`, where `A.B` is the major version.
- A pandoc bump means a major (`A.B`) release, with "style changes" in the changelog. `C` releases never change output.
- Breaking config changes bump `A`.
- The bundled pandoc version is shown everywhere a user looks for it, but is not part of the version number: `panblack --version` (`panblack 1.0.0 (pandoc 3.10.2)`), the changelog entry, and the GitHub release notes.

Why the pandoc version is not in the version number (for example `3.10.2-1.0`):

- Hackage versions are dot-separated integers only. A `-` suffix is not a valid version, and PVP gives no way to mark part of the version as someone else's.
- Putting pandoc's version first (`3.10.2.1.0`) would make pandoc's `3.10` panblack's PVP major version, so a panblack-only breaking change could not be expressed as a major bump.
- The Haskell norm for tools built on pandoc is an independent version with the pandoc version in the release notes, as pandoc-crossref does.
- conda-forge also expects the package version to be the upstream project's own version; packaging rebuilds use the build number instead.

Why pinning matters: 0.x uses whatever pandoc is on PATH. Running it with pandoc 3.10.2 reformatted this repo's `CHANGELOG.md` from `-   item` to `- item`, a style change caused only by the pandoc version.

# Migration from 0.x

panblack 0.x was never published to PyPI or conda-forge; users install it from the git repository. So the "final Python release" is a git tag, `v0.2.0`, installable with `uv tool install git+https://github.com/ickc/panblack@v0.2.0`. It adds `panblack export-config`, which reads the `[["tool.panblack"]]` array from `pyproject.toml` (note: that is a literal quoted key, not nested `tool.panblack`) and writes `.panblack.yaml`. It also prints a deprecation notice pointing to 1.0. This way the Haskell binary never needs a TOML parser.

| 0.x (`pyproject.toml`) | 1.0 (`.panblack.yaml`) |
|---|---|
| `input_format` | `pandoc.from`; for ipynb profiles, `ipynb.cell-format` (with the `ipynb` prefix removed) |
| `require_idempotence_format` | `check`. An `input_format` entry is dropped because stability is always checked. |
| `paths`, `exts` | unchanged |
| `excludes` (regex) | `excludes` (see [Open questions]) |
| `pandoc_args` | `pandoc:` keys, e.g. `--wrap=preserve` → `wrap: preserve`. `--sandbox` is dropped (always on). Unknown args cause an error with a pointer to the docs. |
| `del_jupytext_encoding` | `ipynb.drop-jupytext-encoding` |
| `post_jupytext_sync`, `jupytext_args` | `hooks: [[jupytext, --sync, ...args, '{path}']]`. `export-config` keeps black/isort pipes as they are and prints the ruff equivalent as a suggestion. |
| `pandoc_path` | removed (pandoc is bundled) |
| `processes`, `mode` | `-j` |
| `toml_path`, `save*` | `--config`, `panblack init` |

Expect a one-time reformat commit per project, because the pandoc version changes.

# Plan

0. Get 0.x running locally against a recent pandoc, as a reference *oracle* for parity tests. No release. **Done** (see [Running the 0.x oracle]).
1. Spike: `panblack-core` markdown-only on the GHC wasm backend, plus size and latency numbers. This decides the wasm tiers.
2. Core and CLI for markdown: guard, config, `--check`/`--diff`. Golden tests against the 0.x oracle on real corpora, with both using the same pandoc version.
3. ipynb: pair detection and cell-level formatting, plus hooks.
4. Settle the open questions, then freeze the config schema.
5. Python `v0.2.0` tag: `export-config` and the deprecation notice.
6. panblack 1.0: Hackage (see [Publishing]), feedstock packaging, binaries, pre-commit hook. Migrate the dependent projects.
7. The wasm build and the editor integration.

## Running the 0.x oracle

Works with Python 3.12 and pandoc 3.10.2 with no code changes:

```bash
uv venv .venv && uv pip install -e . pytest tomli jupytext
.venv/bin/python -m pytest -q     # 8 passed
```

Caveat: the integration tests format the repository itself (`paths=[DIR]`) and run `jupytext --sync`. They rewrite tracked files and create `tests/ipynb/example_1.md`. Revert with `git checkout -- . && git clean -n` (review, then `-f`) after running them. The 1.0 tests must run on copies in a temporary directory.

# Publishing

panblack 1.0 is distributed in two ways:

- **Binaries** through the pandoc-forge feedstock and GitHub releases. This is what users install.
- **Source** on Hackage, so `cabal install panblack` works and `panblack-core` can be used as a library. This isn't strictly required for the binaries (the feedstock can build from a GitHub tarball), but it's the convention for Haskell tools.

The name `panblack` is currently free on Hackage.

## One-time setup (approval takes days; start as soon as the repository is public)

1. Register at <https://hackage.haskell.org/users/register-request>. Use an ASCII username; the `FirstnameLastname` form is encouraged.
2. A new account can't upload yet. Ask to join the *uploaders* group, either by getting two existing uploaders to endorse you (the confirmation email explains how) or by emailing <hackage-trustees@haskell.org> with your Hackage username and a link to the package's public repository (<https://github.com/ickc/panblack>). Do this after the repository is public.
3. Create an API token under your account settings on Hackage, and use it for uploads instead of your password.
4. Toolchain: install `ghcup`, then GHC and cabal through it. The feedstock's pinned GHC is what matters for releases; locally, match its version.

## Each release

```bash
cabal check                          # package-description lint; fix all warnings
cabal sdist                          # -> dist-newstyle/sdist/panblack-X.tar.gz
cabal upload --token=... dist-newstyle/sdist/panblack-X.tar.gz            # uploads a *candidate*
# review the candidate page on Hackage (build, docs, metadata)
cabal upload --token=... --publish dist-newstyle/sdist/panblack-X.tar.gz  # publish for real
cabal haddock --haddock-for-hackage
cabal upload --token=... --documentation --publish dist-newstyle/panblack-X-docs.tar.gz
```

Things to know:

- **Published versions are permanent.** You can deprecate a version or edit its `.cabal` metadata (dependency bounds) through a "revision", but you can't delete it. That is why candidates exist; always check one first.
- **Versions follow the PVP, not semver.** A PVP version is `A.B.C`, where `A.B` together is the major version. Breaking changes to `panblack-core`'s API bump `A.B`. Style changes from a pandoc bump are an output change rather than an API change, but give them their own `A.B` bump anyway so the rule "patch never changes output" holds.
- **Dependency bounds.** Hackage expects bounded dependencies (`cabal check` warns otherwise). Pinning pandoc to one exact version (`pandoc ==3.x.y`) is unusual on Hackage, but it is deliberate here and should be explained in the package description.
- The first upload makes you the package's maintainer; other people can only upload if you add them.

# Open questions

Nothing here blocks prototyping. Each question has a provisional choice that the prototype builds on; the prototype's evidence settles it before the config schema is frozen (plan step 4). Only the config-shape questions affect migration.

| Question | Provisional choice | Settled by |
|---|---|---|
| AST normalization before comparing | none; measure fast-path hit rate | golden corpus (step 2) |
| wasm tiers | `md` and `md+html` | spike (step 1) |
| `excludes` regex or globs | gitignore-style globs, `.gitignore` respected | usage on real repos |
| ipynb: cell-level or whole-notebook round trip | cell-level | step 3 |
| Hooks or pre-commit only | hooks | usage |
| Config filename and discovery | `.panblack.yaml`, walk up to the repo root | before freeze |
