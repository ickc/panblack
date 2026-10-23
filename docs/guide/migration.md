---
title: Migrating from 0.x
description: Turn a 0.x pyproject.toml config into a 1.0 .panblack.yaml, and what changes.
---

# Export the config

panblack 0.x's last release, `v0.2.0`, writes 1.0's `.panblack.yaml` from the `[["tool.panblack"]]` array in `pyproject.toml` (a literal quoted key, not a nested `tool.panblack`):

```bash
uv tool install git+https://github.com/ickc/panblack@v0.2.0
panblack export-config    # in the directory you run panblack from
```

It writes `.panblack.yaml` (never overwriting an existing one) and prints a note for anything it couldn't translate. 1.0 itself needs no TOML parser.

# Expect one reformat commit

Expect a one-time reformat commit per project. The bundled pandoc version is likely newer than the one 0.x ran (running 0.x with pandoc 3.10.2 already reformatted `-   item` to `- item`), and 0.x wrote files without a final newline, which 1.0 adds back. After that, the output depends only on the panblack version: each release pins one pandoc.

# What changes

| 0.x (`pyproject.toml`) | 1.0 (`.panblack.yaml`) |
|---|---|
| `input_format` | `pandoc.from`. For ipynb profiles, `ipynb.cell-format`: the extensions pandoc's ipynb reader and writer used for cells (`ipynb`'s own, close to GFM, with the profile's modifiers applied), written relative to `markdown`. |
| `require_idempotence_format` | `check`, same meaning. The `"input_format"` entry becomes `source`. |
| (none: 0.x has no normalizations) | `export-config` writes `normalize: []`, so the output stays as 0.x's. Remove it to get the default [normalizations](markdown.md#normalizations). |
| `paths`, `exts` | unchanged |
| `excludes` (regex) | `excludes`, as globs (see [Which files](configuration.md#which-files)). A regex that is a literal name (`.` or `\.` read as a literal dot) translates exactly, since 0.x searched the whole path: `name/` becomes `*name/`, `name` becomes `*name*`. Any other regex is an error. In a git repository, files git ignores are now skipped too. |
| `pandoc_args` | `pandoc:` keys, e.g. `--wrap=preserve` becomes `wrap: preserve`. `--sandbox` is dropped (1.0 always runs pandoc without IO), and `--ipynb-output` with a note (1.0 never changes outputs). Any other argument is an error with a pointer to the docs. |
| `del_jupytext_encoding` | removed, with a note: 1.0 never changes notebook metadata (see [below](#del_jupytext_encoding)) |
| `post_jupytext_sync`, `jupytext_args` | `hooks: [[jupytext, --sync, ...args, '{path}']]`. Black and isort pipes are kept as they are, and the ruff equivalent is printed as a suggestion (see [Code cells](notebooks.md#code-cells-ruff)). |
| `pandoc_path` | removed: pandoc is bundled |
| `-raw_attribute` in `input_format` | kept in `pandoc.from`, but move it to `pandoc.to` (see [Formatting markdown](markdown.md#raw_attribute-in-to-only)): in `from` it lets the guard accept rewriting a raw block as code. |
| `processes`, `mode` | `-j` |
| `toml_path`, `save*` | `--config`, `panblack init` |

Other differences in behaviour:

- **A failed check is an error.** It rejects the file with exit code 2, where 0.x logged a warning and exited 0.
- **Checks render with pandoc's defaults**, not with your pandoc arguments, and compare all metadata (see [What a check renders](philosophy.md#what-a-check-renders)). On pandoc's own markdown, 1.0 and 0.x accept and reject the same files.
- **Notebooks are formatted cell by cell**, rather than through pandoc's ipynb round trip, so metadata, outputs and cell ids are kept byte for byte (see [How a notebook is formatted](notebooks.md#how-a-notebook-is-formatted)).
- **Two profiles may not cover the same file.** 0.x formatted such a file twice, concurrently.

## `del_jupytext_encoding`

0.x deleted jupytext's `encoding` metadata key by default, because pandoc 2.x's ipynb writer escaped metadata strings as markdown on every round trip: `# -*- coding: utf-8 -*-` became `\# -\*- coding: utf-8 -\*-`, then `\\\# ...`, so 0.x's stability check always failed on a notebook with that key (checked with pandoc 2.16.2, current when 0.x added the option in December 2021). jupytext stores the key when it reads a `.py` file with a coding line. 1.0 doesn't pass metadata through pandoc at all, so the option has nothing left to do.

# An example

A 0.x config with three profiles, one of them an ipynb profile with a spelled-out extension list, exports to a config that loads in 1.0, formats, and settles. Its notebook cell format comes out as `markdown+autolink_bare_uris+east_asian_line_breaks-latex_macros-raw_attribute-table_attributes`: the flavour the list was written to mimic, plus `table_attributes`, which pandoc added later.
