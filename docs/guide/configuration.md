---
title: Configuration and CLI
description: The .panblack.yaml config, which files panblack formats, hooks, the command line, the cache, and the wasm builds.
---

# The config file

The config is `.panblack.yaml`, searched from the working directory upwards, stopping at the repository root (the directory containing `.git`). It holds a list of *profiles*. Each file is formatted by the one profile whose `paths`, `exts` and `excludes` cover it.

```yaml
- paths: [pages, README.md]
  exts: [md]
  excludes: []
  check: [source, html]    # all must pass; default [source]
  normalize: [table-widths, table-cell-breaks]   # default all; [] for none
  pandoc:                  # an inline pandoc defaults file
    from: markdown-simple_tables-multiline_tables-smart-latex_macros+east_asian_line_breaks
    to: markdown-simple_tables-multiline_tables-smart-latex_macros+east_asian_line_breaks-raw_attribute
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
  ipynb:
    cell-format: gfm-tex_math_gfm    # the default
  hooks:
    - [jupytext, --sync, --pipe, 'ruff check --select I --fix-only -', --pipe, 'ruff format -', '{path}']
```

| Key | Meaning | Default |
|---|---|---|
| `paths` | files and directories, relative to the config file | `[]` |
| `exts` | extensions of the files to take from a directory | `[md, markdown]` |
| `excludes` | gitignore-style globs (see [Which files](#which-files)) | `[.git/, .pytest_cache/]` |
| `check` | the checks, all of which must pass (see [Core philosophy](philosophy.md#several-targets-at-once)) | `[source]` |
| `normalize` | the normalizations (see [Formatting markdown](markdown.md#normalizations)) | all of them |
| `pandoc` | an inline pandoc defaults file, restricted to formatter options (see [Options](markdown.md#options)) | pandoc's defaults |
| `defaults` | a pandoc defaults file, relative to the config file, with the same restriction. The inline `pandoc:` keys override it. It can't include further defaults files. | none |
| `ipynb.cell-format` | the markdown flavour of notebook cells (see [Formatting notebooks](notebooks.md#markdown-flavour-of-the-cells)) | `gfm-tex_math_gfm` |
| `hooks` | commands run on each accepted file (see [Hooks](#hooks)) | `[]` |

- An unknown key anywhere is an error, and so is a `pandoc:` option that isn't a formatter option.
- `abbreviations` (for `smart`) is relative to the config file. Without it, the reader's abbreviations come from pandoc's own `abbreviations` data file, as with pandoc's CLI.
- A file is a notebook if its extension is `.ipynb`, whatever the profile.
- A file matched by two profiles is an error.
- Without a config file, `panblack PATH...` uses one profile with the defaults above on the given paths.
- `panblack init` prints the [recommended settings for markdown](markdown.md#quick-start).

# Which files

- **In a git repository, git decides which files a listed directory has**: tracked files, and the untracked ones git doesn't ignore (by `.gitignore` files at any level, `.git/info/exclude` and the global excludes file). A tracked file is included even if a `.gitignore` matches it, as for git. Without git, or outside a repository, the directory is walked and only `excludes` apply.
- **`excludes`** are gitignore-style globs, applied on top of git's list, or while walking. A trailing `/` matches directories only, a pattern with another `/` is anchored at the config directory, any other pattern matches a name at any depth, and a wildcard matches a leading dot.
- A file listed in `paths` itself is always included.
- Input is read as pandoc's CLI reads it: a byte-order mark and carriage returns are removed, and tabs are expanded. So a CRLF file is rewritten with LF under the default `eol: native` on Unix; set `eol: crlf` to keep CRLF.

# Hooks

`hooks:` is a list of commands (argv lists), run in order in the config directory on each accepted file, whether it was changed or already formatted. `{path}` is replaced by the file's path relative to the config directory. Hooks run after panblack writes the file, so a tool such as jupytext sees it as the newest side of a pair.

- The first hook that fails stops the rest and gives exit code 3, with its output. A missing executable is reported as `command not found`.
- Hooks don't run for rejected files, with `--check` or `--diff` (which report panblack's own changes only), with stdin, or in the wasm build.
- panblack's guard doesn't apply to hooks. The tools they run carry their own guarantee (see [Delegating to purpose-built tools](philosophy.md#delegating-to-purpose-built-tools)), and a code formatter intends to change code, which any check would see.

# Command line

```
panblack [PATH...]          # format in place using .panblack.yaml profiles
  --check                   # write nothing; exit 1 if any file would change
  --diff                    # write nothing; print a unified diff
  --config FILE
  -j N                      # files formatted in parallel; default: number of CPUs
  --no-cache                # format every file; neither read nor update the cache
  -v                        # list unchanged files; show the check renders that differ
panblack - [--stdin-filename PATH]   # stdin to stdout
panblack init               # print a starter .panblack.yaml
panblack --version          # includes the bundled pandoc version
```

- `PATH...` selects among the files the profiles cover: those at or below the given paths. A named file that no profile covers is skipped with a note, so a pre-commit hook can pass every changed file.
- Reports go to stderr, one line per file (`reformatted`, `would reformat`, `partly reformatted` for notebooks, `rejected`, `error`) and a summary. Diffs go to stdout.
- With `-`, the profile is the only one, or the one covering `--stdin-filename`. The formatted source is written to stdout. If it is rejected, the input is written back unchanged (exit 2), so a pipe never loses the document.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | `--check` found files that would change |
| 2 | a file was rejected by its checks, or partly reformatted |
| 3 | an error in usage, config or IO, or a failed hook |

With several files, the highest code wins. A rejection is never downgraded to a warning.

# Cache

As black does, panblack skips files it has already accepted.

- A file whose content is unchanged since panblack last accepted it, under the same settings, is reported `unchanged`, without being read by pandoc or running its hooks.
- The settings are everything else the result depends on: the panblack and pandoc versions, the config directory, and the profile with its resolved pandoc settings (so the contents of a `defaults:` or `abbreviations` file count too). Changing any of them starts a new cache.
- A file is recorded only when running panblack on it again would change nothing and report nothing: it was accepted (unchanged or reformatted), not partly reformatted, with no warning and no failed hook, and its hooks left it as panblack wrote it. A hook that changes the file (jupytext with ruff does, for code cells) means it is checked once more on the next run, and recorded then. Rejected files are never recorded, so they are reported on every run.
- `--check` and `--diff` read the cache, and record only files that are unchanged and have no hooks, since they don't run hooks.
- Not covered: the versions of the tools that hooks run, and the other side of a jupytext pair. After upgrading ruff, say, run with `--no-cache` once.
- The cache lives in `$XDG_CACHE_HOME/panblack/`. Reading or writing it never fails a run.

# wasm builds

Two WASI modules are released next to the native binaries:

- **`panblack.wasm`** is the CLI, e.g. `wasmtime run --dir . panblack.wasm --check`, with the same config. WASI can't start processes, so hooks are skipped with a warning naming them, for you or the host to run, and files with hooks are then not cached. `-j` formats one file at a time. The cache needs a writable directory from the host (`--dir cache::/cache --env XDG_CACHE_HOME=/cache`); without one, nothing is cached.
- **`panblack-lite.wasm`** is the build for editors: stdin to stdout, with one profile given as options: `--check` (`source` or `html`; default `source`), `--normalize` (default all), and every `pandoc:` key as an option (`--wrap=preserve --columns=72`). These go through the CLI's own config code, so the same settings format the same way. There is no config file, and no paths, cache, notebooks or hooks. Exit codes are as for the CLI's stdin mode: 0 formatted, 2 rejected, 3 error, and the input is passed through unless it was formatted, so an editor can skip formatting and show a diagnostic. It takes about 0.2 s on a 300-line document, fine for format on save.

The host must pass a program name in `argv`: with an empty `argv` the GHC runtime exits with code 71.
