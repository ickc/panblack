---
title: panblack
subtitle: A black-like formatter for pandoc users
---

panblack is an opinionated formatter for markdown and Jupyter notebooks, in the spirit of [black](https://github.com/psf/black). It formats with pandoc itself, and writes a file only if pandoc converts the formatted file exactly as it converted the original:

![](media/dot/guarantee.svg){fig-alt="Your source x is parsed and rendered to y. The formatted source x′ is parsed and rendered to y′. panblack writes x′ only if y and y′ are equal." width=100%}

pandoc can rewrite markdown into markdown, but it is a converter, not a formatter: its reader keeps only what its own model of a document can hold, so a round trip can lose things. panblack makes it safe by judging the result rather than the round trip. If your markdown becomes html and LaTeX, the formatted markdown must give the same html and the same LaTeX, or panblack leaves the file alone. [Core philosophy](guide/philosophy.md) explains the idea in three pictures.

# Is it for you?

panblack fits if:

- you write pandoc markdown, CommonMark, GFM or Jupyter notebooks, and
- **you convert them with pandoc**, and
- you want one consistent style across a project, enforced in CI or pre-commit, without worrying that formatting changes your output.

It isn't for you if something other than pandoc renders your sources (GitHub, MkDocs, JupyterLab, ...): panblack can only promise what pandoc sees. Use a formatter built on the same parser as your renderer instead.

# Quick start

```bash
panblack init > .panblack.yaml   # the recommended settings for markdown
panblack --diff                  # see what would change, write nothing
panblack                         # format the files the config covers
panblack --check                 # in CI: exit 1 if a file would change
```

panblack is one static binary with pandoc inside, so its output depends only on the panblack version. Binaries for Linux, macOS, Windows and WASI are attached to each [GitHub release](https://github.com/ickc/panblack/releases); 1.0 is not released yet, so for now build it from source (see [Development](developer/development.md)). The Python 0.x's last release is [`v0.2.0`](https://github.com/ickc/panblack/tree/v0.2.0).

# Where next

- [Core philosophy](guide/philosophy.md): what panblack guarantees, and why that makes pandoc usable as a formatter.
- [Formatting markdown](guide/markdown.md): the recommended settings for pandoc markdown, CommonMark and GFM, and what each is for.
- [Formatting notebooks](guide/notebooks.md): markdown cells, jupytext pairs, and code cells with ruff.
- [Configuration and CLI](guide/configuration.md): the config file, the command line, the cache, and the wasm builds.
- [Migrating from 0.x](guide/migration.md): from `pyproject.toml` to `.panblack.yaml`.
- For working on panblack itself: [Development](developer/development.md) and the [design notes](developer/design.md).
