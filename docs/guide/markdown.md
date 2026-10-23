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

## Raw content {#raw-content}

pandoc markdown has two ways to write raw content: *native*, for the formats markdown knows (inline HTML such as `<kbd>`, and TeX such as `\cite{knuth}`), and the *raw attribute*, `` `...`{=format} `` or a ```` ```{=format} ```` block, for any format. The reader understands both, and the AST doesn't record which one you used. So the writer chooses, from the extensions in `to`:

- a raw **inline**: the raw attribute if `raw_attribute` is on, otherwise native for HTML and TeX, otherwise nothing;
- a raw **block**: native for HTML and TeX if `raw_html` / `raw_tex` are on, otherwise the raw attribute if that is on, otherwise nothing.

Two kinds of source are affected differently. The first types HTML and TeX natively, and perhaps uses a raw attribute for a format markdown has no syntax for:

````markdown
Press <kbd>Ctrl</kbd> to cite \cite{knuth}.

Inline `#emph[x]`{=typst} here.

```{=typst}
#set page(width: 10cm)
```
````

The second selects content per output format, because the same effect needs different markup in each. Right-aligning a line is an example: there is no markdown for it, so you write it once for html and once for latex, and each output keeps its own:

````markdown
```{=html}
<div style="text-align: right">
```

```{=latex}
\begin{flushright}
```

Signed, the author.

```{=latex}
\end{flushright}
```

```{=html}
</div>
```

Inline: `<span style="float: right">`{=html}`\hfill{}`{=latex}right`</span>`{=html}.
````

**Without `raw_attribute` in `to`** (the recommended setting), the first source keeps its HTML and TeX as typed. But the writer has no way to write the typst, and drops it:

```markdown
Press <kbd>Ctrl</kbd> to cite \cite{knuth}.

Inline here.
```

and the file is **accepted**: the raw typst renders as nothing in html, so the `html` check can't see it go, and the result is stable. Only a check that renders typst sees it (`check: [source, html, typst]` rejects the file instead). The second source is written natively, `<div style="text-align: right">` directly followed by `\begin{flushright}`. Read back, that is a different document: the TeX environment now swallows "Signed, the author.", which disappears from the html. (The inline selectors are written natively too, as `<span style="float: right">\hfill{}right</span>`, which reads back as a span, so even the latex changes.) The checks see the html lose the text, so the file is **rejected**, left as it was. Safe, but it is never formatted.

**With `raw_attribute` in `to`** (pandoc's default), the typst is kept, and native inline HTML and TeX are rewritten in the attribute form:

```markdown
Press `<kbd>`{=html}Ctrl`</kbd>`{=html} to cite `\cite{knuth}`{=tex}.
```

pandoc renders this the same, but it reads worse, and other renderers (GitHub, JupyterLab, editors) show the `{=html}` literally. On pandoc's own `changelog.md` this happens in 5 places, and it gets `INSTALL.md` rejected, because a multi-line `<a ...>` tag is wrapped and reads back differently. Raw *blocks* of HTML and TeX are still written natively, so the second source is rejected as before.

**With `-raw_html-raw_tex` in `to`** (and `raw_attribute` left on), the writer can only use the attribute form, so every raw element is written explicitly, blocks included. The second source survives and is accepted (pandoc's writer only drops the blank lines between consecutive raw blocks). Why raw blocks are treated differently from raw inlines is [upstream issue 10](../developer/design.md#upstream-issues). The cost is the first source: everything native is rewritten, an HTML comment `<!-- ... -->` becomes a ```` ```{=html} ```` block, and so on. Only `to` changes, so pandoc still reads native HTML and TeX as before, in panblack and in your own runs.

| `to` | native HTML and TeX you typed | per-format raw blocks | raw content for other formats |
|---|---|---|---|
| `-raw_attribute` (recommended) | kept as typed | file rejected | **dropped, unless a check renders that format** |
| pandoc's default | inline rewritten as `` `...`{=html} `` | file rejected | kept |
| `-raw_html-raw_tex` | all rewritten in the attribute form | kept | kept |

"Rejected" never damages a file: it is left as it was, and panblack exits with code 2. On the test corpora, `-raw_html-raw_tex` accepts 3 more blog posts (46 of 68) and 5 fewer of pandoc's files (882 of 1128) than the recommended setting, and rewrites native raw content in 5 of the accepted posts and 1 of pandoc's files. No accepted file loses raw content under any of the three.

So: if you type HTML and TeX natively, keep the recommendation, and list a check for any other format you use raw. If you select content per output format, use `-raw_html-raw_tex`. The unit tests track the second source under all three settings.

`raw_attribute` must stay on in `from`, as in your own pandoc runs. Turning it off there looks like a way to keep the attribute form exactly as typed, but the reader then no longer knows the syntax at all: a ```` ```{=latex} ```` fence isn't a valid fence any more, so it reads as inline code, and the writer writes it back on one line as `` `{=latex} \begin{flushright}` ``. The guard reads both sides the same wrong way, so it accepts this, and your own pandoc run then shows that line as literal code. It is the one setting here that damages files silently, which is why `from` must match how you run pandoc.

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

So for `commonmark_x`, turn off `smart` as above, and `raw_attribute` in `to` (with the same [trade-off](#raw-content), stronger here: commonmark has no native TeX, so raw content for *any* format but HTML, `{=tex}` included, can only be written with it):

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
- **Raw content for formats other than HTML and TeX**, without `raw_attribute` in `to`, is dropped unless a check renders that format, and **raw HTML and TeX blocks selected per output format** are rejected: see [Raw content](#raw-content).
