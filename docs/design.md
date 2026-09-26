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

## Judge the result, not the round trip

Making a pandoc round trip exact is a known hard problem. pandoc's own testing of `markdown → AST → markdown` finds cases that never settle, for example an escape character added on every pass. panblack does not try to solve it. It side-steps it by looking at what you actually get: if what you care about is markdown → html, then all a formatter must guarantee is that the formatted markdown gives you the same html. The checks (see [Terminology]) ask exactly that. The source and the formatted source may differ in pandoc's AST, and even in how a second formatting pass would write them, as long as every check you asked for renders them the same. Choosing the checks is choosing what "the same" means for your project.

## Limits (by design)

If something other than pandoc consumes your source (JupyterLab, nbconvert, GitHub, MkDocs, ...), panblack promises nothing about how that tool sees the result. The guard runs pandoc, not your processor, so a change pandoc considers equivalent may still change the output elsewhere. This is inherent to the approach. panblack does not try to model other processors or work around their differences from pandoc. If you don't process your sources with pandoc, use a formatter built on the same parser as your processor.

## Delegating to purpose-built tools

Tools like ruff, black, isort and jupytext are different: each one is built to transform its format *while preserving what that format means*. ruff and black parse Python into Python's own AST and check that formatting preserved it. jupytext is built around round-tripping notebooks through text formats. They don't need panblack's guard because they carry their own guarantee. panblack hands such work to them (see [External hooks]) instead of reimplementing or wrapping it.

Non-goals, therefore:

- Formatting code (code blocks, code cells). Delegated to code formatters.
- Guarantees for processors other than pandoc.

# Terminology

1.0 keeps 0.x's semantics (`require_idempotence_format`) and names the parts. `fmt(x) = write(parse(x))`.

check
:   A format `t` to render to. It passes when `render(parse(x), t) == render(parse(fmt(x)), t)`, compared with surrounding whitespace stripped, as in 0.x. A profile lists its checks in `check`, and **a file is written only if every listed check passes** (for notebooks, each cell; see [Cell-level formatting]). An empty list accepts any output, as 0.x did.

stability
:   The check named `source`: render with the profile's own writer. Because `render(parse(x), source) == fmt(x)`, it checks `fmt(fmt(x)) == fmt(x)`, i.e. that a second run changes nothing. This was 0.x's `"input_format"` entry, and it is the default (`check: [source]`), as in 0.x. Like any check it can be left out: with `check: [html]`, a result whose html is unchanged is accepted even if a second run would write it differently.

preservation
:   A check on a target format (html, latex, ...): pandoc renders the original and the formatted source the same. This is the relaxed rule from the 0.x README: the source is what you convert *to* those targets, so identical targets are what matters.

AST-equal
:   `parse(x) == parse(fmt(x))`. Not a requirement, a shortcut: if it holds, every check passes without being run.

A failed check rejects the file (exit code 2, see [CLI]); 0.x only logged a warning and exited 0.

## What a check renders

A check asks whether pandoc understands the formatted source the same way, seen through a target format. It is not the user's own output configuration. So a check renders with pandoc's defaults for that target, independent of the profile's `pandoc:` options, with two exceptions:

- The template is the metadata plus the body (`$meta-json$` and `$body$`). `meta-json` holds all metadata as rendered by the target writer, so a change to any field is caught. A standalone template would show only the fields it uses (title, author, date, ...).
- Line wrapping is off, because where the target breaks lines doesn't change what it means.

Extensions of the target can be set in the check's name as usual, e.g. `check: [source, html, latex-smart]`.

0.x rendered checks with the profile's pandoc arguments and the target's standalone template. The only effect of the difference is on what counts as "the same": 1.0 compares what pandoc understands, and doesn't fail because of how the target is configured to look.

# Guard algorithm

```
A   = parse(src)
out = write(A)
A'  = parse(out)
if A == A'                                             -> accept (fast path; no checks run)
elif all(strip(render(A,c)) == strip(render(A',c)) for c in checks) -> accept
else                                                   -> reject, report the failed checks
# render(_, source) = write, so the stability check reuses the parsed A and A'
```

Compared with 0.x (1 + 2N pandoc processes, each re-parsing), this parses twice, writes once, and runs the checks only when the fast path fails.

Since AST equality is only a shortcut, normalizing the AST before comparing (e.g. merging adjacent `Str`) would only make the fast path hit more often. As long as the normalization is safe, it can't change what is accepted. Measure the hit rate on real corpora before deciding whether that is worth doing.

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
- One tier, `md+html`: the markdown reader and writer, with checks `source` and `html`. pandoc's Markdown writer imports the HTML writer itself (for tables markdown can't express), so a markdown-only build is no smaller (see the spike results below).
- A guard failure makes the editor skip formatting and show a diagnostic. The guard is never dropped.
- Target use is format on save, so latency needs to be interactive, not per-keystroke.

Spike results (plan step 1, `haskell/wasm/`, GHC 9.12.4 wasm backend):

- Stock Hackage pandoc 3.10.2 builds for wasm; no fork, so the exact version pin holds. The output is byte-identical to the native build.
- Size: 24.7 MB after `wasm-opt -Oz`, 6.2 MB gzipped. The full pandoc.org `pandoc.wasm` is 59 MB. The `md` and `md+html` tiers came out the same size, and building every package with `split-sections` changed nothing: the linker already drops unreachable code, and what is left is reachable. Most of it is static data (13 MB); among named code the largest are texmath, emojis and commonmark, all used by the markdown reader and writer. Going smaller would need changes in pandoc.
- Latency on this 321-line doc: 0.16 s under wasmtime (precompiled); under node, 38 ms to compile, 245 ms for the first run, then about 175 ms. A one-line file takes 0.01 s. Fine for format-on-save.
- The host must pass a program name in `argv`; with an empty `argv` the GHC runtime exits with code 71.

Toolchain: [ghc-wasm-meta](https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta), installed as in [pandoc-wasm's CI](https://github.com/haskell-wasm/pandoc-wasm/blob/master/.github/workflows/build.yml) (download the archive, `FLAVOUR=9.12 ./setup.sh`), plus native `alex` and `happy`. `cabal.project.wasm` mirrors the `if arch(wasm32)` block of pandoc 3.10.2's own `cabal.project`: pandoc with `-http +embed_data_files`, and five patched dependencies whose patches are copied from pandoc's `wasm/patches` into `haskell/wasm/patches`. (The older pandoc-wasm fork, `haskell-wasm/pandoc`, is stale and not needed.)

# Formatter options

Which pandoc options make sense for a formatter. The list is taken from pandoc 3.10.2's source: the `ReaderOptions` fields that the Markdown and CommonMark readers use, and the `WriterOptions` fields that the Markdown writer uses.

## Formats and their table extensions

| Format | Table extensions (`+` on by default) |
|---|---|
| `markdown` | `+simple_tables +multiline_tables +grid_tables +pipe_tables +table_captions +table_attributes` |
| `commonmark` | `-pipe_tables` |
| `commonmark_x` | `+pipe_tables` |
| `gfm` | `+pipe_tables` |

The CommonMark family has only pipe tables, so most of [Tables] concerns `markdown` only.

## Style: how the same document is written

These only change how the writer spells the AST. They are the formatter's knobs.

| pandoc option | Effect |
|---|---|
| `to` (extensions only) | Which syntax the writer may use: table syntaxes, `four_space_rule` (list indentation), `fenced_code_blocks`/`backtick_code_blocks`, `space_in_atx_header`, ... Same flavour as `from`. |
| `wrap` | `auto` reflows paragraphs, `preserve` keeps source line breaks, `none` puts each paragraph on one line |
| `columns` | line length for `wrap: auto`, and table layout in every wrap mode |
| `markdown-headings` | `atx` (`#`) or `setext` (underlined) |
| `reference-links` | reference-style links instead of inline links |
| `reference-location` | where notes and reference definitions go: `block`, `section` or `document` |
| `ascii` | write non-ASCII characters as entities |

Line endings (`eol`) are handled by the CLI, not by pandoc's writer.

## Reading: must match how you run pandoc

These change what the source *means*, so they must be the same as in your own pandoc invocation, or the guarantee is about the wrong reading.

| pandoc option | Effect |
|---|---|
| `from` (+ extensions) | the flavour and syntax recognised |
| `columns` | also a reader option: a pipe table gets relative widths when a line is longer than it, and grid/multiline widths are computed relative to it. pandoc's CLI uses one `--columns` for both, and panblack does the same. |
| `tab-stop` | tab expansion when reading (and indentation when writing) |
| `indented-code-classes` | classes given to indented code blocks |
| `abbreviations` | where `smart` puts non-breaking spaces |

## Rejected

- `strip-comments`: it would delete HTML comments from the source.
- `default-image-extension`: it would rewrite image paths in the source.
- `toc`, `toc-depth`, `number-sections`, `id-prefix`, `variables`, `template`, `standalone`, `html-math-method`, `syntax-definition`: these add or decorate content. The markdown writer only uses them in its template or in raw-HTML fallbacks.
- `output-file`, filters, and everything else that isn't a reader or writer option.

## Recommended defaults for `markdown`

Assuming table widths are reset (see [Tables]; an option whose name and default are still open):

```yaml
pandoc:
  from: markdown-simple_tables-multiline_tables-smart
  to: markdown-simple_tables-multiline_tables-smart
  wrap: preserve
  columns: 72                                   # pandoc's default
check: [source, html]
```

Everything else stays at pandoc's defaults (`markdown-headings: atx`, inline links, `reference-location: document`, `tab-stop: 4`). These are pure style and don't affect what the guard accepts. Your 0.x configs used `reference-location: block`.

**No `smart`.** Typography is left to production: keep `smart` in your own pandoc runs, but format without it. With `smart`, the writer rewrites what you typed: curly quotes and apostrophes become straight ones, and an invisible non-breaking space (U+00A0) goes after abbreviations such as `p.` and `Mr.` (see [Upstream issues] 5). Without it, the text is kept exactly as typed. On the corpus, every file accepted without `smart` also renders the same html when read *with* `smart`: `smart` only changes how text is typeset, and formatting without it doesn't touch the text.

**Only grid and pipe tables.** The happy case assumes sources have no simple or multiline tables; see [Known limitations]. They are disabled for reading as well as writing, and grid and pipe tables are what people mostly use in the wild anyway.

Why, from runs on the corpus described in [Stability of the candidate defaults], at 72 columns with widths reset:

| `from` | `to` (writer tables) | wrap | html | settled after 1 round | never settles | written files stable after 1 round |
|---|---|---|---|---|---|---|
| grid + pipe | grid + pipe | `preserve` | **22/30** | 29/30 | 0 | **22/22** |
| all | grid + pipe | `preserve` | 20/30 | 27/30 | 0 | 20/20 |
| all | grid + pipe | `auto` | 22/30 | 29/30 | 1 | 22/22 |
| all | grid only | `preserve` | 22/30 | 26/30 | 0 | 18/22 |
| all | grid only | `auto` | 22/30 | 29/30 | 1 | 22/22 |
| all | pipe only | `preserve` | 16/30 | 18/30 | 0 | 16/16 |
| all | pipe only | `auto` | 18/30 | 20/30 | 1 | 18/18 |

- **Eight html failures are common to every row.** They are writer losses unrelated to tables (see [Other writer losses]), so 22/30 is the most any table setting can reach here.
- **`wrap: auto`** can loop forever on the escape problem. A reflowed line starting with `71.` gets escaped, and the escape moves the break. It happened in this corpus at 72 and 100 columns, and one of the two alternating versions can even render different html. Any prose can hit it, which is exactly the "save and it keeps changing" case. `auto` also rewrites every paragraph of an existing file.
- **Pipe tables only** lose every table that needs a grid table (block content, multi-line cells).

With the [Normalizations] below added and `smart` off, the same settings give **html 30/32 and 32/32 settled after one round**. That is on the corpus plus two new grid tables: one with a wrapped cell, and one with block content in a cell. The two remaining failures are example lists and `#.` lists ([Known limitations]), plus a link bug ([Upstream issues] 6) in the same file.

## Normalizations

A normalization is applied to the AST right after every read, on the original and on the formatted source alike. So the checks compare normalized documents, and the formatted source is written from a normalized AST. Each one gives up pandoc-relative equality for something that is, in practice, an accident of the source or of the writer: the html of your own pandoc run can change in the stated way. Each is a separate option, listed by name in a profile's `normalize:` key. All are on by default; `normalize: []` turns them off and gives pandoc-relative equality with no exceptions, as in 0.x (see [Migration from 0.x]). On the golden corpus (see [Plan]) with the recommended settings, they raise the accepted files from 675 to 864 of 1102. Implementation: `Panblack.Normalize`. Its output matches the Lua prototype (`haskell/experiments/normalize.lua`) byte for byte on the 24 documents of the corpus below.

| Normalization (`normalize:` name) | What changes in your own html | Why |
|---|---|---|
| **Reset table widths** (`table-widths`) | column widths (`<col style="width: …">`) | Widths come from dash lengths and `columns`, and the writer can't reproduce them. See [Tables]. |
| **Line breaks in table cells become spaces** (`table-cell-breaks`) | nothing visible (a newline becomes a space in the html source) | With widths reset, the writer may choose a pipe table for a grid table with wrapped cells, and with `wrap: preserve` it writes the line breaks into the pipe row, which gives an invalid table ([Upstream issues] 1). The table is laid out again anyway. Code blocks, code spans and math aren't affected, since they don't contain line-break elements. |
| **Strip leading and trailing blank lines in code blocks** (`code-block-blank-lines`) | those blank lines inside `<pre>` | A code block without attributes is always written as indented code, which can't hold them ([Upstream issues] 2). They are usually accidental, e.g. the padding rows of a grid cell falling inside a fence. |
| **Bare text directly inside a div becomes a paragraph** (`div-bare-text`) | a `<p>` inside such divs | `<div>text</div>` on one line reads as bare text, and no div syntax the writer has can write that back: both fenced divs and raw `<div>` put the content on its own lines. This is a limitation of the syntax, not a bug. |
| **Drop empty `<!-- -->` comments** (`empty-comments`) | the empty comment disappears | The writer inserts `<!-- -->` to separate a list from a following indented code block or list. That would be a new block in the html. The writer puts it back wherever it is needed, so the formatted source still reads correctly. |

Potential problems considered for the table-cell normalization: a cell with a paragraph followed by a list and a code block, one with a hard line break (`\`), and one with inline math and a code span that wrap across lines. These are all in `grid_blocks_wrapped.md`, which passes both checks. Hard breaks are a different element and are kept. The `east_asian_line_breaks` extension removes its line breaks while reading, so it doesn't interact.

## Known limitations

These are cases the happy case excludes. The guard may still accept such files, but the result isn't what you'd want:

- **Simple and multiline tables.** With the recommended `from`, they aren't tables at all: the dashed line makes the header row a setext heading, and the rows become paragraphs. The guard can't notice, because it compares under the same reader. Convert them to grid or pipe tables first, and use the same `from` in your own pandoc runs.
- **Example lists** (`(@)`, `(@label)`). The writer writes them as `(1)`, `(2)`, so they become ordinary lists and the guard rejects the file ([Upstream issues] 3). Even with that fixed, labels can't survive: the reader numbers the list and replaces each reference `(@label)` with the literal number, e.g. `(2)`, so the label never reaches the AST. The html would be unchanged, so the guard couldn't notice. The `example_lists` extension stays on: the writer never produces example lists, and turning the extension off would silently make existing ones plain text.
- **Autonumbered `#.` lists.** The writer writes them as `1.`, which changes the list style, so the guard rejects the file ([Upstream issues] 4). This can't be turned off by itself: `#.` belongs to `fancy_lists`, which also provides `a)`, `i.` and similar lists. A normalization that writes `#.` as `1.` works (30/32 becomes 31/32 on the corpus), but it isn't invisible. In LaTeX, a nested `#.` list gets LaTeX's own second-level label `(a)`, and after the normalization it gets `1.`. So it stays out of the happy case until the writer is fixed; it could be offered as an opt-in normalization.
- **`smart`** is off in the recommended settings, for the reasons above.

## Upstream issues

Found with pandoc 3.10.2, each with a minimal reproduction, as candidates for issues and patches. Known limitations that are *not* listed: the alignment of simple tables, pipe tables padded past `columns`, and bare text in divs.

1. **Table cells get raw line breaks with `--wrap=preserve`.** A cell whose text contains a soft line break is written with the newline inside the row. For simple tables (the default choice) the continuation becomes a new row; for pipe tables the row is invalid. With `--wrap=auto` it becomes a space, as it should here too. Reproduction: `haskell/experiments/softbreak-in-cell.native`, a two-column table with widths at their defaults and one cell `wrapped⏎text`:

    ```
    $ pandoc -f native -t markdown --wrap=preserve softbreak-in-cell.native
      a   b
      --- ---------
      x   wrapped
          text
    $ pandoc -f native -t markdown-simple_tables-multiline_tables --wrap=preserve softbreak-in-cell.native
    | a   | b       |
    |-----|---------|
    | x   | wrapped
           text     |
    ```

    Code: `Writers/Markdown/Table.hs`. In practice this hits any grid table with a wrapped cell once its widths are reset.

2. **Code blocks without attributes are always written as indented code**, even when `fenced_code_blocks` or `backtick_code_blocks` is enabled (`blockToMarkdown'`, `CodeBlock` case: fenced only if `attribs /= nullAttr`). Indented code can't hold leading or trailing blank lines, so those are lost:

    ```
    $ printf '```\ncode\n\n```\n' | pandoc -t native    # CodeBlock "code\n"
    $ printf '```\ncode\n\n```\n' | pandoc -t markdown  # "    code"
    ```

    It also forces `<!-- -->` between a list and a following code block. Proposal: use a fence whenever one of those extensions is on, or at least whenever the code has leading or trailing blank lines.

3. **Example lists are written as `(1)`**, not `(@)`: `orderedListMarkers` (`Writers/Shared.hs`) writes numbers for the `Example` style, so the list becomes a decimal list (`class="example"` is lost).

    ```
    $ printf '(@) a\n(@) b\n' | pandoc -t markdown     # (1) a / (2) b
    ```

4. **`#.` lists are written as `1.`**: the `DefaultStyle`/`DefaultDelim` list becomes `Decimal`/`Period` (`<ol>` becomes `<ol type="1">`). Same code path as 3.

    ```
    $ printf '#. a\n#. b\n' | pandoc -t markdown       # 1. a / 2. b
    ```

5. **`smart`'s non-breaking space after abbreviations is written out.** The writer's `unsmartify` undoes curly quotes and dashes, but not the non-breaking space the reader inserts after abbreviations.

    ```
    $ printf 'See p. 30.\n' | pandoc -t markdown | cat -A   # See p.M-BM- 30.
    ```

6. **A link URL containing an unbalanced `)` isn't escaped.**

    ```
    $ printf '[link](/hithere\\))\n' | pandoc -t markdown   # [link](/hithere))
    ```

    This reads back as a link to `/hithere` followed by a literal `)`.

7. **The commonmark writer drops the parentheses in `\\(...\\)`** (found on notebooks written for MathJax). The text is read correctly, as `Str "\\(a\\)"`, but written without the parentheses, so it reads back as `\a\`:

    ```
    $ printf '%s\n' 'x \\(a\\) y' | pandoc -f gfm -t gfm   # x \\a\\ y
    ```

8. **The commonmark writer drops the info string `text`**, so the `text` class is lost (`<pre class="text">` becomes `<pre>`). Other languages are kept.

    ```
    $ printf '```text\nx\n```\n' | pandoc -f gfm -t gfm       # ```
    ```

# Tables

Tables are where pandoc as a formatter hurts most. pandoc's table AST stores relative column widths. The reader derives them from the source, using the dash counts and scaling when a line is longer than `columns`; otherwise it stores none. The writer then picks a table syntax (simple, multiline, grid, pipe) based on the widths and on which extensions are enabled, and the new source reads back with different widths or alignment. This design doc is an example: pandoc rewrites its pipe tables as simple tables. That makes the alignment explicitly left and changes the widths, so the `html` check fails, and the widths shift again on every run, so `source` fails too.

## Findings (plan step 1b)

The experiment is `haskell/experiments/Tables.hs`. It runs 12 tables (each syntax, alignment, long lines, inline markup, block content in cells, and this doc's two tables) × every combination of disabled table extensions × `columns` 40/72/100/120/200, with checks `[source, html]`.

- **Default `markdown` accepts 14 of 60 runs.** The main cause is a writer limitation: a simple table can't express *default* alignment when a header is shorter than its column. The writer pads the header, the reader then sees it flush left, and the column becomes `AlignLeft`. Every pipe table without explicit alignment hits this, since the writer prefers simple tables. A known pandoc limitation: the four syntaxes are interchangeable, and there is no way to fix the syntax for one table.
- **Disabling extensions in `from` is the wrong knob.** `from` sets the reader too, so with pipe tables only, a simple or grid table in the source is read as a paragraph. The guard accepts that, because it is the same under that reader, but the user's own pandoc run (plain `markdown`) reads a table there.
- **So the writer gets its own extensions:** `pandoc.to`, defaulting to `from`. It must be the same markdown flavour as `from`, and only its extensions may differ.
- **Pipe tables only (`to: markdown-simple_tables-multiline_tables-grid_tables`), widths kept.** This was the best setting that keeps widths. It accepts 44 of 60 runs, and every pipe and simple table is written as a pipe table. The failures are grid and multiline tables (rejected, so left untouched), plus one known limitation: the writer can pad a pipe table past `columns`, and on re-reading the table gets widths it didn't have. This setting is superseded by [Recommended defaults for `markdown`], which resets widths.
- Keeping grid tables (`to: markdown-simple_tables-multiline_tables`) accepts 46 of 60 runs, but pipe tables then fail at narrow widths, because the writer switches to grid tables.
- **What each syntax can express** (pandoc 3.10.2 manual and reader): grid tables are the most capable. They have block content, row and column spans, alignment, a foot and headerless tables. Pipe tables have none of the first four and no multi-line cells. The exception is widths: grid and multiline tables *always* get widths on reading, computed from the dash lengths relative to `columns`. Only pipe tables (with no line longer than `columns`) and simple tables can have none.
- **Resetting widths** means setting every column's width to default in the AST right after reading, on both the original and the formatted source. Then width can't cause a mismatch, and grid tables can express everything. With `to:` grid tables only (`markdown-simple_tables-multiline_tables-pipe_tables`), every run passes the `html` check at every `columns`. The html check then doesn't depend on `columns` at all: the reader only uses it to compute widths, which are reset, and checks render without wrapping. The rest (8 of 60) fail only `source`. When cell text doesn't fit in `columns`, the grid writer wraps it, `--wrap=preserve` keeps that wrap as a line break, and the next run lays the table out differently once more. In every case, including this doc at 72 and 120, the second run reaches a fixed point.
- **Why it's still not free:**
    - Resetting only happens inside panblack. The user's own pandoc run still reads widths: this doc's pipe table goes from 50/50 to 20/79, and a table with no widths gains some, since a grid table always has them. So this doesn't hold the pandoc-relative guarantee for widths. It would be an explicit opt-in meaning "same, except table column widths".
    - A large `columns` is not a fix. It changes what is written, since `columns` is the markdown writer's line length (tables in this doc grow to 194 characters, and in general a cell never wraps). The failing check is `source`, which by definition reruns the formatter with the same options, so it can't use a different `columns` from the output.
- **When pipe tables are written with widths reset**, a multiline table's multi-line cells go into a pipe table, and with `--wrap=preserve` the line breaks are written inside the pipe row. That breaks the table, so it reads back as a paragraph. This is a writer bug: pipe cells can't contain newlines. It doesn't happen when pipe tables are disabled in `to`.
- `columns` also sets the reader's columns, as with the pandoc CLI. The reader uses them to decide whether a table gets relative widths.

Open: whether to offer width-resetting as an opt-in (see above), and which `to:` default `panblack init` writes. Then rerun on real corpora in step 2.

## Stability of the candidate defaults

Run with `haskell/experiments/Stability.hs` on 30 documents (about 70 tables):

- the 12 synthetic tables
- this doc
- pandoc's own markdown test files (`tables`, `pipe-tables`, `testsuite`, `markdown-reader-more`, `markdown-citations`)
- the 12 sections of pandoc's `MANUAL.txt` that contain a table

For each document it iterates `f(i+1) = write(read(f(i)))` from the source `f0`, and records:

- **html:** `html(f0) == html(f1)`, the output check;
- **round 1:** `f1 == f2`, the `source` check;
- **round 2:** `f2 == f3`;
- **settles:** the round at which the output stops changing, if any.

`from: markdown`, `to: markdown-simple_tables-multiline_tables`, over `columns` 72/80/88/100/120:

| wrap | widths | html | round 1 | round 2 | never settles (>8 rounds) |
|---|---|---|---|---|---|
| `auto` | kept | 15–17 | 23–27 | 26–29 | 1–2 |
| `auto` | reset | 21–22 | 29–30 | 29–30 | 0–1 |
| `preserve` | kept | 15–17 | 23–27 | 26–29 | 1 |
| `preserve` | reset | 20 | 27 | **30 at every width** | 0 |

At 80 columns, `wrap: auto`: html 15, round 1 27, round 2 27, never 1 with widths kept; html 22, round 1 30, round 2 30, never 0 with widths reset.

What the failures are:

- **Table widths** account for every html failure that resetting widths fixes (7 of 15 documents at 80), and for most of the documents that take 3–5 rounds to settle.
- **Wrap and escape oscillation** (`wrap: auto` only): a line break can put a number ending in `.` at the start of a line, where it would read as a list item. So the writer escapes it (`71\.`), which lengthens the line and moves the break, so the next round it isn't escaped. This is period-2 forever (this doc at 100 columns, pandoc's reader test at 72). It is the escape problem that makes pandoc round trips hard to stabilise; the html doesn't change.
- **Multi-line cells written as a pipe table with `wrap: preserve`**: the line breaks go inside the pipe row and break the table (see [Tables]). With `wrap: auto` they become spaces, so this doesn't happen.
- **Other writer losses, not about tables** (the guard rejects these files, which is the design working):
    - trailing blank lines of a code block inside a grid cell are dropped;
    - example lists (`(@)`, `(@foo)`) are written as `(1)`, so they become ordinary lists;
    - `smart` inserts a non-breaking space in `[p. 30]` inside a citation;
    - one list numbering style in pandoc's `testsuite` (`<ol>` becomes `<ol type="1">`).

Two rounds are not always enough with widths kept: some documents take 3 or 5. With widths reset and `wrap: preserve`, every document is fixed after round 2 at every width. With widths reset and `wrap: auto`, almost every document is fixed after round 1; only the escape oscillation remains.

# Config

The file is `.panblack.yaml`. It holds a list of profiles, like the 0.x array of tables.

```yaml
- paths: [pages, README.md]
  exts: [md]
  excludes: []
  check: [source, html]    # all must pass; default [source] (see Terminology)
  normalize: [table-widths, table-cell-breaks]   # default all (see Normalizations)
  pandoc:                  # inline pandoc defaults file (alternatively: defaults: path/to/file.yaml)
    from: markdown-raw_attribute-latex_macros-simple_tables-multiline_tables+east_asian_line_breaks+autolink_bare_uris
    wrap: preserve
    columns: 120
    reference-location: block

- paths: [src]
  exts: [ipynb]
  excludes: ['.ipynb_checkpoints/']
  check: [source, html]
  pandoc:
    wrap: preserve
    columns: 120
    reference-location: block
  ipynb:
    cell-format: gfm-tex_math_gfm    # default; see "Markdown flavour for notebooks"
  hooks:
    - [jupytext, --sync, --pipe, 'ruff check --select I --fix-only -', --pipe, 'ruff format -', '{path}']
```

- `pandoc:` is parsed by pandoc's own defaults-file parser, after checking that it only uses the options in [Formatter options]: `from`/`reader`, `to`/`writer`, `columns`, `tab-stop`, `indented-code-classes`, `abbreviations`, `wrap`, `markdown-headings`, `reference-links`, `reference-location`, `ascii` and `eol`. Anything else is an error (`output-file`, `filters`, `standalone`, ...). So is an unknown key anywhere in the config. `to` defaults to `from` and may differ only in extensions (see [Tables]).
- `defaults:` names a pandoc defaults file, relative to the config file, with the same restriction. The inline `pandoc:` keys override it. It can't include further defaults files. `abbreviations` is also relative to the config file (pandoc's CLI resolves it relative to the working directory).
- `eol` (`lf`, `crlf`, `native`; pandoc's default is `native`) sets the line endings written. As with the pandoc CLI, input is read with carriage returns and a byte-order mark removed and tabs expanded, so a CRLF file is rewritten with LF under the default.
- Defaults are 0.x's: `exts: [md, markdown]`, `excludes: [.git/, .pytest_cache/]`, `check: [source]`, and pandoc's own defaults for `pandoc:`. The exception is `normalize:`, which defaults to all of them.
- As with pandoc's CLI, the reader's abbreviations (for `smart`) come from pandoc's `abbreviations` data file unless `abbreviations` names a file. The reader's built-in default list is shorter.
- A file matched by two profiles is an error (0.x formatted it twice, concurrently).
- Without a config file, `panblack PATH...` uses one profile with those defaults on the given paths.
- A file is a notebook if its extension is `.ipynb`. Its cells are read and written in `ipynb.cell-format`, not `pandoc.from`/`to`; the other `pandoc:` keys apply as usual. So one profile can cover notebooks and markdown files alike.
- In a git repository, git decides which files a listed directory has: `git ls-files --cached --others --exclude-standard`, i.e. tracked files and the untracked ones git doesn't ignore, by `.gitignore` files at any level, `.git/info/exclude` and the global excludes file. A tracked file is included even if a `.gitignore` matches it, as for git. `--stdin-filename` asks `git check-ignore`. Without git, or outside a repository, the directory is walked and only `excludes` apply. Running git costs no library and about 40 lines, and gives git's own rules rather than a reimplementation.
- `excludes`: gitignore-style globs, applied on top of git's list, or while walking. A trailing `/` matches directories only, a pattern with another `/` is anchored at the config directory, and any other pattern matches a name at any depth. A file listed in `paths` is always included, as in 0.x.
- `panblack init` prints the recommended defaults for markdown.

# ipynb

## Recommended: format the notebook, let jupytext write the pair

Notebook users mostly edit the `.ipynb` in JupyterLab, so the notebook is the source and a paired text file is a view of it. The recommended workflow is therefore 0.x's: a profile formats the `.ipynb` (see [Cell-level formatting]), and a hook runs `jupytext --sync` so that jupytext writes the text side from it:

```yaml
- paths: [notebooks]
  exts: [ipynb]
  excludes: ['.ipynb_checkpoints/']
  hooks:
    - [jupytext, --sync, --pipe, 'ruff check --select I --fix-only -', --pipe, 'ruff format -', '{path}']
```

Pair the notebook in its metadata (`jupytext --set-formats ipynb,md`), so panblack can see the pairing (see [Pairs]). Verified with jupytext 1.19.5 and ruff 0.16.9: it settles on the first run, outputs are kept, and `--check` passes afterwards. panblack never writes the text side, so jupytext's YAML header is never touched.

Rule: **a pair has exactly one side formatted by panblack.** If both sides are in panblack's paths, two serializers fight, and the pair never converges.

### Alternative: format the text side

Users who edit the text side instead can format it with a markdown profile, with two changes, both found by testing with jupytext 1.19.5:

- The hook must write only the notebook: `[jupytext, --to, ipynb, --update, '{path}']`, which keeps the outputs. `jupytext --sync` also rewrites the text side in jupytext's own form (` ```python ` for pandoc's `` ``` python ``), so panblack and jupytext rewrite it back and forth on every run and `--check` never passes.
- The text side must have no jupytext YAML header. pandoc rewrites YAML metadata in its own form: `format_version: '1.3'` becomes `format_version: 1.3`, a string becomes a float, and jupytext then fails with a `TypeError`. pandoc reads both the same, so the guard can't see this (see [Limits (by design)]). Set the pairing in `jupytext.toml` instead, with `notebook_metadata_filter = "-all"`.

## Pairs

panblack reads the pairing from each notebook it formats (`jupytext.formats` in its metadata), for two things:

- It warns when the other side of the pair is formatted too. It finds the other side as jupytext's `paired_paths` does (extensions, suffixes such as `.pct.py`, directory and file-name prefixes), except for prefix roots (`notebooks///ipynb`, which mirror a directory tree) and pairings set only in a jupytext config file (reading those would need a TOML parser). Those notebooks just get no warning.
- It decides whether the cells are also one document (see [Cell-level formatting]): they are if the notebook is paired with a markdown format (`md`, `Rmd`, `qmd`, `myst`, ...), because a markdown reader then reads the text side whole.

## Cell-level formatting

pandoc's ipynb round trip normalizes more than a formatter should. For example, running 0.x with pandoc 3.10.2 on `tests/ipynb/example_1.ipynb` changed `language_info.codemirror_mode.version` from the number `3` to the string `"3"`, and for a notebook without cell ids pandoc makes up new random ones on every run, so 0.x's check never passes on it. Metadata, nbformat minor version, cell ids and attachments are all at risk in the same way. 1.0 therefore formats cell by cell (`Panblack.Notebook`):

- The JSON is parsed with aeson (already a pandoc dependency), and only the markdown cells' `source` goes through the markdown pipeline. The new sources are spliced into the original bytes, so every other byte is kept: metadata, outputs, cell ids, number formatting, indentation. A source keeps its shape: a string stays a string; a list of lines stays a list, laid out like the old one. It is written as Jupyter writes JSON (Python's `json.dumps`), with non-ASCII characters escaped only if the file is all ASCII. A final newline is kept or left out as in the original cell, since Jupyter cells usually have none. Carriage returns are removed before reading, as for files.
- **Each cell is a document.** JupyterLab, nbconvert and pandoc's own ipynb reader all read each cell on its own, so the guard checks each cell on its own. A cell whose checks fail is kept as it was, and the other cells are still formatted: the file is *partly reformatted* (exit code 2, so `--check` and pre-commit still flag it). This is the one exception to "a file is written only if every listed check passes" (see [Terminology]): for a notebook, the unit is the cell.
- **Whole-notebook check, for notebooks paired with markdown** (see [Pairs]). All markdown cells, formatted or kept, are joined (separated by a blank line) into one document, parsed with the *same* cell format, and compared before and after. If it fails, nothing is written. This catches what spans cells in the text side, such as a reference link whose definition is in another cell, or footnotes numbered across the notebook: the writer renumbers each cell's footnotes from 1, so joined they collide. For an unpaired notebook these are faithful per-cell changes. One consequence: a cell holding only a link reference definition becomes empty, since per cell the definition is unused. panblack implements this check itself instead of going through pandoc's ipynb reader, so the reader and writer always agree on the markdown flavour.
- A failure names the cell (`cell 3: html`, counting all cells from 1) or `all markdown cells`.
- 0.x's `del_jupytext_encoding` (on by default) is dropped: metadata is never changed. 0.x needed it because pandoc 2.x's ipynb writer escaped metadata strings as markdown on every round trip (`# -*- coding: utf-8 -*-` became `\# -\*- coding: utf-8 -\*-`, then `\\\# ...`), so 0.x's stability check always failed on a notebook with that key. Checked with pandoc 2.16.2, the version current when 0.x added the option (Dec 2021). jupytext stores the key when it reads a `.py` file with a coding line. pandoc 3.10.2 keeps the string, and 1.0 doesn't pass metadata through pandoc at all.

Results on 137 distinct notebooks found on the author's machine (tutorials, course material, blog posts), with `check: [source, html]` and `wrap: preserve`, took 0.5 s in all. 2 are paired with markdown. 61 were reformatted and 63 were already formatted. 11 were partly reformatted, keeping 14 cells, all rightly:

- 9 (copies of one tutorial): display math spanning lines, which pandoc reads differently after formatting.
- 1: `\\(\sigma\\)` in three cells, which the commonmark writer writes without the parentheses ([Upstream issues] 7).
- 1: a fenced block with the info string `text`, which the commonmark writer drops ([Upstream issues] 8).

1 was rejected by the whole-notebook check: it is paired with `_pair//md` and numbers its footnotes across cells. 1 file was not JSON. Every notebook that was in Jupyter's own layout before (131 of them) still is afterwards, code cells, outputs and metadata are unchanged, and a second run changes nothing.

Cell-level formatting is settled: the fallback, a whole-notebook pandoc round trip as in 0.x, is not needed.

## Markdown flavour for notebooks

In 0.x the flavour was `input_format`, which served as both reader and writer format. For ipynb this meant spelling out the full pandoc-markdown extension list on top of `ipynb`.

Notebook authors usually write for JupyterLab (marked, roughly GFM, plus `$...$` math), not pandoc markdown. So cell markdown gets its own key, `ipynb.cell-format`. It defaults to `gfm-tex_math_gfm`, the pandoc flavour closest to how notebooks are written. `gfm` already reads `$...$` (`tex_math_dollars`), but with `tex_math_gfm` it *writes* all math in GitLab's syntax (`` $`x`$ `` and ```` ```math ```` blocks), which JupyterLab doesn't render. Users who process notebooks with pandoc (for example with pannb) can set it to a pandoc-markdown variant.

Choosing a flavour does not change what is guaranteed. The guard still runs pandoc, so the [Limits (by design)] above apply as they do to any other source.

# External hooks

`hooks:` is a list of argv templates, run in order in the config directory after each file is accepted, whether it was changed or already formatted (0.x ran jupytext after every accepted file too). `{path}` is replaced by the file's path relative to the config directory. The first hook that fails stops the rest and gives exit code 3, with its output; a missing executable is reported as `command not found`. Hooks don't run for rejected files, with `--check` or `--diff` (which report panblack's own changes only), with stdin, or in the wasm build.

Hooks are how panblack delegates to the purpose-built tools described in [Delegating to purpose-built tools]. panblack's guard doesn't apply to hooks because they don't need it: the tools carry their own guarantee. It also couldn't apply: a code formatter intends to change code text, which any target-equal check (html renders code blocks) would reject.

Hooks run after the write, so jupytext sees the freshly written file as the newest one.

## Code formatting: ruff

The recommended code formatter is ruff, replacing black and isort. For a notebook formatted directly:

```yaml
hooks:
  - [jupytext, --sync, --pipe, 'ruff check --select I --fix-only -', --pipe, 'ruff format -', '{path}']
```

This was verified with jupytext 1.19.5 and ruff 0.16.9: jupytext pipes each notebook through ruff as a py:percent script over stdin, and outputs are kept. Don't use jupytext's `{}` placeholder with ruff's `-` stdin argument: jupytext then passes a temp file and ruff waits on stdin forever. When formatting the text side instead (see [Alternative: format the text side]), add the same `--pipe` arguments to its `--update` hook.

Differences from the 0.x black + isort setup:

- ruff's import sorting has no equivalent of isort's `--float-to-top`. Imports are sorted within each cell but not moved into the first cell. Users who want that keep isort in the hook.
- For a notebook with no pair, ruff can format `.ipynb` directly, without jupytext: `[ruff, format, '{path}']`.

Since hooks are plain commands, black and isort (or anything else) stay possible; `panblack init` emits the ruff version.

An alternative is to leave all of this to pre-commit (`panblack` → `jupytext` → `ruff`) and have no hooks. That's simpler, but profiles then no longer describe the whole workflow.

# CLI

```
panblack [PATH...]          # format in place using .panblack.yaml profiles
  --check                   # exit 1 if any file would change
  --diff                    # print a unified diff, write nothing
  --config FILE
  -j N                      # default: number of CPUs
  --no-cache                # format every file; neither read nor update the cache
  -v                        # list unchanged files; show the check renders that differ
panblack - [--stdin-filename PATH]   # stdin to stdout
panblack init               # print a starter .panblack.yaml
panblack --version          # includes the bundled pandoc version
```

Exit codes: 0 means OK. 1 means `--check` found changes. 2 means a failed check (see [Terminology]). 3 means an error in usage, config or IO. With several files the highest code wins. A guard failure is never downgraded to a warning (0.x logged it and exited 0).

- The config is `.panblack.yaml`, searched from the working directory upwards, stopping at the repository root (the directory containing `.git`).
- `PATH...` selects among the files the profiles cover: those files at or below the given paths. A named file that no profile covers is skipped with a note, so a pre-commit hook can pass every changed file.
- Reports go to stderr, one line per file (`reformatted`, `would reformat`, `partly reformatted` for notebooks, `rejected`, `error`) and a summary; diffs go to stdout.
- With `-`, the profile is the only one, or the one covering `--stdin-filename`. The formatted source is written to stdout. If it is rejected, the input is written back unchanged (exit 2), so a pipe never loses the document.

## Cache

As black does, panblack skips files it has already accepted. Implementation: `Panblack.Cache`.

- Each profile has a cache file, `$XDG_CACHE_HOME/panblack/KEY.json`, mapping each file's absolute path to the SHA-256 of its content. `KEY` is a digest of everything else the result depends on: the panblack and pandoc versions, the config directory, and the profile with its resolved pandoc settings (so the contents of a `defaults:` or `abbreviations` file count too). Changing any of them starts a new cache.
- A file whose content has its recorded digest is reported `unchanged`, without being read by pandoc or running its hooks.
- A file is recorded only when running panblack on it again would change nothing and report nothing: it was accepted (unchanged or reformatted), not partly reformatted, with no warning and no failed hook, and the hooks left it as panblack wrote it. A hook that changes the file (jupytext with ruff `--pipe`s does, for code cells) means it is checked once more on the next run, and recorded then. Rejected files are never recorded, so they are reported on every run.
- `--check` and `--diff` read the cache. They record only files that are unchanged and have no hooks, since they don't run hooks.
- Not covered: the versions of the tools that hooks run (as with black and its plugins), and the other side of a jupytext pair. After upgrading ruff, say, use `--no-cache` once. Stdin is never cached.
- Reading or writing the cache never fails a run: an unreadable cache is empty, and the file is replaced atomically. Concurrent runs may lose each other's new entries, which only costs a recheck.
- Measured: 20 copies of this doc with the `panblack init` settings take 2.2 s at `-j1` and 0.00 s cached; the same with a hook that takes 0.2 s, 1.8 s at `-j4` and 0.00 s cached. pandoc's 1090 small `test/command` files take 0.14 s either way, so there the cache doesn't matter.

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
| `input_format` | `pandoc.from`. For ipynb profiles, `ipynb.cell-format`: the extensions pandoc's ipynb reader and writer used for cells (`ipynb`'s own, close to GFM, with the profile's modifiers applied), written relative to `markdown`. `export-config` lists them with the pandoc 0.x runs. |
| `require_idempotence_format` | `check`, same meaning. The `"input_format"` entry becomes `source`. |
| (none: 0.x has no normalizations) | `export-config` writes `normalize: []`, so the output stays as 0.x's. Remove it to get the default normalizations. |
| `paths`, `exts` | unchanged |
| `excludes` (regex) | `excludes`, as globs (see [Config]). A regex that is a literal name (`.` or `\.` read as a literal dot) translates exactly, since 0.x searched the whole path: `name/` becomes `*name/`, `name` becomes `*name*`. Any other regex is an error. In a git repository, files git ignores are now skipped too. |
| `pandoc_args` | `pandoc:` keys, e.g. `--wrap=preserve` → `wrap: preserve`. `--sandbox` is dropped (always on), and `--ipynb-output` with a note (1.0 never changes outputs). Any other arg is an error with a pointer to the docs. |
| `del_jupytext_encoding` | removed: `export-config` ignores it with a note (see [Cell-level formatting]) |
| `post_jupytext_sync`, `jupytext_args` | `hooks: [[jupytext, --sync, ...args, '{path}']]`. `export-config` keeps black/isort pipes as they are and prints the ruff equivalent as a suggestion. |
| `pandoc_path` | removed (pandoc is bundled) |
| `processes`, `mode` | `-j` |
| `toml_path`, `save*` | `--config`, `panblack init` |

Expect a one-time reformat commit per project, because the pandoc version changes. 0.x also wrote files without a final newline (panflute's `convert_text` strips pandoc's output), and 1.0 adds it back.

# Plan

0. Get 0.x running locally against a recent pandoc, as a reference *oracle* for parity tests. No release. **Done** (see [Running the 0.x oracle]).
1. Spike: `panblack-core` markdown-only on the GHC wasm backend, plus size and latency numbers. This decides the wasm tiers. **Done** (see [`panblack-wasm` (editor build)]). The core and a stdin→stdout prototype driver are in `haskell/` (native output byte-identical to the pandoc CLI with the 0.x template).
    - 1b. Tables (see [Tables]), in parallel with the spike. **Done** for the synthetic set; real corpora in step 2.
2. Core and CLI for markdown: guard, config, `--check`/`--diff`. Golden tests against the 0.x oracle on real corpora, with both using the same pandoc version.
    - CLI, config and normalizations: **done**. With no normalizations, the output is byte-identical to the pandoc CLI (what 0.x runs) for every formatter option on four documents (pandoc's `testsuite.txt`, `markdown-reader-more.txt` and `MANUAL.txt`, and this doc), for `markdown`, `gfm` and `commonmark_x`. With all of them on, it is byte-identical to pandoc with the Lua prototype on the 24-document corpus.
    - Golden tests: **done**, `haskell/golden/run.sh`. The corpus is pandoc's own markdown, fetched with `cabal get` for the pinned version: `MANUAL.txt`, the top-level `.md` files, the markdown reader tests and the 1090 `test/command/*.md` files, 1102 files in all. 0.x and 1.0 (`normalize: []`) format separate copies under three settings: the defaults; the defaults with `html`; and `wrap: preserve`, `columns: 120`, `reference-location: block` with `html`. Every file comes out byte-identical, except that 0.x drops the final newline. The accept/reject decisions agree too, although 1.0 renders checks differently (see [What a check renders]). The golden run found two differences, both fixed: the pandoc CLI expands tabs before reading, and it takes `smart`'s abbreviations from a data file.
3. ipynb: pair detection and cell-level formatting, plus hooks. **Done** (see [ipynb] and [External hooks]). Tested on 137 real notebooks and end to end with jupytext and ruff. This showed that formatting the text side of a pair needs `jupytext --update` rather than `--sync`, and no jupytext YAML header (see [Alternative: format the text side]).
4. Settle the open questions, then freeze the config schema.
    - A cache, as black has: **done** (see [Cache]). Runs are already fast (0.06 s for one notebook, 0.5 s for 137, of which about 0.04 s is start-up), so a daemon wouldn't buy much; the cost worth saving is re-running hooks such as jupytext and ruff, and large documents, on files that haven't changed. Watching files is left to tools such as `watchexec`.
5. Python `v0.2.0` tag: `export-config` and the deprecation notice. **Done** (`src/panblack/export.py`, tagging pending). On the author's wiki config (three profiles, one ipynb with a spelled-out extension list), the exported config loads in 1.0, formats, and settles; the cell format comes out as `markdown+autolink_bare_uris+east_asian_line_breaks-latex_macros-raw_attribute-table_attributes`, the flavour the list was written to mimic, plus `table_attributes`, which pandoc added later.
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

# Licence

GPL-2.0-or-later, as pandoc, laid out as pandoc does: `COPYRIGHT` holds the notice and the exceptions, `COPYING.md` the licence text (the cabal package in `haskell/` links to both). pandoc is GPL-2.0-or-later and every panblack binary bundles it, so distributed binaries were covered by the GPL anyway; with the source under the same licence there is no split, and the repository can include pandoc-derived material. 0.x keeps BSD-3: its releases, `v0.2.0` the last, are tagged on the `0.x` branch, and the move to the GPL comes with the rewrite. The exception is `haskell/wasm/patches`, MIT, copied from pandoc.

Test corpora come from pandoc itself (the markdown files under `test/`, and `MANUAL.txt`). They are taken at test time from the pinned pandoc source (`cabal get pandoc-3.10.2`), not copied into the repository. That keeps them in step with the pinned version whatever the licence.

# Open questions

Nothing here blocks prototyping. Each question has a provisional choice that the prototype builds on; the prototype's evidence settles it before the config schema is frozen (plan step 4). Only the config-shape questions affect migration.

| Question | Provisional choice | Settled by |
|---|---|---|
| AST normalization before comparing (speed only) | none; measure fast-path hit rate | golden corpus (step 2) |
| Default table settings | `from`/`to: markdown-simple_tables-multiline_tables`, `wrap: preserve`, widths reset (see [Recommended defaults for `markdown`]) | step 2 corpora |
| Normalizations: option names, defaults, how to turn them off | a `normalize:` list, all on by default, `[]` for none; see [Normalizations] | before freeze |
| wasm tiers | settled: one tier, `md+html` | spike (step 1), done |
| `excludes` regex or globs, and `.gitignore` | settled: gitignore-style globs, on top of git's own list of files (see [Config]) | author, done |
| ipynb: partial formatting and the whole-notebook check (see [Cell-level formatting]). Three things to revisit: a notebook paired with a markdown file that nothing renders as one document (e.g. kept only for diffs) is still rejected for footnotes numbered across cells, which may call for `ipynb.whole-notebook-check: never`; without the check, a cell holding only a link reference definition becomes empty, which is faithful per cell but deletes what the author wrote, so it might be rejected instead; and a partly reformatted file exits 2 on every run until its kept cells are fixed by hand | per cell, keep rejected cells; whole-notebook check only when paired with markdown | usage |
| ipynb: cell-level or whole-notebook round trip | settled: cell-level (see [Cell-level formatting]) | step 3, done |
| Hooks or pre-commit only | settled: hooks (see [External hooks]); pre-commit can still chain the tools instead | author, done |
| Licence: GPL-2.0-or-later (like pandoc and pandoc-crossref) or keep BSD-3 | settled: GPL-2.0-or-later; see [Licence] | author, done |
| Config filename and discovery | settled: `.panblack.yaml`, walk up to the repo root | author, done |
