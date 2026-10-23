---
title: Core philosophy
description: What panblack promises, and why that promise is what makes pandoc usable as a formatter.
---

pandoc can already rewrite markdown into markdown, so a formatter built on it might look trivial. It isn't, because pandoc is a converter, not a formatter. This page shows the one idea that makes it work in three pictures, and then what follows from it. Everything else in this guide (the recommended settings, normalizations, notebooks) is that idea put into practice.

# pandoc: many formats, one AST

pandoc converts between formats through its own abstract syntax tree (AST). A reader *parses* a source format into the AST, and a writer *renders* the AST in a target format, so any reader can be paired with any writer:

![](../media/dot/pandoc.svg){fig-alt="Readers for markdown, commonmark, rst and more parse into the pandoc AST, and writers render it as markdown, html, LaTeX and more." width=75%}

A formatter is one particular pairing: parse markdown, write markdown, $\mathrm{fmt}(x) = \mathrm{write}(\mathrm{parse}(x))$. The catch is that the AST is pandoc's model, not the source's. A reader keeps only what pandoc can express and needs for its writers, and discards the rest: syntax choices, and constructs pandoc reads differently from the format's own tools. Whatever the reader doesn't keep, the writer can't put back. So a pandoc round trip carries no promise by itself: $\mathrm{fmt}(x)$ may differ from $x$ in ways that matter, and may even read back as a different AST.

# The guarantee: converting the formatted source gives the same result

You write in a format X (say markdown) and convert it to a format Y (say html). panblack replaces your source with the formatted one only if converting the formatted source to Y gives what converting the original gives:

$$
X \xrightarrow{\text{AST}} Y \quad = \quad X \xrightarrow{\text{AST}} X \xrightarrow{\text{AST}} Y
$$

The left side is your pandoc run on the original. The right side formats first, then runs the same conversion. Spelled out, with $x$ your source and $x' = \mathrm{fmt}(x)$ the formatted source:

![](../media/dot/guarantee.svg){fig-alt="Top row: x is parsed to an AST and rendered to y. Bottom row: x is parsed to an AST, written as x′, parsed again to AST′ and rendered to y′. y and y′ must be equal." width=100%}

What is compared is $y$, the result you actually use. It is not the AST, and not the source text. $\mathrm{AST}'$ may differ from $\mathrm{AST}$, and $x'$ from $x$ (that is the point of formatting), as long as $y$ doesn't change.

This is what makes pandoc usable as a formatter at all. Making a pandoc round trip `markdown → AST → markdown` exact is a known hard problem: pandoc's own tests find cases that never settle, for example an escape character added on every pass. panblack doesn't try to solve it. It side-steps it by judging the result, not the round trip.

# Several targets at once

A project usually converts its sources to more than one format, so a profile lists several Ys, called its *checks*, and every one must hold:

![](../media/dot/checks.svg){fig-alt="x is parsed to an AST and rendered as html, LaTeX and markdown x′. The formatted x′ is parsed to AST′ and rendered as html′, LaTeX′ and markdown x″. Each pair must be equal: html and html′, LaTeX and LaTeX′, x′ and x″." width=55%}

The checks have names:

check
:   A format to render to, such as `html`, `latex`, or any other pandoc text writer, with extensions if you like (`latex-smart`). It passes when the original and the formatted source render the same, compared with surrounding whitespace stripped. A profile lists its checks in `check:`, and **a file is written only if every listed check passes** (for notebooks, each cell; see [Formatting notebooks](notebooks.md#how-a-notebook-is-formatted)).

stability, the check `source`
:   One of the Ys can be X itself: render the formatted source in its own format, which is formatting it a second time. That is the check named `source`. It passes when $\mathrm{fmt}(\mathrm{fmt}(x)) = \mathrm{fmt}(x)$, i.e. a second run changes nothing, the stability you expect from a formatter. It is the default (`check: [source]`). Like any check it can be left out: with `check: [html]`, a result whose html is unchanged is accepted even if a second run would write it differently.

preservation
:   A check on a target format (html, LaTeX, ...): pandoc renders the original and the formatted source the same. The source is what you convert *to* those targets, so identical targets are what matters.

An empty list accepts any output. A failed check rejects the file: it is left as it was, and panblack exits with code 2 (see [exit codes](configuration.md#exit-codes)), so `--check` and pre-commit flag it.

Choosing the checks is choosing what "the same" means for your project. List the formats you actually produce.

# When the AST doesn't change, and when it does

If the formatted source parses to the same AST as the original, every check passes without being rendered: each check depends on the AST alone, so equal ASTs give equal outputs. In terms of the picture above, if the bottom row reaches the same AST as the top one,

$$
x \xrightarrow{\text{parse}} \mathrm{AST} \xrightarrow{\text{write}} x' \xrightarrow{\text{parse}} \mathrm{AST}' \quad\text{with}\quad \mathrm{AST}' = \mathrm{AST},
$$

then $y' = y$ for every check, and none is rendered. This is the *fast path*. AST equality is enough, but not required: a file whose AST changes is still accepted when every check renders the same.

So which does the work in practice? Measured on two corpora: pandoc 3.12.1's own markdown (`MANUAL.txt`, the top-level `.md` files, the reader tests and `test/command/*.md`: 1128 files, nearly all of which pandoc's writer reformats), and Quarto's documentation (the 552 `.qmd` pages of [quarto-web](https://github.com/quarto-dev/quarto-web) at commit `ecf8316`, read as pandoc markdown), which is written for pandoc through Quarto and was never formatted with pandoc's writer:

| Corpus | Settings | Accepted | AST unchanged | AST changed, checks equal | Rejected |
|---|---|---|---|---|---|
| pandoc | [recommended](markdown.md#quick-start) | 887 | 887 | 0 | 241 |
| pandoc | recommended, but `wrap: auto` | 886 | 850 | 36 | 242 |
| pandoc | pandoc's defaults (`wrap: auto`), `check: [source, html]`, no normalizations | 691 | 658 | 33 | 437 |
| Quarto | recommended | 510 | 507 | 3 | 42 |
| Quarto | recommended, but `wrap: auto` | 510 | 130 | **380** | 42 |

Two things follow.

**The checks are what let a formatter change the AST at all.** With `wrap: auto`, the writer reflows paragraphs: line breaks move, so `SoftBreak` and `Space` trade places in the AST, while the html is identical. On Quarto's pages, 380 of the 510 files accepted needed the html check, and AST equality alone would have accepted 130. Every one of the 33 in the third row is such a reflow. Requiring an unchanged AST would forbid reflowing, and any other style change that the AST happens to record. Defining "the same" by what you produce is what allows them.

**With the recommended settings, the writer nearly always either reproduces the AST or loses something you would see.** `wrap: preserve` keeps line breaks where they are, and the [normalizations](markdown.md#normalizations) state the remaining accidents (table widths, empty comments, ...) explicitly, so every accepted file of pandoc's corpus comes back AST-equal, and all but 3 of Quarto's. Those 3 each hold an `{=html}` inline that `raw: native` writes as plain HTML, which reads back as two raw elements with the same html ([`raw: auto`](markdown.md#raw-content) keeps it as typed). Every rejection, conversely, is an html difference (240 of the 241 on pandoc's corpus): a change in the AST that does show in the output. Asked alone, the `source` check would have accepted all 240, since they are stable. They are stable *and wrong*, which is what the html check is for. On Quarto's pages, all 42 rejections fail the html check.

So the checks carry the guarantee, and the fast path is how it is usually confirmed cheaply. Once a project is formatted, every file is unchanged,

$$
x' = x,
$$

which is the fast path trivially: the checks cost time only when formatting changes what pandoc reads, which is exactly when they are needed. With `wrap: auto` that is the first time each paragraph is reflowed, and it costs only time: on Quarto's pages, the checks take about 2 of the 6.6 seconds of a first run on one core. (Comparing ASTs with soft breaks counted as spaces would skip them, and decides the same on both corpora, but the [design notes](../developer/design.md#guard-algorithm) explain why it isn't worth coupling the guard to wrapping.)

# What a check renders

A check asks one question: does pandoc understand the formatted source the same way as the original, seen through a target format? It is not a rebuild of your own html or LaTeX. So a check renders with pandoc's defaults for its target, independent of the profile's `pandoc:` options, with two exceptions:

- **The template is all of the metadata plus the body** (`$meta-json$` and `$body$`). `meta-json` holds every metadata field, rendered by the target writer, so a change to any field is caught. A standalone template would show only the fields it uses (title, author, date, ...).
- **Line wrapping is off.** Where the target breaks its own lines doesn't change what it means.

Why not render with the profile's options, as 0.x did? Because those are options for *writing markdown*: `wrap`, `columns`, `markdown-headings`, `reference-links`, `reference-location`, `ascii`. Handed to the html writer they either do nothing (`markdown-headings`, `reference-links`) or change how the html is laid out (`columns` and `wrap` its line breaks, `reference-location` where footnotes go, `ascii` its entities). Neither has anything to do with whether pandoc understood the source the same way. Since both sides of a check are rendered alike, such options can only add noise to the comparison, never information.

The two differences from 0.x, in detail:

- 0.x passed its `pandoc_args` to every conversion, its checks included. For markdown profiles it also passed its own markdown template (the title block plus the body) to every target, so its html check compared the body only and could not see a change to metadata. 1.0 compares all of the metadata in every check.
- 0.x rendered with the profile's wrapping, so with `--wrap=preserve` the html kept the source's line breaks. 1.0 renders without wrapping.

The effect is only on what counts as "the same": 1.0 compares what pandoc understood, and doesn't fail because of how a target is configured to look. On pandoc's 1128 markdown files under three settings, 1.0 and 0.x accept and reject exactly the same files.

Extensions of a target can still be set in the check's name, e.g. `check: [source, html, latex-smart]`.

# Normalizations: stated exceptions

A few things pandoc's markdown writer can't write back faithfully are, in practice, accidents of the source or of the writer: column widths that come from how many dashes a table happened to have, or an empty `<!-- -->` comment the writer itself inserts. For each such case panblack has a *normalization*, applied to the AST right after every read, on the original and on the formatted source alike. Each gives up the guarantee above in one stated way: your own pandoc run's html can change in that way and no other. They are listed, with what each changes, in [Formatting markdown](markdown.md#normalizations). All are on by default, and `normalize: []` turns them off for the guarantee with no exceptions.

# Which formats

Nothing above is specific to markdown. The guard needs only a reader and a writer for the source format: parse it, write it back, and compare what the checks render. So in principle panblack can format any format pandoc can both read and write. Plenty of text formats people write by hand have only one of the two. pandoc can *read* a Vimwiki, but has no Vimwiki writer, so it can't write your notes back. It can *write* Texinfo, the format of GNU's manuals, but can't read it, so there is nothing to parse and no AST to compare. (Binary formats such as docx are out for a plainer reason: a formatter rewrites text you edit.)

What panblack supports, and its author tests, is narrower: the markdown family (pandoc markdown, CommonMark, `commonmark_x`, GFM and pandoc's other markdown variants), and Jupyter notebooks, whose markdown cells it formats. The recommended settings in this guide are written for those, and come from runs on real files.

Other text formats pandoc reads and writes, such as reStructuredText (`rst`) or Org, would fit the same design, but panblack doesn't offer them yet: `from: rst` is refused. Adding one is a small change (a reader, a writer and a template), but nobody has tested how faithfully pandoc's rst writer round-trips real documents, and the guard would then reject whatever it doesn't. Expect such a format to need its own recommended settings, and its own list of writer losses, before it is useful.

# Limits (by design)

The guard runs pandoc, so the guarantee is relative to pandoc as the processor. It holds when pandoc is the tool that consumes your sources.

If something other than pandoc consumes your source (JupyterLab, nbconvert, GitHub, MkDocs, ...), panblack promises nothing about how that tool sees the result: a change pandoc considers equivalent may still change the output elsewhere. This is inherent to the approach. panblack doesn't try to model other processors or work around their differences from pandoc. If you don't process your sources with pandoc, use a formatter built on the same parser as your processor.

## Preprocessor syntax {#preprocessor-syntax}

The same applies when a tool processes your source *before* pandoc does. Several frameworks add a template or macro language on top of markdown and expand it first: Quarto and Hugo shortcodes, Liquid in Jekyll, Jinja in MkDocs macros, knitr chunks in R Markdown. panblack implements none of these syntaxes. To pandoc they are plain text, so the writer escapes whatever looks like markdown in them, and since pandoc's own output doesn't change, the guard accepts it. The preprocessor then no longer recognizes what you wrote:

| You wrote | panblack writes |
|---|---|
| `{{< include _part.md >}}` (Quarto, Hugo) | `{{\< include \_part.md \>}}` |
| `{% include _footer.html %}` (Liquid) | `{% include \_footer.html %}` |
| `{% set area = width * height %}` (Jinja) | `{% set area = width \* height %}` |
| `` ```{r} x ``` `` inline (R Markdown) | `` `{r} x` `` |

On Quarto's own documentation, 205 of the 257 pages that use shortcodes are written back with them escaped. Until panblack understands a framework's syntax, leave the files that use it out, with `excludes:` or a profile whose `paths` don't cover them.

Likewise, the guarantee covers the targets you list as checks. Content that none of them renders, such as a raw `{=typst}` block when the checks are `html` and `latex`, is invisible to the guard. panblack writes such content back as you typed it, but no check confirms it (see [raw content](markdown.md#raw-content)).

# Delegating to purpose-built tools

Tools like ruff, black, isort and jupytext are different: each is built to transform its format *while preserving what that format means*. ruff and black parse Python into Python's own AST and check that formatting preserved it. jupytext is built around round-tripping notebooks through text formats. They don't need panblack's guard because they carry their own guarantee. panblack hands such work to them through [hooks](configuration.md#hooks) instead of reimplementing or wrapping it.

Non-goals, therefore:

- Formatting code (code blocks, code cells). That is delegated to code formatters.
- Guarantees for processors other than pandoc.
