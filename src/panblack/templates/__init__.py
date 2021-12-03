from __future__ import annotations

from importlib import resources
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from pathlib import Path

with resources.path(__package__, "template.md") as path:
    TEMPLATE: Path = path
