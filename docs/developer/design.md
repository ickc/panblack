---
title: Design notes
description: Why panblack is built the way it is, with the experiments, measurements and upstream issues behind each choice.
---

These notes are for working on panblack: the reasoning and the evidence behind its design. What panblack promises and how to use it are in the Guide, starting from [Core philosophy](../guide/philosophy.md); this page doesn't repeat them. How to build, test and release is in [Development](development.md).

# Goals

- Keep the core idea of 0.x: format with pandoc, and trust the result only if it passes a *guard* (see [Core philosophy](../guide/philosophy.md)).
- Ship one static binary that bundles pandoc. The output then depends only on the panblack version, as with black.
- Offer a minimal wasm build for editor format-on-save, where latency matters.
- Use a YAML config that reuses pandoc's defaults-file format, and pull in no new parsing dependencies.
- Give 0.x users an obvious migration path.

# Guard algorithm

The semantics are 0.x's `require_idempotence_format`, with its parts named (see [the checks](../guide/philosophy.md#several-targets-at-once)). `fmt(x) = write(parse(x))`, and a check `t` passes when `render(parse(x), t) == render(parse(fmt(x)), t)`, compared with surrounding whitespace stripped, as in 0.x.

```
A   = parse(src)
out = write(A)
A'  = parse(out)
if A == A'                                    -> accept (fast path; no checks run)
elif all(strip(render(A,c)) == strip(render(A',c))
         for c in checks)                     -> accept
else                                          -> reject, report the failed checks
# render(_, source) = write, so the stability check reuses the parsed A and A'
```

Compared with 0.x (1 + 2N pandoc processes, each re-parsing), this parses twice, writes once, and runs the checks only when the fast path fails. Implementation: `Panblack.Guard`, in `PandocPure`.

**The fast path, measured.** With CI's build of `c54891c` (`panblack --no-cache -v`, whose report says when the checks, rather than AST equality, accepted a reformatted file), on the golden corpus (1128 files of pandoc 3.12.1's own markdown), and with the current build on Quarto's documentation (552 pages, described with the test corpora under [Licence](#licence)):

| Corpus | Settings | Accepted | AST-equal | via the checks | Rejected (failed checks) |
|---|---|---|---|---|---|
| pandoc | `check: [source]`, `normalize: []`, pandoc's defaults | 1122 | 658 | 464 | 6 |
| pandoc | `check: [source, html]`, `normalize: []`, pandoc's defaults | 691 | 658 | 33 | 437 |
| pandoc | `panblack init` | 887 | 887 | 0 | 241 (240 html, 1 both) |
| pandoc | `panblack init`, `check: [source]` | 1126 | 886 | 240 | 1 |
| pandoc | `panblack init`, `wrap: auto` | 886 | 850 | 36 | 242 |
| Quarto | `panblack init` | 510 | 507 | 3 | 42 (34 html, 8 both) |
| Quarto | `panblack init`, `wrap: auto` | 510 | 130 | 380 | 42 (33 html, 9 both) |

What it shows (written up for users in [Core philosophy](../guide/philosophy.md#when-the-ast-doesnt-change-and-when-it-does)):

- Accepting a changed AST is what `wrap: auto` depends on: all 33 files of the second row are reflows (`SoftBreak` and `Space` swapped), and on Quarto's pages 377 of the 380 (the other 3 are those of the next point).
- With `wrap: preserve` and the normalizations, an AST change is always an output change on pandoc's corpus: no file is accepted through the checks, and the 240 that `source` alone accepts are all html failures. On Quarto's, 3 are: each holds an `{=html}` inline that `raw: native` writes natively, which reads back as two raw elements (`raw: auto` keeps it as typed).
- In the steady state (a second run over the formatted corpus), every accepted file is unchanged, which is AST-equal trivially.

**A wrap-insensitive fast path: measured, not adopted.** The recommended settings already include the five [normalizations](../guide/markdown.md#normalizations), which change what is accepted. A different kind would apply only to the two ASTs compared for the fast path, so it could only skip rendering the checks, never change what is accepted. The one that matters is wrapping: with `wrap: auto`, nearly every file is accepted through the checks, because reflowing swaps `SoftBreak` and `Space`. Measured with a build whose fast path compares the ASTs with every `SoftBreak` replaced by `Space` (same corpora, `panblack init` with `wrap: auto`, `--no-cache -j1`):

| Corpus | Accepted via the checks | of those, equal with soft breaks as spaces | Rejected files equal so | Time, current → relaxed |
|---|---|---|---|---|
| pandoc | 36 | 36 | 0 | 6.2 s → 6.2 s |
| Quarto | 380 | 377 | 0 | 6.6 s → 4.5 s |

So reflowing is the only AST change nearly all those files had, and the relaxed fast path would decide exactly as the checks do. It isn't adopted:

- It saves time only the first time a file is reflowed: about a third on Quarto's pages, nothing measurable on pandoc's corpus. Afterwards a file is unchanged, or skipped by the cache.
- It is sound only if every check renders a soft break and a space alike. The targets do, since they render with wrapping off, but the `source` check renders with the profile's writer, and under `wrap: preserve` a soft break is a line break. The guard would have to know how each check wraps, which ties the format-independent guard to writer options for a small gain.

Merging adjacent `Str` elements, the other candidate, finds nothing: every file accepted through the checks differs by soft breaks.

# Architecture

## `panblack-core` (library)

- Runs purely in `PandocPure`: no IO, deterministic, sandboxed by construction (this replaces `--sandbox`).
- Templates and resources are provided through PureState's in-memory file tree. The markdown template (`$titleblock$` + `$body$`, 0.x's) is embedded.
- Readers and writers are imported directly, not through pandoc's registries, so a build that only needs markdown can drop the other formats at link time. Checks other than `html` go through the writer registry (`Panblack.Target.Registry`), which only the CLI links.
- API: `format :: Profile -> Text -> Either GuardFailure Formatted`. A `Profile` is a reader, a writer and a list of checks; normalizations wrap its reader, and the raw syntax (`Panblack.Raw`) its writer.

## `panblack` (CLI, native static binary)

- Handles file discovery, parallelism (GHC threads, `-j`), IO, the cache and hooks.
- Built through `pandoc-forge/pandoc-feedstock` alongside pandoc and pandoc-crossref.
- File discovery runs `git ls-files --cached --others --exclude-standard` in a repository, and `git check-ignore` for `--stdin-filename`. That costs no library and about 40 lines, and gives git's own rules rather than a reimplementation.

## wasm builds

Two WASI command modules, both released (usage in [Configuration and CLI](../guide/configuration.md#wasm-builds)):

- `panblack.wasm`: the CLI, the same `app/Main.hs`. `-j` formats one file at a time, since the wasm RTS has no threads.
- `panblack-lite.wasm`: the editor build. Its options are parsed by the CLI's config code, so the same settings format the same way, and `scripts/build-wasm.sh` checks this. It never calls `targetByName`, so pandoc's writer registry isn't linked, and the other readers and writers are dropped at link time. pandoc's markdown writer imports the HTML writer itself (for tables markdown can't express), so leaving out the `html` check would make it no smaller: there is one tier. The guard is never dropped: a failure makes the editor skip formatting and show a diagnostic. Target use is format on save, so latency needs to be interactive, not per keystroke.
- Sizes after `wasm-opt -Oz`: lite 24 MB (6.3 MB gzipped), the full CLI 36 MB (10 MB gzipped). The native CLI is 120 MB: native code is larger than wasm after `-Oz`, which also drops the debug name section (62 MB for lite before it; `-O2` and `-Os` give 37 MB).

Spike results (plan step 1, GHC 9.12.4 wasm backend):

- Stock Hackage pandoc 3.12.1 builds for wasm; no fork, so the exact version pin holds. The output is byte-identical to the native build.
- Size: 24.7 MB after `wasm-opt -Oz`, 6.2 MB gzipped. The full pandoc.org `pandoc.wasm` is 59 MB. The `md` and `md+html` tiers came out the same size, and building every package with `split-sections` changed nothing: the linker already drops unreachable code, and what is left is reachable. Most of it is static data (13 MB); among named code the largest are texmath, emojis and commonmark, all used by the markdown reader and writer. Going smaller would need changes in pandoc.
- Latency on a 321-line document: 0.16 s under wasmtime (precompiled); under node, 38 ms to compile, 245 ms for the first run, then about 175 ms. A one-line file takes 0.01 s.
- The host must pass a program name in `argv`; with an empty `argv` the GHC runtime exits with code 71.

Toolchain: [ghc-wasm-meta](https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta), installed as in [pandoc-wasm's CI](https://github.com/haskell-wasm/pandoc-wasm/blob/master/.github/workflows/build.yml) (download the archive, `FLAVOUR=9.12 ./setup.sh`), plus native `alex` and `happy`. `cabal.project.wasm` mirrors the `if arch(wasm32)` block of pandoc 3.12.1's own `cabal.project`: pandoc with `-http +embed_data_files`, and five patched dependencies whose patches are copied from pandoc's `wasm/patches` into `haskell/wasm/patches`. (The older pandoc-wasm fork, `haskell-wasm/pandoc`, is stale and not needed.)

## Checks render with pandoc's defaults

A check renders with pandoc's defaults for its target, with the template `$meta-json$` + `$body$` and no wrapping (`Panblack.Target.Html.targetOptions`), not with the profile's options as 0.x did. The rationale is in [What a check renders](../guide/philosophy.md#what-a-check-renders). The golden run confirms that the accept/reject decisions agree with 0.x's on all 1128 files under three settings.

## Notebooks

Cell-level formatting (`Panblack.Notebook`) is settled: the fallback, a whole-notebook pandoc round trip as in 0.x, isn't needed. The rationale and behaviour are in [How a notebook is formatted](../guide/notebooks.md#how-a-notebook-is-formatted). Implementation notes:

- The JSON is parsed with aeson (already a pandoc dependency) to find the cells, and a small scanner over the original bytes finds where each markdown cell's `source` is, so the new sources can be spliced in and every other byte kept.
- The whole-notebook check (for notebooks paired with markdown) is implemented in panblack rather than through pandoc's ipynb reader, so the reader and writer always agree on the markdown flavour.
- `Panblack.Jupytext` mirrors jupytext's `paired_paths`, except for prefix roots and pairings set only in a jupytext config file (reading those would need a TOML parser).

## Cache

`Panblack.Cache` (behaviour in [Configuration and CLI](../guide/configuration.md#cache)):

- Each profile has a cache file, `$XDG_CACHE_HOME/panblack/KEY.json`, mapping each file's absolute path to the SHA-256 of its content. `KEY` is a digest of the panblack and pandoc versions, the config directory, and the profile with its resolved pandoc settings.
- An unreadable cache is empty, and the file is replaced atomically. Concurrent runs may lose each other's new entries, which only costs a recheck.
- Measured: 20 copies of a large document with the `panblack init` settings take 2.2 s at `-j1` and 0.00 s cached; the same with a hook that takes 0.2 s, 1.8 s at `-j4` and 0.00 s cached. pandoc 3.10.2's 1090 small `test/command` files take 0.14 s either way, so there the cache doesn't matter.
- Runs are already fast (0.06 s for one notebook, 0.5 s for 137, of which about 0.04 s is start-up), so a daemon wouldn't buy much: the cost worth saving is re-running hooks such as jupytext and ruff, and large documents, on files that haven't changed. Watching files is left to tools such as `watchexec`.

# Formatter options

The options a profile may set ([Options](../guide/markdown.md#options)) were taken from pandoc 3.10.2's source, and still hold for 3.12.1: the `ReaderOptions` fields that the Markdown and CommonMark readers use, and the `WriterOptions` fields that the Markdown writer uses. `pandoc:` is parsed by pandoc's own defaults-file parser after checking its keys, which is why the config needs no parsing dependency beyond the `yaml` package pandoc already uses.

| Format | Table extensions (`+` on by default) |
|---|---|
| `markdown` | `+simple_tables +multiline_tables +grid_tables +pipe_tables +table_captions +table_attributes` |
| `commonmark` | `-pipe_tables` |
| `commonmark_x` | `+pipe_tables` |
| `gfm` | `+pipe_tables` |

The CommonMark family has only pipe tables, so most of [Tables](#tables) concerns `markdown` only.

# Recommended defaults: the evidence

The recommended settings and the reasons for each are in [Formatting markdown](../guide/markdown.md#formatting-a-source-not-writing-markdown). The runs behind them, on the corpus described in [Stability of the candidate defaults](#stability-of-the-candidate-defaults), at 72 columns with widths reset:

| `from` | `to` (writer tables) | wrap | html | settled after 1 round | never settles | written files stable after 1 round |
|---|---|---|---|---|---|---|
| grid + pipe | grid + pipe | `preserve` | **22/30** | 29/30 | 0 | **22/22** |
| all | grid + pipe | `preserve` | 20/30 | 27/30 | 0 | 20/20 |
| all | grid + pipe | `auto` | 22/30 | 29/30 | 1 | 22/22 |
| all | grid only | `preserve` | 22/30 | 26/30 | 0 | 18/22 |
| all | grid only | `auto` | 22/30 | 29/30 | 1 | 22/22 |
| all | pipe only | `preserve` | 16/30 | 18/30 | 0 | 16/16 |
| all | pipe only | `auto` | 18/30 | 20/30 | 1 | 18/18 |

- **Eight html failures are common to every row.** They are writer losses unrelated to tables (see the other writer losses in [Stability of the candidate defaults](#stability-of-the-candidate-defaults)), so 22/30 is the most any table setting can reach here.
- **`wrap: auto`** can loop forever on the escape problem. It happened in this corpus at 72 and 100 columns, and one of the two alternating versions can even render different html.
- **Pipe tables only** lose every table that needs a grid table (block content, multi-line cells).

With the normalizations added and `smart` off, the same settings give **html 30/32 and 32/32 settled after one round**, on the corpus plus two new grid tables (one with a wrapped cell, one with block content in a cell). The two remaining failures are example lists and `#.` lists ([Known limitations](../guide/markdown.md#known-limitations)), plus a link bug ([upstream issue 6](#upstream-issues)) in the same file. On the golden corpus, the normalizations raise the accepted files from 694 to 887 of 1128 (pandoc 3.12.1).

Further notes behind the recommendations:

- **`smart`:** on the corpus, every file accepted without `smart` also renders the same html when read *with* `smart`.
- **`latex_macros`:** on the corpus it changes nothing, because its macros are all in code blocks.
- **`raw_attribute`** (before `Panblack.Raw`, which now turns it off in the writer itself; see [Raw content](#raw-content-the-evidence)): without it in `to`, `INSTALL.md` is accepted and no file gains `{=...}`. A raw block or span for a format the markdown writer can't write natively, such as `{=typst}`, is then dropped, and the guard only sees it if a check renders that format: with `check: [source, html, latex]` such a file is accepted with the raw content deleted, while `check: [source, html, typst]` rejects it. The happy case assumes raw attributes only for TeX and HTML (see the [open question](#open-questions)).
- **`#.` lists:** a normalization that writes `#.` as `1.` works (30/32 becomes 31/32 on the corpus), but it isn't invisible: in LaTeX, a nested `#.` list gets LaTeX's own second-level label `(a)`, and after the normalization it gets `1.`. So it stays out of the defaults until the writer is fixed; it could be offered as an opt-in normalization.
- **Example lists:** the `example_lists` extension stays on. The writer never produces example lists, and turning the extension off would silently make existing ones plain text.

# Tables

Tables are where pandoc as a formatter hurts most (summary in [Formatting markdown](../guide/markdown.md#tables)). pandoc's table AST stores relative column widths. The reader derives them from the source, using the dash counts and scaling when a line is longer than `columns`; otherwise it stores none. The writer then picks a table syntax (simple, multiline, grid, pipe) based on the widths and on which extensions are enabled, and the new source reads back with different widths or alignment. This design doc was an example: pandoc rewrote its pipe tables as simple tables. That made the alignment explicitly left and changed the widths, so the `html` check failed, and the widths shifted again on every run, so `source` failed too.

## Findings (plan step 1b)

The experiment is `haskell/experiments/Tables.hs`. It runs 12 tables (each syntax, alignment, long lines, inline markup, block content in cells, and this doc's two tables) × every combination of disabled table extensions × `columns` 40/72/100/120/200, with checks `[source, html]`.

- **Default `markdown` accepts 14 of 60 runs.** The main cause is a writer limitation: a simple table can't express *default* alignment when a header is shorter than its column. The writer pads the header, the reader then sees it flush left, and the column becomes `AlignLeft`. Every pipe table without explicit alignment hits this, since the writer prefers simple tables. A known pandoc limitation: the four syntaxes are interchangeable, and there is no way to fix the syntax for one table.
- **Disabling extensions in `from` is the wrong knob.** `from` sets the reader too, so with pipe tables only, a simple or grid table in the source is read as a paragraph. The guard accepts that, because it is the same under that reader, but the user's own pandoc run (plain `markdown`) reads a table there.
- **So the writer gets its own extensions:** `pandoc.to`, defaulting to `from`. It must be the same markdown flavour as `from`, and only its extensions may differ.
- **Pipe tables only (`to: markdown-simple_tables-multiline_tables-grid_tables`), widths kept.** This was the best setting that keeps widths. It accepts 44 of 60 runs, and every pipe and simple table is written as a pipe table. The failures are grid and multiline tables (rejected, so left untouched), plus one known limitation: the writer can pad a pipe table past `columns`, and on re-reading the table gets widths it didn't have. Superseded by the recommended defaults, which reset widths.
- Keeping grid tables (`to: markdown-simple_tables-multiline_tables`) accepts 46 of 60 runs, but pipe tables then fail at narrow widths, because the writer switches to grid tables.
- **What each syntax can express** (pandoc 3.10.2 manual and reader): grid tables are the most capable. They have block content, row and column spans, alignment, a foot and headerless tables. Pipe tables have none of the first four and no multi-line cells. The exception is widths: grid and multiline tables *always* get widths on reading, computed from the dash lengths relative to `columns`. Only pipe tables (with no line longer than `columns`) and simple tables can have none.
- **Resetting widths** means setting every column's width to default in the AST right after reading, on both the original and the formatted source. Then width can't cause a mismatch, and grid tables can express everything. With `to:` grid tables only (`markdown-simple_tables-multiline_tables-pipe_tables`), every run passes the `html` check at every `columns`. The html check then doesn't depend on `columns` at all: the reader only uses it to compute widths, which are reset, and checks render without wrapping. The rest (8 of 60) fail only `source`. When cell text doesn't fit in `columns`, the grid writer wraps it, `--wrap=preserve` keeps that wrap as a line break, and the next run lays the table out differently once more. In every case, including this doc at 72 and 120, the second run reaches a fixed point.
- **Why it's still not free:**
    - Resetting only happens inside panblack. The user's own pandoc run still reads widths: this doc's pipe table goes from 50/50 to 20/79, and a table with no widths gains some, since a grid table always has them. So this doesn't hold the pandoc-relative guarantee for widths, which is why it is a named normalization, `table-widths`.
    - A large `columns` is not a fix. It changes what is written, since `columns` is the markdown writer's line length (tables in this doc grow to 194 characters, and in general a cell never wraps). The failing check is `source`, which by definition reruns the formatter with the same options, so it can't use a different `columns` from the output.
- **When pipe tables are written with widths reset**, a multiline table's multi-line cells go into a pipe table, and with `--wrap=preserve` the line breaks are written inside the pipe row. That breaks the table, so it reads back as a paragraph. This is a writer bug ([upstream issue 1](#upstream-issues)): pipe cells can't contain newlines. The `table-cell-breaks` normalization works around it.
- `columns` also sets the reader's columns, as with the pandoc CLI. The reader uses them to decide whether a table gets relative widths.

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
- **Multi-line cells written as a pipe table with `wrap: preserve`**: the line breaks go inside the pipe row and break the table (see [Tables](#tables)). With `wrap: auto` they become spaces, so this doesn't happen.
- **Other writer losses, not about tables** (the guard rejects these files, which is the design working):
    - trailing blank lines of a code block inside a grid cell are dropped;
    - example lists (`(@)`, `(@foo)`) are written as `(1)`, so they become ordinary lists;
    - `smart` inserts a non-breaking space in `[p. 30]` inside a citation;
    - one list numbering style in pandoc's `testsuite` (`<ol>` becomes `<ol type="1">`).

Two rounds are not always enough with widths kept: some documents take 3 or 5. With widths reset and `wrap: preserve`, every document is fixed after round 2 at every width. With widths reset and `wrap: auto`, almost every document is fixed after round 1; only the escape oscillation remains.

# Normalizations

The normalizations and what each changes are in [Formatting markdown](../guide/markdown.md#normalizations). Implementation: `Panblack.Normalize`. Its output matches the Lua prototype (`haskell/experiments/normalize.lua`) byte for byte on the 24 documents of the stability corpus.

Potential problems considered for the table-cell normalization: a cell with a paragraph followed by a list and a code block, one with a hard line break (`\`), and one with inline math and a code span that wrap across lines. These are all in `haskell/experiments/tables/grid_blocks_wrapped.md`, which passes both checks. Hard breaks are a different element and are kept. The `east_asian_line_breaks` extension removes its line breaks while reading, so it doesn't interact.

# Raw content: the evidence {#raw-content-the-evidence}

The user-facing side is [Advanced: raw content](../guide/markdown.md#raw-content). Implementation: `Panblack.Raw`, which wraps a profile's writer after the normalizations wrap its reader, so `auto` reads back exactly as the guard does.

**The problem.** pandoc markdown has a native and an attribute syntax for raw HTML and TeX, the reader maps both to the same `RawBlock`/`RawInline`, and the writer picks one syntax per kind of element from the `to` extensions: inlines prefer the attribute form, blocks the native one ([upstream issue 10](#upstream-issues)). No `to` setting keeps both styles as typed. Tried first, each with its own flaw:

| Setting | Flaw |
|---|---|
| `to: …-raw_attribute` (the old recommendation, as `raw: pandoc` still does) | raw content for formats without a native syntax (`{=typst}`) is dropped, and accepted unless a check renders that format |
| `to:` with `raw_attribute` (pandoc's default) | typed inline HTML and TeX are rewritten as `` `…`{=html} ``; raw blocks are still written natively |
| `to: …-raw_html-raw_tex` | everything typed natively is rewritten, comments included |
| `from: …-raw_attribute` | the reader no longer parses the attribute form: fences become inline code, and the guard, reading both sides the same way, accepts it. The only setting that damages what every output shows. |

**The mechanism.** The writer copies a raw element of format `markdown` out verbatim (`nest 0` keeps its blank lines), in both the markdown and the CommonMark variant. So panblack can choose the syntax per element: an element to be written in the attribute form becomes a raw `markdown` element holding `` `…`{=fmt} `` or a fenced block followed by a blank line. Unless `raw: pandoc`, panblack also turns `raw_attribute` off in the writer (`rawWriterSpec`): with it on, the writer puts every raw inline in the attribute form itself. So `to` needs no raw setting, and the recommended config has no `to` at all; on both corpora, under every `raw:` setting and both flavours, the output is byte-identical to the old recommendation's `to: …-raw_attribute`. The fence is one backtick longer than the longest run in the content, at least 3 for blocks.

**The policies, measured** with checks `[source, html, latex]`, the recommended settings, `--no-cache -j1`, on the golden corpus (1128 files) and Quarto's documentation (552 pages), read as pandoc markdown and as `commonmark_x-smart` (neither is written for CommonMark, so the second is a stress test). Quarto's with the current build:

| Flavour | `raw:` | pandoc corpus accepted | time | Quarto accepted | time | native elements rewritten (Quarto) |
|---|---|---|---|---|---|---|
| markdown | `native` | 887 | 4.7 s | 510 | 5.0 s | 0 |
| markdown | `attribute` | 883 | 8.1 s | 516 | 4.7 s | 226 |
| markdown | `auto` | 887 | 5.9 s | 516 | 5.2 s | 0 |
| commonmark_x | `native` | 886 | 7.8 s | 512 | 4.0 s | 1 |
| commonmark_x | `attribute` | 886 | 8.0 s | 513 | 3.9 s | 222 |
| commonmark_x | `auto` | 886 | 11.1 s | 513 | 4.2 s | 1 |

- `auto` accepts every file `native` does, with the same output except in 3 files, where it keeps an `{=html}` inline as typed. It accepts 6 more pages, all with `{=html}` or `{=tex}` blocks that, written natively, read back as something else: an `<iframe>` inside a div is split in two, a `<div>` opens a div.
- On pandoc markdown, the fixed rules of `native` (below) don't recover those 6. Telling an HTML fragment that reads back as something else from one that doesn't takes a reread.
- In CommonMark, native HTML blocks end at a blank line, which the writer puts after them, so they read back intact, and `native` is enough. The one rule it needs: the writer removes blank lines inside a native HTML block (`removeBlankLinesInHTML`), so a block that contains one goes in the attribute form.
- The one native element `native` and `auto` rewrite in CommonMark is an HTML block holding a blank line (the rule below).
- The slowest file is pandoc's 1.3 MB `changelog.md` read as `commonmark_x`: 9.6 s with `auto`, 5.7 s with `native`.

**Rules every policy but `attribute` and `pandoc` applies**, as they need no reread: formats the writer has no native syntax for; `latex` elements (native TeX reads as `tex`, so a `latex` element was typed in the attribute form; HTML has no such tell); TeX whose `\begin`/`\end` don't balance; in CommonMark, HTML blocks containing a blank line.

**`auto`'s rounds.** Each round writes the file, reads it back, aligns the raw elements read back with the original ones as `diff` aligns lines (the `Diff` library, already used for `--diff`), and switches every original element without a match to the attribute form. One round fixes all the elements that fail on their own; a second is needed only when fixing one exposes another, e.g. a TeX block that had swallowed it. Rounds needed: 19 files took one and none took more on pandoc's corpus as pandoc markdown; on Quarto's pages 70 took one and 15 two as pandoc markdown, 81 and 7 as `commonmark_x`; a file with 400 `{=html}` fragments took two, in 0.07 s. The limit is 10 rounds, then every raw block in the attribute form, then everything.

**Rejected designs:**

- Testing each element alone (write it, read it back alone): no faster on these corpora (7.6 s on pandoc's corpus), since every raw inline is tested, and it misses context, such as a TeX environment swallowing the next paragraph.
- One fallback straight to every raw block in the attribute form: the same acceptance as `auto`, but it also rewrites the native blocks that read back fine, in every file that needs any fixed.
- Fixing the first differing element per round, the first version of `auto`: the same output on Quarto's pages, but one whole-file round per element, so a file with many fragments costs quadratic time (pandoc's changelog as `commonmark_x`: 43 s), and a cap on rounds then trades faithfulness for time (on Quarto's pages, a cap of 2 rewrote 18 native elements, 4 and 8 none).

**Default `native`**: the corpus results are those of the old recommendation, at no cost, and raw content is no longer dropped silently. `auto` is opt-in because of its cost and because only pandoc markdown needs it. `pandoc` reproduces 0.x: on the golden corpus with `normalize: []`, `raw: pandoc` gives files byte-identical to the build before `Panblack.Raw` under all three golden settings; `golden/run.sh` uses it.

The examples are tests in `haskell/test/Spec.hs`.

# Upstream issues

Found with pandoc 3.10.2, each with a minimal reproduction, as candidates for issues and patches. Rechecked with pandoc 3.12.1: all but 7 still reproduce. 9 and 10 were found later, on 3.12.1. Known limitations that are *not* listed: the alignment of simple tables, pipe tables padded past `columns`, and bare text in divs.

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

7. **Fixed in pandoc 3.12 ([jgm/pandoc#11927](https://github.com/jgm/pandoc/issues/11927)).** **The commonmark writer drops the parentheses in `\\(...\\)`** (found on notebooks written for MathJax). The text is read correctly, as `Str "\\(a\\)"`, but written without the parentheses, so it reads back as `\a\`:

    ```
    $ printf '%s\n' 'x \\(a\\) y' | pandoc -f gfm -t gfm   # x \\a\\ y
    ```

8. **The commonmark writer drops the info string `text`**, so the `text` class is lost (`<pre class="text">` becomes `<pre>`). Other languages are kept.

    ```
    $ printf '```text\nx\n```\n' | pandoc -f gfm -t gfm       # ```
    ```

9. **An empty div is dropped.** A div with no content, such as the `::: {#refs}` placeholder that says where citeproc puts the bibliography, isn't written at all, so it reads back as nothing. Checked with pandoc 3.10.2 and 3.12.1.

    ```
    $ printf 'Text.\n\n::: {#refs}\n:::\n' | pandoc -t markdown    # Text.
    ```

10. **Raw HTML and TeX blocks are written natively, even when that reads back as something else.** The markdown writer chooses the syntax for raw content differently for inlines and blocks. A `RawInline` is written in the attribute form whenever `raw_attribute` is on (`Writers/Markdown/Inline.hs`, `RawInline` case), but a `RawBlock` of HTML or TeX is written natively whenever `raw_html` / `raw_tex` is on, and uses the attribute form only otherwise (`Writers/Markdown.hs`, `blockToMarkdown'`, `RawBlock` case). Native is only safe for a fragment that reads back as the same block, and fragments are exactly what a raw block selected per output format holds. Here an unbalanced `\begin` is written natively, and read back as one TeX block that swallows the paragraph, so it disappears from the html:

    ````
    $ cat up10.md
    ```{=latex}
    \begin{flushright}
    ```

    Text.

    ```{=latex}
    \end{flushright}
    ```
    $ pandoc -t markdown up10.md | pandoc -t native
    [ RawBlock (Format "tex") "\\begin{flushright}\n\nText.\n\n\\end{flushright}" ]
    $ pandoc -t markdown up10.md | pandoc -t html     # (nothing; was <p>Text.</p>)
    ````

    HTML fragments fail the same way: `<div style="...">` written natively reads back as the start of a div. Natively written blocks are also not separated by a blank line, so an HTML block and a TeX block run together. Proposal: write a `RawBlock` in the attribute form whenever `raw_attribute` is on, as for inlines; or, more conservatively, whenever the native form doesn't read back as the same block. Found with [these examples](../guide/markdown.md#raw-content); panblack rejects such files rather than damaging them, so they are never formatted.

# Versioning

The rules are in [Development](development.md#versioning). Why the pandoc version is not in the version number (for example `3.10.2-1.0`):

- Hackage versions are dot-separated integers only. A `-` suffix is not a valid version, and PVP gives no way to mark part of the version as someone else's.
- Putting pandoc's version first (`3.10.2.1.0`) would make pandoc's `3.10` panblack's PVP major version, so a panblack-only breaking change could not be expressed as a major bump.
- The Haskell norm for tools built on pandoc is an independent version with the pandoc version in the release notes, as pandoc-crossref does.
- conda-forge also expects the package version to be the upstream project's own version; packaging rebuilds use the build number instead.

Why pinning matters: 0.x uses whatever pandoc is on `PATH`. Running it with pandoc 3.10.2 reformatted this repository's `CHANGELOG.md` from `-   item` to `- item`, a style change caused only by the pandoc version.

Style changes from a pandoc bump are an output change rather than an API change, but they get their own `A.B` bump anyway, so the rule "a patch release never changes output" holds.

# Distribution

panblack 1.0 is distributed in two ways:

- **Binaries** through the pandoc-forge feedstock and GitHub releases. This is what users install.
- **Source** on Hackage, so `cabal install panblack` works and `panblack-core` can be used as a library. This isn't strictly required for the binaries (the feedstock can build from a GitHub tarball), but it's the convention for Haskell tools. The name `panblack` is currently free on Hackage.

0.x was never published to PyPI or conda-forge; users install it from the git repository. So its final release is a git tag, `v0.2.0` on `main`, with `panblack export-config` and a deprecation notice ([Migrating from 0.x](../guide/migration.md)). This way the Haskell binary never needs a TOML parser.

# Licence

GPL-2.0-or-later, as pandoc, laid out as pandoc does: `COPYRIGHT` holds the notice and the exceptions, `COPYING.md` the licence text (the cabal package in `haskell/` links to both). pandoc is GPL-2.0-or-later and every panblack binary bundles it, so distributed binaries were covered by the GPL anyway; with the source under the same licence there is no split, and the repository can include pandoc-derived material. 0.x keeps BSD-3: its releases, `v0.2.0` the last, are tagged on `main`, and the move to the GPL comes with the rewrite. The exception is `haskell/wasm/patches`, MIT, copied from pandoc.

Test corpora come from pandoc itself (the markdown files under `test/`, and `MANUAL.txt`). They are taken at test time from the pinned pandoc source (`cabal get pandoc-3.12.1`), not copied into the repository. That keeps them in step with the pinned version whatever the licence. Some measurements also use Quarto's documentation, the `.qmd` pages of [quarto-web](https://github.com/quarto-dev/quarto-web) at commit `ecf8316` (renamed to `.md`, flattened into one directory), as a public corpus written for pandoc but never formatted by its writer. Quarto's own syntax isn't pandoc's: the writer escapes shortcodes (`{{< include x.md >}}` becomes `{{\< include x.md \>}}`), which pandoc's own output doesn't show, so these pages test the guard, not formatting Quarto projects.

# Plan

0. Get 0.x running locally against a recent pandoc, as a reference *oracle* for parity tests. No release. **Done** (see [the 0.x oracle](development.md#the-0.x-oracle)).
1. Spike: `panblack-core` markdown-only on the GHC wasm backend, plus size and latency numbers. This decides the wasm tiers. **Done** (see [wasm builds](#wasm-builds)).
    - 1b. Tables (see [Tables](#tables)), in parallel with the spike. **Done.**
2. Core and CLI for markdown: guard, config, `--check`/`--diff`. Golden tests against the 0.x oracle on real corpora, with both using the same pandoc version.
    - CLI, config and normalizations: **done**. With no normalizations, the output is byte-identical to the pandoc CLI (what 0.x runs) for every formatter option on four documents (pandoc's `testsuite.txt`, `markdown-reader-more.txt` and `MANUAL.txt`, and this doc), for `markdown`, `gfm` and `commonmark_x`. With all of them on, it is byte-identical to pandoc with the Lua prototype on the 24-document corpus.
    - Golden tests: **done**, `haskell/golden/run.sh` (see [Development](development.md#the-golden-test)). Every file comes out byte-identical, except that 0.x drops the final newline. The accept/reject decisions agree too. The golden run found two differences, both fixed: the pandoc CLI expands tabs before reading, and it takes `smart`'s abbreviations from a data file.
3. ipynb: pair detection and cell-level formatting, plus hooks. **Done** (see [Formatting notebooks](../guide/notebooks.md)). Tested on 137 real notebooks and end to end with jupytext and ruff. This showed that formatting the text side of a pair needs `jupytext --update` rather than `--sync`, and no jupytext YAML header.
4. Settle the open questions, then freeze the config schema.
    - A cache, as black has: **done** (see [Cache](#cache)).
5. Python `v0.2.0` tag: `export-config` and the deprecation notice. **Done**, tagged on `main`; the Python code is removed from `main` after it. Tested on a real 0.x config (three profiles, one for notebooks): the exported config loads in 1.0, formats, and settles.
6. panblack 1.0: Hackage (see [Development](development.md#releasing)), feedstock packaging, binaries, pre-commit hook. Migrate the dependent projects.
    - Binaries: **done**, built by CI for every platform and attached to GitHub releases.
7. The wasm build and the editor integration.
    - wasm build: **done**, `panblack.wasm` and `panblack-lite.wasm` (see [wasm builds](#wasm-builds)).
    - Editor integration: not started.

# Open questions

Each question has a provisional choice that the implementation builds on; the evidence settles it before the config schema is frozen (plan step 4). Only the config-shape questions affect migration.

| Question | Provisional choice | Settled by |
|---|---|---|
| Normalizations: option names, defaults, how to turn them off | settled: a `normalize:` list, all on by default (author's decision, 2026-10-23), `[]` for none; see [Normalizations](../guide/markdown.md#normalizations) | done |
| How raw content is written back, given that the AST doesn't record which syntax was typed | settled: `raw: native` by default, `attribute` and `auto` opt-in, `pandoc` for 0.x (see [Raw content: the evidence](#raw-content-the-evidence)) | done |
| ipynb: partial formatting and the whole-notebook check (see [How a notebook is formatted](../guide/notebooks.md#how-a-notebook-is-formatted)). Three things to revisit: a notebook paired with a markdown file that nothing renders as one document (e.g. kept only for diffs) is still rejected for footnotes numbered across cells, which may call for `ipynb.whole-notebook-check: never`; without the check, a cell holding only a link reference definition becomes empty, which is faithful per cell but deletes what the author wrote, so it might be rejected instead; and a partly reformatted file exits 2 on every run until its kept cells are fixed by hand | per cell, keep rejected cells; whole-notebook check only when paired with markdown | usage |
| AST normalization before comparing (speed only) | settled: not adopted; with `wrap: preserve` nearly every accepted file takes the fast path, and with `wrap: auto` a soft-break-insensitive comparison saves up to a third of the first run at the cost of coupling the guard to writer options (see [Guard algorithm](#guard-algorithm)) | golden corpus and Quarto's docs, done |
| Default table settings | grid and pipe tables only, `wrap: preserve`, widths reset (see [Formatting markdown](../guide/markdown.md#only-grid-and-pipe-tables)) | step 2 corpora |
| wasm tiers | settled: one tier, `md+html` | spike (step 1), done |
| `excludes` regex or globs, and `.gitignore` | settled: gitignore-style globs, on top of git's own list of files | author, done |
| ipynb: cell-level or whole-notebook round trip | settled: cell-level | step 3, done |
| Hooks or pre-commit only | settled: hooks; pre-commit can still chain the tools instead | author, done |
| Licence: GPL-2.0-or-later (like pandoc and pandoc-crossref) or keep BSD-3 | settled: GPL-2.0-or-later; see [Licence](#licence) | author, done |
| Config filename and discovery | settled: `.panblack.yaml`, walk up to the repository root | author, done |
