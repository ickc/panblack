"""A panflute filter that process ipynb inputs."""

from __future__ import annotations

from dataclasses import dataclass, field
from difflib import unified_diff
from functools import cached_property
from itertools import chain
from pathlib import Path
from typing import Optional, Sequence

import defopt
import psutil
import tomlkit
from map_parallel import map_parallel
from panflute.tools import convert_text

from .util import setup_logging

logger = setup_logging()
__version__ = "0.1.0"


@dataclass
class MarkdownFormatter:
    path: Path
    pandoc_args: list[str] = field(default_factory=list)
    pandoc_path: Optional[Path] = None
    input_format: str = "markdown"
    require_idempotent_native: bool = False
    require_idempotent_markdown: bool = True

    @cached_property
    def text(self) -> str:
        logger.debug("Reading from %s", self.path)
        with self.path.open("r") as f:
            return f.read()

    def to_native(self, text: str) -> str:
        return convert_text(
            text,
            input_format=self.input_format,
            output_format="native",
            standalone=True,
            extra_args=self.pandoc_args,
            pandoc_path=self.pandoc_path,
        )

    @cached_property
    def native(self) -> str:
        return self.to_native(self.text)

    def to_markdown(self, text: str) -> str:
        return convert_text(
            text,
            input_format="native",
            output_format=self.input_format,
            standalone=True,
            extra_args=self.pandoc_args,
            pandoc_path=self.pandoc_path,
        )

    @cached_property
    def markdown(self) -> str:
        return self.to_markdown(self.native)

    @cached_property
    def is_idempotent(self) -> bool:
        if self.require_idempotent_native:
            native_round_trip = self.to_native(self.markdown)
            res = self.native == native_round_trip
            if not res:
                logger.debug("File is not idempotent at %s", self.path)
                for line in unified_diff(self.native.split(), native_round_trip.split()):
                    logger.debug(line)
            return res
        if self.require_idempotent_markdown:
            markdown_round_trip = self.to_markdown(self.to_native(self.markdown))
            res = self.markdown == markdown_round_trip
            if not res:
                logger.debug("File is not idempotent at %s", self.path)
                for line in unified_diff(self.markdown.split(), markdown_round_trip.split()):
                    logger.debug(line)
            return res
        return True

    def write(self) -> None:
        if self.is_idempotent:
            logger.info("Overwritting %s", self.path)
            with self.path.open("w") as f:
                f.write(self.markdown)


@dataclass
class Options:
    """Panblack formatter.

    TODO: read from config files.
    """

    path: Path
    save: bool = False
    toml_path: Path = Path("pyproject.toml")
    excludes: Sequence[str] = (".git/**", ".pytest_cache/**")
    exts: Sequence[str] = (".md", ".markdown")
    processes: Optional[int] = None
    # to MarkdownFormatter
    pandoc_args: list[str] = field(default_factory=list)
    pandoc_path: Optional[Path] = None
    input_format: str = "markdown"
    require_idempotent_native: bool = False
    require_idempotent_markdown: bool = True

    @property
    def dict(self) -> dict:
        return {key: str(value) if isinstance(value, Path) else value for key, value in vars(self).items()}

    @property
    def paths(self) -> list[Path]:
        path = self.path
        exts = self.exts
        excludes = self.excludes

        if path.is_dir():
            res = [
                p
                for p in chain(*[path.glob(f"**/*{ext}") for ext in self.exts])
                if not any(p.match(exclude) for exclude in excludes)
            ]
            # res = [p for p in path.iterdir() if p.suffix in exts and not any(p.match(exclude) for exclude in excludes)]
            logger.debug(res)
            logger.info("Found %s markdown files.", len(res))
            return res
        else:
            return [path]

    def to_toml(self):
        """Dump self to a toml file."""
        toml_path = self.toml_path
        if toml_path.exists():
            with open(toml_path, "r") as f:
                config = tomlkit.parse(f.read())
        else:
            config = {}
        config[__name__] = self.dict
        with open(self.toml_path, "w") as f:
            f.write(tomlkit.dumps(config))

    def exec(self):
        pandoc_args = self.pandoc_args
        pandoc_path = self.pandoc_path
        input_format = self.input_format
        require_idempotent_native = self.require_idempotent_native
        require_idempotent_markdown = self.require_idempotent_markdown

        def write(path):
            formatter = MarkdownFormatter(
                path,
                pandoc_args=pandoc_args,
                pandoc_path=pandoc_path,
                input_format=input_format,
                require_idempotent_native=require_idempotent_native,
                require_idempotent_markdown=require_idempotent_markdown,
            )
            logger.info("Processing %s", path)
            formatter.write()

        if self.save:
            self.to_toml()

        processes = self.processes or psutil.cpu_count(logical=False)

        map_parallel(write, self.paths, processes=processes, mode="multithreading", return_results=False)


def cli():
    options = defopt.run(
        Options,
        strict_kwonly=False,
        show_types=True,
        no_negated_flags=True,
        version=True,
    )
    options.exec()


if __name__ == "__main__":
    cli()
