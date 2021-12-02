"""A panflute filter that process ipynb inputs."""

from __future__ import annotations

import os
from logging import getLogger
from typing import TYPE_CHECKING
from dataclasses import dataclass

import defopt
from panflute.elements import CodeBlock, Div, Doc, Para, RawBlock
from panflute.io import run_filters
from panflute.tools import convert_text

from .util import setup_logging

if TYPE_CHECKING:
    from typing import Any, Callable, Optional, Union

    from panflute.base import Element

logger = setup_logging()


def main():
    pass


def cli():
    defopt.run(main)


if __name__ == "__main__":
    cli()
