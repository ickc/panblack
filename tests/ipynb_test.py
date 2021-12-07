from __future__ import annotations

from pathlib import Path
from unittest import TestCase
import json

from panblack import MarkdownFormatter

DIR = Path(__file__).parent / "ipynb"

class TestMarkdownFormatter(TestCase):

    def setUp(self):
        self.path = path = DIR / "example_1.ipynb"

        self.cases = {
            (del_jupytext_encoding, post_jupytext_sync):
            MarkdownFormatter(
                path,
                input_format="ipynb",
                require_idempotence_format=("ipynb",),
                del_jupytext_encoding=del_jupytext_encoding,
                post_jupytext_sync=post_jupytext_sync,
            )
            for del_jupytext_encoding in (False, True)
            for post_jupytext_sync in (False, True)
        }

    def test_is_ipynb(self) -> None:
        for i in self.cases.values():
            assert i.is_ipynb

    def test_del_jupytext_encoding(self):
        del_jupytext_encoding = True
        for post_jupytext_sync in (False, True):
            f = self.cases[(del_jupytext_encoding, post_jupytext_sync)]
            text = f.text
            assert "encoding" not in json.loads(text)["metadata"]["jupytext"]
