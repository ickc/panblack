from __future__ import annotations

from pathlib import Path

import pytest
import tomlkit

from panblack.export import ExportError, export, glob_exclude

DIR = Path(__file__).parent


def export_toml(text: str) -> tuple[str, list[str]]:
    notes: list[str] = []
    return export(tomlkit.parse(text)["tool.panblack"], Path("pyproject.toml"), notes), notes


def test_markdown():
    with (DIR / "example.toml").open() as f:
        out, notes = export_toml(f.read())
    assert out.endswith(
        """- paths: ["pages", "posts", "README.md"]
  exts: ["md"]
  excludes: []
  check: ["html"]
  normalize: []
  pandoc:
    from: "markdown-raw_attribute-latex_macros+east_asian_line_breaks+autolink_bare_uris"
    wrap: "preserve"
    columns: 120
    reference-location: "block"
"""
    )
    assert notes == []


def test_defaults():
    out, _ = export_toml('[["tool.panblack"]]\npaths = ["."]\n')
    assert out.endswith(
        """- paths: ["."]
  exts: ["md", "markdown"]
  excludes: ["*.git/", "*.pytest_cache/"]
  check: ["source"]
  normalize: []
  pandoc:
    from: "markdown"
"""
    )


def test_ipynb():
    out, notes = export_toml(
        """[["tool.panblack"]]
paths = ["src"]
exts = ["ipynb"]
input_format = "ipynb+smart"
require_idempotence_format = ["input_format", "", "html"]
pandoc_args = ["--wrap", "none", "--ipynb-output=all"]
jupytext_args = ["--pipe", "black"]
"""
    )
    # ipynb's own extensions (close to GFM), relative to markdown
    assert '    cell-format: "markdown+autolink_bare_uris-' in out
    assert "+smart" not in out and "-smart" not in out
    assert '  check: ["source", "html"]\n' in out
    assert '    wrap: "none"\n' in out
    assert '    - ["jupytext", "--sync", "--pipe", "black", "{path}"]\n' in out
    assert [note.split(":")[1] for note in notes] == [" --ipynb-output=all dropped", " del_jupytext_encoding dropped", " hooks"]


def test_excludes():
    assert glob_exclude(".ipynb_checkpoints/") == "*.ipynb_checkpoints/"
    assert glob_exclude(r"\.draft") == "*.draft*"
    with pytest.raises(ExportError):
        glob_exclude(".git/*")


@pytest.mark.parametrize(
    "line",
    [
        'pandoc_args = ["--standalone"]',
        'pandoc_args = ["--columns"]',
        'pandoc_path_typo = "pandoc"',
    ],
)
def test_errors(line):
    with pytest.raises(ExportError):
        export_toml(f'[["tool.panblack"]]\n{line}\n')
