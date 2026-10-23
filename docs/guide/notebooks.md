---
title: Formatting notebooks
description: Format the markdown cells of Jupyter notebooks, keep jupytext pairs in step, and format code cells with ruff.
---

# Quick start

Notebook users mostly edit the `.ipynb` in JupyterLab, so the notebook is the source, and a paired text file (if any) is a view of it. The recommended workflow is therefore: panblack formats the notebook's markdown cells, and a hook runs `jupytext --sync`, which writes the text side and formats the code cells with ruff on the way:

```yaml
- paths: [notebooks]
  exts: [ipynb]
  excludes: ['.ipynb_checkpoints/']
  check: [source, html]
  pandoc:
    wrap: preserve
  hooks:
    - [jupytext, --sync, --pipe, 'ruff check --select I --fix-only -', --pipe, 'ruff format -', '{path}']
```

Then run `panblack` as for any other file. A notebook with no pair needs no jupytext: use `hooks: [[ruff, format, '{path}']]`, or no hooks at all.

Pair the notebook in its own metadata (`jupytext --set-formats ipynb,md`), so panblack can see the pairing (see [Pairs](#pairs)). Verified with jupytext 1.19.5 and ruff 0.16.9: it settles on the first run, outputs are kept, and `--check` passes afterwards. panblack never writes the text side, so jupytext's YAML header is never touched.

**One rule: a pair has exactly one side formatted by panblack.** If both sides are in panblack's paths, two serializers fight, and the pair never converges. panblack warns when it formats a notebook whose pair it also formats.

# How a notebook is formatted

**Cell by cell.** panblack formats each markdown cell as a document of its own, and leaves every other byte of the file alone. The reasons:

- **pandoc's ipynb round trip changes more than a formatter should.** Run on a notebook, it rewrites metadata (0.x with pandoc 3.10.2 turned `language_info.codemirror_mode.version` from the number `3` into the string `"3"`), the nbformat minor version, attachments, and cell ids. A notebook without cell ids gets new random ones on every run, so a stability check can never pass on it: 0.x never accepted such a notebook.
- **Each cell is what every consumer reads.** JupyterLab, nbconvert and pandoc's own ipynb reader all render each markdown cell on its own. So the faithful unit for the guard is the cell, not the notebook.
- **One bad cell shouldn't block the rest.** A cell whose checks fail is kept as it was, and the other cells are still formatted.

In detail:

- The JSON is parsed only to find the markdown cells' `source`. Each is formatted, and the new sources are spliced into the original bytes, so everything else is kept: metadata, outputs, code cells, cell ids, number formatting, indentation. Notebook metadata is never changed.
- A source keeps its shape: a string stays a string, and a list of lines stays a list, laid out like the old one. It is written as Jupyter writes JSON, with non-ASCII characters escaped only if the file was all ASCII. A cell's final newline is kept or left out as it was, since Jupyter cells usually have none.
- A file with a rejected cell is reported *partly reformatted*, with exit code 2, so `--check` and pre-commit still flag it. A failure names the cell, `cell 3: html`, counting all cells from 1.

## Notebooks paired with markdown: the whole-notebook check

If a notebook is paired with a markdown format (`md`, `Rmd`, `qmd`, `myst`, ...), its cells are also one document: a markdown reader reads the text side whole. So for such a notebook all markdown cells, formatted or kept, are also joined (separated by a blank line) into one document, which must pass the checks as a whole, or nothing is written. This catches what spans cells in the text side, such as a reference link whose definition is in another cell, or footnotes numbered across the notebook: the writer renumbers each cell's footnotes from 1, so joined they would collide. A failure is reported as `all markdown cells`.

For a notebook without such a pair these are faithful per-cell changes. One consequence: a cell holding only a link reference definition becomes empty, since within the cell the definition is unused.

# Markdown flavour of the cells

Cells are read and written in `ipynb.cell-format`, not `pandoc.from`/`to`; the other `pandoc:` keys apply as usual. So one profile can cover notebooks and markdown files alike.

```yaml
  ipynb:
    cell-format: gfm-tex_math_gfm   # the default
```

Notebook authors usually write for JupyterLab (marked, roughly GFM, plus `$...$` math), not for pandoc markdown, so the default is the pandoc flavour closest to that. `gfm` already reads `$...$` math, but with `tex_math_gfm` it *writes* all math in GitLab's syntax (`` $`x`$ `` and ```` ```math ```` blocks), which JupyterLab doesn't render, hence `-tex_math_gfm`. If you process notebooks with pandoc (for example with pannb), set it to a pandoc markdown variant, with the same reasoning as in [Formatting markdown](markdown.md#formatting-a-source-not-writing-markdown).

Choosing a flavour doesn't change what is guaranteed. The guard still runs pandoc, so the [limits](philosophy.md#limits-by-design) apply here as to any other source: how JupyterLab renders a cell is not something panblack can check.

# Pairs

panblack reads the pairing from each notebook it formats (`jupytext.formats` in its metadata), for two things:

- It warns when the other side of the pair is formatted too. It finds the other side as jupytext's `paired_paths` does (extensions, suffixes such as `.pct.py`, directory and file-name prefixes), except for prefix roots (`notebooks///ipynb`, which mirror a directory tree) and pairings set only in a jupytext config file. Those notebooks just get no warning.
- It decides whether the cells are also one document (see [above](#notebooks-paired-with-markdown-the-whole-notebook-check)).

# Code cells: ruff

panblack doesn't format code (see [Delegating to purpose-built tools](philosophy.md#delegating-to-purpose-built-tools)): a hook does. The recommended code formatter is ruff, in place of black and isort. In the hook above, jupytext pipes each notebook through ruff as a py:percent script over stdin, and outputs are kept. Don't use jupytext's `{}` placeholder with ruff's `-` stdin argument: jupytext then passes a temporary file, and ruff waits on stdin forever.

Differences from a black + isort setup:

- ruff's import sorting has no equivalent of isort's `--float-to-top`. Imports are sorted within each cell, but not moved into the first cell. If you want that, keep isort in the hook.
- Hooks are plain commands, so black and isort (or anything else) remain possible.

The alternative is to leave all of this to pre-commit (`panblack`, then `jupytext`, then `ruff`) and have no hooks. That's simpler, but then the profile no longer describes the whole workflow.

# Alternative: format the text side

If you edit the text side of a pair rather than the notebook, format it with a [markdown profile](markdown.md) instead, with two changes, both found by testing with jupytext 1.19.5:

- The hook must write only the notebook: `[jupytext, --to, ipynb, --update, '{path}']`, which keeps the outputs (add the same `--pipe` arguments for ruff). `jupytext --sync` would also rewrite the text side in jupytext's own style (` ```python ` for pandoc's `` ``` python ``), so panblack and jupytext would rewrite it back and forth on every run, and `--check` would never pass.
- The text side must have no jupytext YAML header. pandoc rewrites YAML metadata in its own form: `format_version: '1.3'` becomes `format_version: 1.3`, a string becomes a float, and jupytext then fails with a `TypeError`. pandoc reads both the same, so the guard can't see this (see [Limits](philosophy.md#limits-by-design)). Set the pairing in `jupytext.toml` instead, with `notebook_metadata_filter = "-all"`.

# On real notebooks

Run on 137 distinct notebooks (tutorials, course material, blog posts) with `check: [source, html]` and `wrap: preserve`, panblack took 0.5 s in all. 61 were reformatted and 63 were already formatted. 11 were partly reformatted, keeping 14 cells, all rightly:

- 9 (copies of one tutorial): display math spanning lines, which pandoc reads differently after formatting.
- 1: `\\(\sigma\\)` in three cells, which the commonmark writer wrote without the parentheses (fixed in pandoc 3.12).
- 1: a fenced block with the info string `text`, which the commonmark writer drops ([upstream issue 8](../developer/design.md#upstream-issues)).

1 was rejected by the whole-notebook check: it is paired with `_pair//md` and numbers its footnotes across cells. 1 file was not JSON. Every notebook that was in Jupyter's own layout before (131 of them) still is afterwards: code cells, outputs and metadata are unchanged, and a second run changes nothing.
