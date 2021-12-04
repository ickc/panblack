"""A panflute filter that process ipynb inputs."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from difflib import unified_diff
from functools import cached_property
from itertools import chain
from pathlib import Path
from typing import Optional, Sequence

import defopt
import psutil
import tomlkit
from custom_inherit import DocInheritMeta
from map_parallel import map_parallel
from panflute.tools import convert_text

from .templates import TEMPLATE
from .util import setup_logging

logger = setup_logging()
__version__ = "0.1.0"

JUPYTEXT_ARGS = [
    "--sync",
    "--pipe",
    "black",
    "--pipe",
    'isort - --treat-comment-as-code "# %%" --float-to-top',
]


@dataclass
class CoreOptions(metaclass=DocInheritMeta(style="google_with_merge")):  # type: ignore[misc] # type-checker limitation
    """Core options needed throughout.

    Args:
        path: input path.
        pandoc_path: path to pandoc executable.
        input_format: the input format (can include extensions.)
        require_idempotence_format: the formats to require the formatter to be idempotent. For each format, if "input_format", same as input_format, if "", skip checking, else check with the specified format.
        del_jupytext_encoding: if True and if input_format starts with ipynb, jupytext encoding will be deleted in metadata.
        post_jupytext_sync: run jupytext after panblack with args: --sync --pipe black --pipe 'isort - --treat-comment-as-code "# %%" --float-to-top'
    """

    path: Path
    pandoc_path: Optional[Path] = None
    input_format: str = "markdown"
    require_idempotence_format: Sequence[str] = ("input_format",)
    del_jupytext_encoding: bool = True
    post_jupytext_sync: bool = True


@dataclass
class MarkdownFormatter(CoreOptions):
    """Markdown formatter using pandoc.

    Args:
        pandoc_args: additional args passes to pandoc.
    """

    pandoc_args: list[str] = field(default_factory=list)

    @cached_property
    def is_ipynb(self) -> bool:
        return self.input_format.startswith("ipynb")

    @cached_property
    def text(self) -> str:
        logger.debug("Reading %s", self.path)
        with self.path.open("r") as f:
            res = f.read()
        if self.del_jupytext_encoding and self.is_ipynb:
            try:
                data = json.loads(res)
                del data["metadata"]["jupytext"]["encoding"]
                res = json.dumps(data)
            except KeyError:
                pass
            except Exception as e:
                logger.warning(
                    "Cannot delete jupytext encoding key in %s with the following exception: %s", self.path, e
                )
        return res

    def convert(
        self,
        text: str,
        input_format: str,
        output_format: str,
    ) -> str:
        return convert_text(
            text,
            input_format=input_format,
            output_format=output_format,
            standalone=True,
            extra_args=self.pandoc_args,
            pandoc_path=self.pandoc_path,
        )

    @cached_property
    def text_converted(self) -> str:
        return self.convert(self.text, self.input_format, self.input_format)

    def check_idempotence(
        self,
        output_format: str,
    ) -> bool:
        ref = self.convert(self.text, self.input_format, output_format).strip()
        round_trip = self.convert(self.text_converted, self.input_format, output_format).strip()

        logger.debug("Checking idempotence to %s", output_format)
        res = ref == round_trip
        if not res:
            logger.warning(
                f"Not idempotent converting to {output_format}, {self.path}\n"
                + "\n".join(line for line in unified_diff(ref.split(), round_trip.split()))
            )
        return res

    @cached_property
    def is_idempotent(self) -> bool:
        return all(self.check_idempotence(f) for f in self.require_idempotence_format)

    def write(self) -> None:
        if self.is_idempotent:
            # make sure reading before writting
            text_converted = self.text_converted
            logger.info("Overwritting %s", self.path)
            with self.path.open("w") as f:
                f.write(text_converted)
            # cannot avoid writing to file first
            # as we need to use the --sync option as well
            if self.post_jupytext_sync and self.is_ipynb:
                from jupytext.cli import jupytext

                args = JUPYTEXT_ARGS + [str(self.path)]
                logger.info("Running post jupytext sync: jupytext %s", " ".join(args))
                jupytext(args=args)


@dataclass
class Options(CoreOptions):
    """Panblack formatter.

    Args:
        paths: additional paths.
        pandoc_args: additional args passes to pandoc, white-space-delimited.
        exts: the file extensions to glob from each path if it is a directory.
        excludes: the patterns to be excluded in globbing.
        processes: the no. of concurrent processes, if not specified, default to no. of physical cores.
        mode: the mode to run concorrently, can be anything map_parallel support including
            multiprocessing, multithreading, dask, mpi, mpi_simple, serial

    Notes:
        TODO: read from config files.
    """

    paths: list[Path] = field(default_factory=list)
    pandoc_args: str = ""
    exts: Sequence[str] = (".md", ".markdown")
    excludes: Sequence[str] = (".git/**", ".pytest_cache/**")
    toml_path: Path = Path("pyproject.toml")
    save: bool = False
    processes: Optional[int] = None
    mode: str = "multithreading"

    def __post_init__(self) -> None:
        self.require_idempotence_format = [
            self.input_format if f == "input_format" else f for f in self.require_idempotence_format
        ]
        self.paths.append(self.path)

    @property
    def dict(self) -> dict:
        return {key: str(value) if isinstance(value, Path) else value for key, value in vars(self).items()}

    @property
    def all_paths(self) -> list[Path]:
        exts = self.exts
        excludes = self.excludes

        all_paths = []
        for path in self.paths:
            if path.is_dir():
                res = [
                    p
                    for p in chain(*[path.glob(f"**/*{ext}") for ext in exts])
                    if not any(p.match(exclude) for exclude in excludes)
                ]
                logger.info("Found %s files from %s.", len(res), path)
                logger.debug(res)
                all_paths += res
            else:
                all_paths.append(path)
        return all_paths

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
        pandoc_args = [f"--template={TEMPLATE}"] + self.pandoc_args.split()
        pandoc_path = self.pandoc_path
        input_format = self.input_format
        require_idempotence_format = self.require_idempotence_format
        del_jupytext_encoding = self.del_jupytext_encoding
        post_jupytext_sync = self.post_jupytext_sync

        logger.info(
            "Running %s --standalone --from=%s %s ...",
            "pandoc" if pandoc_path is None else pandoc_path,
            self.input_format,
            " ".join(pandoc_args),
        )

        def write(path):
            formatter = MarkdownFormatter(
                path,
                pandoc_args=pandoc_args,
                pandoc_path=pandoc_path,
                input_format=input_format,
                require_idempotence_format=require_idempotence_format,
                del_jupytext_encoding=del_jupytext_encoding,
                post_jupytext_sync=post_jupytext_sync,
            )
            formatter.write()

        if self.save:
            self.to_toml()

        processes = self.processes or psutil.cpu_count(logical=False)

        map_parallel(write, self.all_paths, processes=processes, mode=self.mode, return_results=False)


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
