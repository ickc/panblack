from __future__ import annotations

import json
from pathlib import Path
from unittest import TestCase

from panblack import CliOptions

DIR = Path(__file__).parent


class TestMarkdownFormatter(TestCase):
    def setUp(self):
        self.path = Path(DIR / "example.toml")
        self.out_path = Path(DIR / "example.out.toml")
        self.cli_options = CliOptions(
            paths=[Path("pages"), Path("posts"), Path("README.md")],
            exts=[".md"],
            excludes=[],
            input_format="markdown-raw_attribute-latex_macros+east_asian_line_breaks+autolink_bare_uris",
            require_idempotence_format=["html"],
            pandoc_args="--sandbox --wrap=preserve --columns=120 --reference-location=block",
            save=True,
            save_only=True,
            save_append=True,
            toml_path=self.out_path,
        )

    def test_save(self):
        cli_options = self.cli_options
        cli_options.exec()
        with self.out_path.open() as f:
            out = f.read().strip()
        with self.path.open() as f:
            ref = f.read().strip()
        self.out_path.unlink()
        assert out == ref

    def test_load(self):
        cli_options = CliOptions(toml_path=self.path)
        assert cli_options.toml_config
