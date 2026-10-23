---
title: Development
description: Build, test and release panblack, and work on these docs.
---

How to work on panblack. Why it is the way it is, with the experiments behind each choice, is in the [design notes](design.md).

# Layout

| Path | What |
|---|---|
| `haskell/src/Panblack/` | the library, `panblack-core`: the guard (`Guard`), markdown profiles (`Markdown`), checks (`Target`), `Normalize`, `Config`, `Discover`, `Notebook`, `Jupytext`, `Cache`, `Diff` |
| `haskell/app/Main.hs` | the CLI, native and `panblack.wasm` |
| `haskell/lite/Main.hs` | `panblack-lite`, the editor build |
| `haskell/test/Spec.hs` | the test suite |
| `haskell/golden/run.sh` | the golden test against 0.x |
| `haskell/experiments/` | the table and stability experiments of the design notes |
| `haskell/wasm/patches/` | pandoc's wasm patches (MIT) |
| `cabal.project`, `cabal.project.wasm` | native and wasm builds; `index-state` pins the Hackage snapshot |
| `pins.env` | the toolchain versions CI builds with |
| `scripts/` | the CI build scripts, and the docs screenshot script |
| `docs/` | this site (Quarto) |

# Build and test

Install GHC and cabal with `ghcup`, at the versions in `pins.env` (GHC 9.12.2, cabal 3.16.1.0). Then, from the repository root:

```bash
cabal build exe:panblack
cabal test all
cabal run panblack -- --version
```

## The golden test

`haskell/golden/run.sh` formats pandoc's own markdown with 1.0 and with the 0.x oracle, and compares the files byte for byte. The corpus is fetched with `cabal get` for the pinned pandoc version: `MANUAL.txt`, the top-level `.md` files, the markdown reader tests and `test/command/*.md`, 1128 files for pandoc 3.12.1. It runs under three settings: the defaults; the defaults with `html`; and `wrap: preserve`, `columns: 120`, `reference-location: block` with `html`.

```bash
haskell/golden/run.sh "$(cabal list-bin exe:panblack)" ~/.local/bin/panblack /tmp/golden
```

The second argument is the 0.x `panblack` (below), and the `pandoc` on `PATH` must be the pinned version, since that is what 0.x runs. It exits nonzero if any file differs; the differing ones are listed in `SETTING/differ.tsv`. Every file is expected to come out byte-identical, except that 0.x drops the final newline.

## The 0.x oracle

0.x is tagged `v0.2.0`. It works with Python 3.12 to 3.14 and pandoc 3.10.2 to 3.12.1 with no code changes. For the golden test, install it on its own:

```bash
uv tool install git+https://github.com/ickc/panblack@v0.2.0   # or a worktree of the tag
```

To run its own tests, in a worktree of `v0.2.0`:

```bash
uv venv .venv && uv pip install -e . pytest tomli jupytext
.venv/bin/python -m pytest -q
```

Caveat: the integration tests format the repository itself and run `jupytext --sync`. They rewrite tracked files and create `tests/ipynb/example_1.md`. Revert with `git checkout -- .` and `git clean -n` (review, then `-f`) afterwards.

# Builds

CI (`.github/workflows/build.yml`, mirroring the pandoc-forge feedstock) builds and runs `cabal test` on every push to `main` and on pull requests: static musl binaries for linux-64 and linux-aarch64, osx-64, osx-arm64 and win-64, plus `panblack.wasm` and `panblack-lite.wasm`. The archives are workflow artifacts. Toolchains are pinned in `pins.env`.

- **Native:** `scripts/build-native.sh OUTDIR` builds, tests, and stages the binary with the licence files. pandoc's data files are embedded (`+embed_data_files` in `cabal.project`), so the binary doesn't look for them in the cabal store it was built in.
- **wasm:** `scripts/build-wasm.sh OUTDIR` installs the GHC wasm toolchain ([ghc-wasm-meta](https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta), at the revision in `pins.env`) unless it is already there, builds both modules with `cabal.project.wasm`, and runs a smoke test that panblack-lite gives the same output as the CLI. It needs native `alex` and `happy` on `PATH`. `cabal.project.wasm` mirrors the `if arch(wasm32)` block of pandoc's own `cabal.project`, with stock Hackage pandoc and five patched dependencies.

# Releasing

Publishing a GitHub release `vX` makes CI attach the archives to it; the tag must match the version in `haskell/panblack.cabal`.

## Versioning

- Each panblack release pins one exact pandoc version.
- Versions follow the Haskell PVP: `A.B.C`, where `A.B` is the major version.
- A pandoc bump is a major (`A.B`) release, with the style changes in the changelog. `C` releases never change output.
- Breaking config changes bump `A`.
- **Before 1.0**, releases are `0.99.x`. They exist to shake out distribution (Hackage, conda-forge, the release binaries) on a version nobody depends on yet, and promise nothing: any of them may change output or config. `0.99` sorts above the Python 0.x (last `0.2.0`), so an upgrade from it is an upgrade. `1.0.0` is declared once a `0.99.x` has gone through every channel without trouble.
- The bundled pandoc version is shown wherever a user looks for it, but is not part of the version number: `panblack --version` (`panblack 1.0.0 (pandoc 3.12.1)`), the changelog entry, and the release notes. Why, in the [design notes](design.md#versioning).

## Hackage: one-time setup

Approval takes days, so start as soon as the repository is public.

1. Register at <https://hackage.haskell.org/users/register-request>. Use an ASCII username; the `FirstnameLastname` form is encouraged.
2. A new account can't upload yet. Ask to join the *uploaders* group, either by getting two existing uploaders to endorse you (the confirmation email explains how) or by emailing <hackage-trustees@haskell.org> with your Hackage username and a link to the repository.
3. Create an API token under your account settings on Hackage, and use it for uploads instead of your password.

## Hackage: each release

```bash
cabal check                          # package-description lint; fix all warnings
cabal sdist                          # -> dist-newstyle/sdist/panblack-X.tar.gz
cabal upload --token=... dist-newstyle/sdist/panblack-X.tar.gz            # uploads a *candidate*
# review the candidate page on Hackage (build, docs, metadata)
cabal upload --token=... --publish dist-newstyle/sdist/panblack-X.tar.gz  # publish for real
cabal haddock --haddock-for-hackage
cabal upload --token=... --documentation --publish dist-newstyle/panblack-X-docs.tar.gz
```

- **Published versions are permanent.** You can deprecate a version or edit its `.cabal` metadata (dependency bounds) through a revision, but you can't delete it. That is why candidates exist; always check one first.
- **Dependency bounds.** Hackage expects bounded dependencies (`cabal check` warns otherwise). Pinning pandoc to one exact version is unusual on Hackage, but it is deliberate here, and the package description explains it.
- The first upload makes you the package's maintainer; other people can only upload if you add them.

# Docs

This site is Quarto, in `docs/`, with Quarto and Graphviz from pixi:

```bash
pixi run preview  # live preview on port 21576, re-rendered on save
pixi run build    # render to docs/_site
pixi run serve    # serve docs/_site as is, on port 21576
pixi run clean    # remove the rendered site and diagrams
```

- **Audiences.** Home is for deciding whether panblack fits. The Guide is for users, one page per job. The developer pages are for working on panblack: this page is how, and the design notes are why, with the evidence. Put a fact on the page of the reader who needs it, and link to it from elsewhere rather than repeating it.
- **Diagrams** are Graphviz: a `.dot` file in `docs/media/dot/`, rendered to SVG by `pixi run build-media` (which `build` and `preview` run first) with cairo, which draws the labels as outlines in TeX Gyre Schola, so readers need no font. The SVGs are not committed. On the dark theme they get a white backdrop (`custom.scss`).
- **Checking a visual change:** `scripts/screenshot.sh PAGE OUT.png` shoots a rendered page in a headless browser (installed once with `quarto install chrome-headless-shell`). `SCREENSHOT_THEME=dark` shoots the dark theme, and `SCREENSHOT_SECTION=ID` a copy of the page with only that section.
- The site is published to GitHub Pages from `main` by `.github/workflows/docs.yml`.
