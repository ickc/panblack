---
title: Formatting markdown
description: Format pandoc markdown, CommonMark or GFM sources with the recommended settings, and what each setting is for.
---

# Quick start

```bash
panblack init > .panblack.yaml   # the recommended settings for pandoc markdown
panblack --diff                  # see what would change, write nothing
panblack                         # format every file the config covers
panblack --check                 # in CI: exit 1 if a file would change
```

`panblack init` writes one profile:

```yaml
- paths: [.]
  exts: [md, markdown]
  excludes: [.git/]
  check: [source, html]
  pandoc:
    from: markdown-simple_tables-multiline_tables-smart-latex_macros
    to: markdown-simple_tables-multiline_tables-smart-latex_macros-raw_attribute
    wrap: preserve
    columns: 72
```

`check: [source, html]` means a file is written only if a second run would change nothing and its html is unchanged (see [Core philosophy](philosophy.md#several-targets-at-once)). Add the other formats you produce, e.g. `check: [source, html, latex]`. The rest of this page explains the `pandoc:` settings.

# Formatting a source, not writing markdown

pandoc has one markdown writer, and it is built to produce markdown as an *output*: the last step of a conversion from some other format. It doesn't distinguish that from formatting a markdown *source*, where what you typed should be kept as typed. The recommended settings turn off what only makes sense for output.

The flavour itself (`markdown`, plus extensions) must match how you run pandoc, since it decides what the source means. The exceptions below are each chosen so that formatting without them keeps your text as typed, and your own pandoc run, with them on, reads the result as it read the original.

## No `smart`

`smart` is typography: it turns `"quotes"` into curly quotes, `--` into dashes, and puts a non-breaking space after abbreviations. That is a rendering decision, for production, not something to bake into the source. Keep `smart` in your own pandoc runs, and format without it.

With `smart` on while formatting, the writer rewrites what you typed: curly quotes and apostrophes you typed become straight ones, and an invisible non-breaking space (U+00A0) is written after abbreviations such as `p.` and `Mr.` ([upstream issue 5](../developer/design.md#upstream-issues)). Without it, the text is kept exactly as typed. On the test corpus, every file accepted without `smart` also renders the same html when read *with* `smart`.

## No `latex_macros`

With it, the reader expands macros defined in the source, and the writer writes the expansion in place: after `\newcommand{\R}{\mathbb{R}}`, `$x \in \R$` becomes `$x \in \mathbb{R}$`. The html is the same, so the guard would accept it, but your macro is gone. Expanding macros is a rendering step. It has to be off when reading too, since that is where macros are expanded. Your own pandoc run with `latex_macros` is unaffected: the definitions and the math are kept as typed, so pandoc expands them the same way.

## `raw_attribute` in `to` only

Without it, the writer writes inline HTML and TeX as you typed them. With it, as `` `<kbd>`{=html}Ctrl`</kbd>`{=html} `` and `` `\cite{knuth}`{=tex} ``, which pandoc reads the same but which is harder to read, and which other renderers (GitHub, JupyterLab, editors) show literally. Raw content for formats markdown has no other syntax for, such as `{=typst}`, is written by panblack itself and kept either way. If you also use `{=html}` or `{=latex}`, see [Advanced: raw content](#raw-content).

`raw_attribute` must stay on in `from`, as in your own pandoc runs. Turning it off there looks like a way to keep the attribute form exactly as typed, but the reader then no longer knows the syntax at all: a ```` ```{=latex} ```` fence isn't a valid fence any more, so it reads as inline code, and the writer writes it back on one line as `` `{=latex} \begin{flushright}` ``. The guard reads both sides the same wrong way, so it accepts this, and your own pandoc run then shows that line as literal code. This is why `from` must match how you run pandoc.

## Only grid and pipe tables

`-simple_tables-multiline_tables`, in both `from` and `to`. pandoc's table writer chooses a syntax from the column widths in the AST, and simple and multiline tables are where that round trip is least stable (see [Tables](#tables)). Grid and pipe tables are also what people mostly use. Because this is in `from` as well, simple and multiline tables in your source aren't read as tables at all (see [Known limitations](#known-limitations)): convert them first, and use the same `from` in your own pandoc runs.

## `wrap: preserve`

`preserve` keeps your line breaks, so a formatted file differs from the original only where the writer changes syntax. `auto` reflows every paragraph to `columns`, which rewrites every paragraph of an existing file, and can loop forever: a reflowed line starting with `71.` would read as a list item, so the writer escapes it (`71\.`), the escape moves the line break, and on the next run it isn't escaped. Any prose can hit it, which is exactly the "save and it keeps changing" case the `source` check rejects. `none` puts each paragraph on one line.

`columns` (72, pandoc's default) is still used with `preserve`: it is the width tables are laid out to.

## What these settings achieve

On pandoc 3.12.1's own markdown (1128 files), the recommended settings with the default [normalizations](#normalizations) accept 887 files, against 694 without normalizations. The [design notes](../developer/design.md#recommended-defaults-the-evidence) have the runs behind each choice.

# CommonMark and GFM

The same reasoning applies to `commonmark`, `commonmark_x` and `gfm`, with fewer knobs. The CommonMark family has only pipe tables, so the table settings don't apply, and its writer has none of pandoc markdown's table choices to make. The extensions that matter by default:

| Flavour | `smart` | `raw_attribute` | other |
|---|---|---|---|
| `commonmark` | off | off | |
| `commonmark_x` | **on** | **on** | |
| `gfm` | off | off | `tex_math_gfm`: the writer writes math as `` $`x`$ `` |

So for `commonmark_x`, turn off `smart` as above, and `raw_attribute` in `to`, for the [same reason](#raw_attribute-in-to-only). CommonMark has no native TeX, so all raw content but HTML is written in the attribute form; and since its HTML blocks end at a blank line, which the writer puts after them, native HTML reads back intact, so the default `raw: native` keeps `{=html}` blocks working too (written as plain HTML).

```yaml
- paths: [.]
  check: [source, html]
  pandoc:
    from: commonmark_x-smart
    to: commonmark_x-smart-raw_attribute
    wrap: preserve
```

For `gfm`, keep `$x$` math as typed with `-tex_math_gfm` in `to`:

```yaml
- paths: [.]
  check: [source, html]
  pandoc:
    from: gfm
    to: gfm-tex_math_gfm
    wrap: preserve
```

The commonmark writer has its own losses: it drops the info string `text` from a fenced block ([upstream issue 8](../developer/design.md#upstream-issues)), which the html check catches.

# Options

`pandoc:` is an inline [pandoc defaults file](https://pandoc.org/MANUAL.html#defaults-files), restricted to the options that make sense for a formatter. Anything else (`output-file`, `filters`, `standalone`, ...) is an error. `to` defaults to `from`, and may differ from it only in extensions.

## Style: how the same document is written

These only change how the writer spells the AST. They are the formatter's knobs, and don't affect what the guard accepts.

| pandoc option | Effect |
|---|---|
| `to` (extensions only) | Which syntax the writer may use: table syntaxes, `four_space_rule` (list indentation), `fenced_code_blocks`/`backtick_code_blocks`, `space_in_atx_header`, ... Same flavour as `from`. |
| `wrap` | `auto` reflows paragraphs, `preserve` keeps source line breaks, `none` puts each paragraph on one line |
| `columns` | line length for `wrap: auto`, and table layout in every wrap mode |
| `markdown-headings` | `atx` (`#`, the default) or `setext` (underlined) |
| `reference-links` | reference-style links instead of inline links |
| `reference-location` | where notes and reference definitions go: `block`, `section` or `document` (the default) |
| `ascii` | write non-ASCII characters as entities |
| `eol` | line endings written: `lf`, `crlf` or `native` (the default) |

## Reading: must match how you run pandoc

These change what the source *means*, so they must be the same as in your own pandoc invocation, or the guarantee is about the wrong reading.

| pandoc option | Effect |
|---|---|
| `from` (+ extensions) | the flavour and syntax recognised |
| `columns` | also a reader option: a pipe table gets relative widths when a line is longer than it, and grid and multiline widths are computed relative to it. pandoc's CLI uses one `--columns` for both, and so does panblack. |
| `tab-stop` | tab expansion when reading (and indentation when writing) |
| `indented-code-classes` | classes given to indented code blocks |
| `abbreviations` | where `smart` puts non-breaking spaces |

## Not allowed

- `strip-comments`: it would delete HTML comments from the source.
- `default-image-extension`: it would rewrite image paths in the source.
- `toc`, `toc-depth`, `number-sections`, `id-prefix`, `variables`, `template`, `standalone`, `html-math-method`, `syntax-definition`: these add or decorate content. The markdown writer only uses them in its template or in raw-HTML fallbacks.
- `output-file`, filters, and everything else that isn't a reader or writer option.

# Tables

Tables are where pandoc as a formatter hurts most. pandoc's table AST stores relative column widths. The reader derives them from the source, from the dash counts, and from scaling when a line is longer than `columns`. The writer then picks a table syntax (simple, multiline, grid, pipe) from the widths and the enabled extensions, and the new source reads back with different widths or alignment. Without help, a pipe table is typically rewritten as a simple table, its alignment becomes explicitly left, and its widths shift again on every run, so both `source` and `html` fail.

The recommended settings deal with this in two steps:

- **Only grid and pipe tables**, as above. Grid tables can express everything (block content, spans, alignment, a foot, headerless tables); pipe tables are the common simple case.
- **Reset table widths** (the `table-widths` normalization, below). Widths can then never cause a mismatch. They are an accident of how many dashes a table happened to have, not something you chose.

With both, every table of the synthetic test set (each syntax, alignment, long lines, markup and block content in cells) passes the html check at every `columns` from 40 to 200, and on the table corpus every document reaches a fixed point after one formatting run. The cost is that your own pandoc run's column widths can change, since a grid table always gets widths when read. The [design notes](../developer/design.md#tables) have the experiments.

# Normalizations

A normalization is applied to the AST right after every read, on the original and on the formatted source alike, so the checks compare normalized documents, and the formatted source is written from a normalized AST. Each one gives up pandoc-relative equality for something that is, in practice, an accident of the source or of the writer: the html of your own pandoc run can change in the stated way, and no other. They apply to notebook cells too.

All are on by default. List the ones you want in a profile's `normalize:` key, or `normalize: []` for none, which gives pandoc-relative equality with no exceptions.

| `normalize:` name | What changes in your own html | Why |
|---|---|---|
| `table-widths` | column widths (`<col style="width: …">`) | Widths come from dash lengths and `columns`, and the writer can't reproduce them. See [Tables](#tables). |
| `table-cell-breaks` | nothing visible (a newline becomes a space in the html source) | With widths reset, the writer may choose a pipe table for a grid table with wrapped cells, and with `wrap: preserve` it writes the line breaks into the pipe row, which gives an invalid table ([upstream issue 1](../developer/design.md#upstream-issues)). The table is laid out again anyway. Code blocks, code spans and math aren't affected, since they don't contain line-break elements. Hard line breaks (`\`) are a different element and are kept. |
| `code-block-blank-lines` | leading and trailing blank lines inside `<pre>` | A code block without attributes is always written as indented code, which can't hold them ([upstream issue 2](../developer/design.md#upstream-issues)). They are usually accidental, e.g. the padding rows of a grid cell falling inside a fence. |
| `div-bare-text` | a `<p>` inside such divs | `<div>text</div>` on one line reads as bare text, and no div syntax the writer has can write that back: both fenced divs and raw `<div>` put the content on its own lines. This is a limitation of the syntax, not a bug. |
| `empty-comments` | an empty comment disappears | The writer inserts `<!-- -->` to separate a list from a following indented code block or list. That would be a new block in the html. The writer puts it back wherever it is needed, so the formatted source still reads correctly. |

# Known limitations

These are cases the recommended settings exclude. The guard may still accept such files, but the result isn't what you'd want:

- **Simple and multiline tables.** With the recommended `from`, they aren't tables at all: the dashed line makes the header row a setext heading, and the rows become paragraphs. The guard can't notice, because it compares under the same reader. Convert them to grid or pipe tables first, and use the same `from` in your own pandoc runs.
- **Example lists** (`(@)`, `(@label)`). The writer writes them as `(1)`, `(2)`, so they become ordinary lists, and the guard rejects the file ([upstream issue 3](../developer/design.md#upstream-issues)). Even with that fixed, labels couldn't survive: the reader replaces each reference `(@label)` with its number, so the label never reaches the AST.
- **Autonumbered `#.` lists.** The writer writes them as `1.`, which changes the list style, so the guard rejects the file ([upstream issue 4](../developer/design.md#upstream-issues)). It can't be turned off by itself: `#.` belongs to `fancy_lists`, which also provides `a)`, `i.` and similar lists.
- **`{=html}` blocks holding part of an element**, such as an opening `<div>`, are rejected with the default `raw: native` in pandoc markdown: see [Advanced: raw content](#raw-content).

# Advanced: raw content {#raw-content}

Most files need nothing here. It matters if you use `{=html}` or `{=latex}` to give each output format its own markup.

pandoc markdown has two ways to write raw HTML or TeX: as you'd type it (`<kbd>`), or with a raw attribute (`` `<kbd>`{=html} ``, or a ```` ```{=html} ```` block). pandoc reads both the same way, so once a file is read, nothing records which one you used, and panblack has to choose when it writes the file back. The `raw:` setting of a profile makes that choice. Take this file:

````markdown
Press <kbd>Ctrl</kbd>.

```{=html}
<div class="note">
```

Text.

```{=html}
</div>
```
````

| `raw:` | What happens |
|---|---|
| `native` (the default) | `<kbd>` is kept. The two blocks are written as plain `<div class="note">` and `</div>`, which the next run reads as a div and writes as `::: note`. The `source` check sees that, so the file is rejected, and left as it was. |
| `attribute` | The blocks are kept. `<kbd>` is rewritten as `` `<kbd>`{=html}Ctrl`</kbd>`{=html} ``. |
| `auto` | Both are kept. |

So:

- **If you never use `{=html}` or `{=latex}`** for raw HTML or TeX, keep `raw: native`, the default. (Raw attributes for formats that have no other syntax, such as `{=typst}`, are fine: they are always kept as typed.)
- **If you never type HTML or TeX directly** (`<kbd>`, `<!-- comments -->`, `\cite{...}`), use `raw: attribute`.
- **If you do both**, use `raw: auto`. It costs time: after writing a file, it reads it back to check that every raw element came back unchanged. The ones that didn't are switched to the attribute form, all at once, and the file is written and read again, until everything comes back. Each round is a whole-file write and read, and files need one or two: no file of the test corpora needed more than two, nor did one with 400 `{=html}` fragments. After 10 rounds panblack stops trying and puts every raw block in the attribute form. On the test corpora `auto` made formatting 25% slower on pandoc's 1128 files and 6% slower on the author's 68 blog posts; the slowest file, pandoc's 1.3 MB changelog read as `commonmark_x`, took 9.6 s instead of 5.7 s. Files without raw HTML or TeX cost nothing extra.

`native` and `auto` also write a few raw elements in the attribute form because they can't be written natively: `{=latex}` elements (native TeX reads as `tex`, so a `latex` element can only have been typed with the attribute, and is kept that way), TeX holding a `\begin{...}` without its `\end{...}` or the reverse (written natively, it would swallow what follows), and, in the CommonMark family, HTML blocks containing a blank line (that writer removes the blank lines).

`raw: pandoc` leaves the choice to pandoc's writer, from the `to` extensions alone, as 0.x did. It exists to compare with 0.x.

`raw:` only applies when `from` reads raw attributes, which `gfm` and `commonmark` don't. The measurements behind these settings are in the [design notes](../developer/design.md#raw-content-the-evidence).
