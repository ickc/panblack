from __future__ import annotations

from pathlib import Path
from unittest import TestCase

from panblack import CliOptions

DIR = Path(__file__).parent.parent


class TestMarkdownFormatter(TestCase):
    def setUp(self):
        self.path = Path(DIR / "example.toml")
        self.out_path = Path(DIR / "example.out.toml")
        self.cli_options = CliOptions(
            paths=[Path(".")],
            excludes=["src/panblack/templates/template.md"],
        )

    def test_integration(self):
        self.cli_options.exec()
