from __future__ import annotations

from pathlib import Path

from panblack import GlobPath

DIR = Path(__file__).parent.parent


def test_exclude():
    g = GlobPath([DIR], exts=("sample",), excludes=[])
    assert len(list(g.all_paths)) > 0


def test_exclude_2():
    g = GlobPath([DIR], exts=("sample",), excludes=(".git/*",))
    assert len(list(g.all_paths)) == 0
