from __future__ import annotations

from pathlib import Path

from panblack import CliOptions

DIR = Path(__file__).parent.parent


def test_integration():
    cli_options = CliOptions(
        paths=[DIR],
        excludes=["src/panblack/templates/template.md"],
    )
    cli_options.exec()


def test_integration_ipynb():
    cli_options = CliOptions(
        paths=[DIR / Path("tests/ipynb/example_1.ipynb")],
        exts=[".ipynb"],
        input_format="ipynb",
    )
    cli_options.exec()
