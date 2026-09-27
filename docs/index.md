---
title: panblack---black-like formatter for pandoc users
---

# Introduction

Kind of like black, an opinionated formatter powered by pandoc, for markdown and Jupyter notebooks.

panblack 1.0 is a rewrite in Haskell that bundles pandoc, in progress; see the [design](design.md).
The Python 0.x is in the history; its last release is [`v0.2.0`](https://github.com/ickc/panblack/tree/v0.2.0).

# Key idea

Pandoc as a formatter is not a novel concept.
However, pandoc is not designed to be a formatter.
Pandoc has many readers & writers that can
convert to and from different formats to its internal AST (abstract syntax tree.)

For example, for markdown format,
converting from markdown to markdown via pandoc is lossy,
because behind the scene pandoc actually
converts from markdown to native AST first,
and then convert from this AST
(that doesn't capture all the source information)
to markdown.

As a formatter,
you want it to have some kind of assurance that information is not lost.
One could check the AST is "idempotent" (i.e. the formatted markdown produces the same AST.)

However, often this requirement is still too strong.
The key idea here is that we often are treating the markdown as source,
and it will be converted to some target formats.
Hence, we can relax the requirement (of reproducing the same AST) to
reproducing the same target format.

This is what panblack does---it uses pandoc to format the source
with the requirements that it is idempotent to some specified output formats.

That's also why panblack is designed for pandoc users.
If you use processors other than pandoc,
panblack does not guarantee the formatter is lossless (in the output target formats.)

# Usage

```bash
panblack init > .panblack.yaml   # the recommended settings for markdown
panblack                         # format the files the profiles cover
panblack --check                 # exit 1 if any file would change
panblack --diff                  # print a diff, write nothing
```

See [Config](design.md#config) and [CLI](design.md#cli) for the details.

# Migrating from 0.x

0.x's last release, `v0.2.0`, writes 1.0's `.panblack.yaml` from the `tool.panblack` config in `pyproject.toml`:

```bash
uv tool install git+https://github.com/ickc/panblack@v0.2.0
panblack export-config    # in the directory you run panblack from
```

See [Migration from 0.x](design.md#migration-from-0.x) for what changes.

# Development

```bash
cabal build exe:panblack
cabal test all
```

The docs are a Quarto site in `docs/`, with Quarto from pixi:

```bash
pixi run serve    # preview on port 21576
pixi run build    # render to docs/_site
```
