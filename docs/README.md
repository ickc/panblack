---
title: panblack---black-like formatter for pandoc users.
---

``` table
---
header: false
markdown: true
include: badges.csv
...
```

# Introduction

Kind of like black, an opinionated formatter powered by pandoc including formats like markdown, ipynb, etc.

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
One could check the AST is "idempotent" (i.e. the formatted markdown produces the same AST.)

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

``` bash
panblack --paths .
```

Or configure it via `pyproject.toml`.

See `panblack -h` for details.

You can also experiments with the cli flags to your liking,
and when you want to write it to the config file `pyproject.toml`,
use the flag `--save`, and optionally `--save-append` if you want to have multiple configurations
running concurrently.

# Note on ipynb

Note that while panblack supports ipynb formats,
I personally use it together with [pannb](https://github.com/ickc/pannb)
that treats the ipynb as input format in pandoc.
If you use other processor that reads from ipynb,
such as `nbconvert`,
you may find it not idempotent as it is processed by something other than pandoc after all.

# Example config

The following TOML is some examples:

``` toml
[["tool.panblack"]]
input_format = "markdown-raw_attribute-latex_macros+east_asian_line_breaks+autolink_bare_uris"
require_idempotence_format = ["html"]
paths = ["pages", "README.md"]
exts = ["md"]
excludes = []
pandoc_args = ["--sandbox", "--wrap=preserve", "--columns=120", "--reference-location=block"]

[["tool.panblack"]]
paths = ["src"]
exts = ["ipynb"]
excludes = [".ipynb_checkpoints/"]
# modified from
# pandoc --list-extensions=markdown | tr -d '\n'
# to mimics markdown-raw_attribute-latex_macros+east_asian_line_breaks+autolink_bare_uris
input_format = "ipynb-abbreviations+all_symbols_escapable-angle_brackets_escapable-ascii_identifiers+auto_identifiers+autolink_bare_uris+backtick_code_blocks+blank_before_blockquote+blank_before_header+bracketed_spans+citations-compact_definition_lists+definition_lists+east_asian_line_breaks-emoji+escaped_line_breaks+example_lists+fancy_lists+fenced_code_attributes+fenced_code_blocks+fenced_divs+footnotes-four_space_rule-gfm_auto_identifiers+grid_tables-gutenberg-hard_line_breaks+header_attributes-ignore_line_breaks+implicit_figures+implicit_header_references+inline_code_attributes+inline_notes+intraword_underscores-latex_macros+line_blocks+link_attributes-lists_without_preceding_blankline-literate_haskell-markdown_attribute+markdown_in_html_blocks-mmd_header_identifiers-mmd_link_attributes-mmd_title_block+multiline_tables+native_divs+native_spans-old_dashes+pandoc_title_block+pipe_tables-raw_attribute+raw_html+raw_tex-rebase_relative_paths-short_subsuperscripts+shortcut_reference_links+simple_tables+smart+space_in_atx_header-spaced_reference_links+startnum+strikeout+subscript+superscript+task_lists+table_captions+tex_math_dollars-tex_math_double_backslash-tex_math_single_backslash+yaml_metadata_block"
require_idempotence_format = ["html"]
pandoc_args = ["--sandbox", "--wrap=preserve", "--columns=120", "--reference-location=block", "--ipynb-output=all"]

[["tool.panblack"]]
paths = ["posts"]
exts = ["md"]
excludes = []
input_format = "markdown-raw_attribute-latex_macros+east_asian_line_breaks+autolink_bare_uris"
require_idempotence_format = ["html", "latex"]
pandoc_args = ["--sandbox", "--wrap=preserve", "--columns=120", "--reference-location=block"]
```