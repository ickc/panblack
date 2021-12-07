"""A panflute filter that process ipynb inputs."""

from __future__ import annotations

import json
from concurrent import futures
from dataclasses import dataclass, field
from difflib import unified_diff
from functools import cached_property
from itertools import chain
from pathlib import Path
from subprocess import list2cmdline  # nosec
from typing import ClassVar, List, Optional, Sequence

import defopt
import psutil
import tomlkit
from custom_inherit import DocInheritMeta
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
EXECUTOR: dict[str, futures.Executor] = {
    "multithreading": futures.ThreadPoolExecutor,  # type: ignore[dict-item] # mypy limitation
    "multiprocessing": futures.ProcessPoolExecutor,  # type: ignore[dict-item] # mypy limitation
}


@dataclass
class RequirePath:
    """Require positional path via MRO.

    Args:
        path: input path.
    """

    path: Path


@dataclass
class CoreOptions(metaclass=DocInheritMeta(style="google_with_merge")):  # type: ignore[misc] # type-checker limitation
    """Core options needed throughout.

    Args:
        pandoc_path: path to pandoc executable.
        input_format: the input format (can include extensions.)
        require_idempotence_format: the formats to require the formatter to be idempotent. For each format, if "input_format", same as input_format, if "", skip checking, else check with the specified format.
        del_jupytext_encoding: if True and if input_format starts with ipynb, jupytext encoding will be deleted in metadata.
        post_jupytext_sync: run jupytext after panblack with args: --sync --pipe black --pipe 'isort - --treat-comment-as-code "# %%" --float-to-top'
    """

    pandoc_path: Optional[Path] = None
    input_format: str = "markdown"
    require_idempotence_format: Sequence[str] = ("input_format",)
    del_jupytext_encoding: bool = True
    post_jupytext_sync: bool = True

    @cached_property
    def is_markdown(self) -> bool:
        return self.input_format.startswith("markdown")

    @cached_property
    def is_ipynb(self) -> bool:
        return self.input_format.startswith("ipynb")


@dataclass
class MarkdownFormatter(CoreOptions, RequirePath):
    """Markdown formatter using pandoc.

    Args:
        pandoc_args: additional args passes to pandoc.
        auto_write: run write automatically at init.
    """

    pandoc_args: List[str] = field(default_factory=list)
    auto_write: bool = False

    def __post_init__(self) -> None:
        if self.auto_write:
            self.write()

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
                logger.info("Running post jupytext sync: jupytext %s", list2cmdline(args))
                jupytext(args=args)


@dataclass
class CommonOptions(CoreOptions):
    """Common options for panblack formatter.

    Args:
        paths: input paths.
        exts: the file extensions to glob from each path if it is a directory.
        excludes: the patterns to be excluded in globbing.
    """

    paths: List[Path] = field(default_factory=list)
    exts: Sequence[str] = (".md", ".markdown")
    excludes: Sequence[str] = (".git/**", ".pytest_cache/**")

    @classmethod
    def from_dict(cls, **options) -> Options:
        kwargs = {key: [Path(path) for path in value] if key == "paths" else value for key, value in options.items()}
        return cls(**kwargs)  # type: ignore[return-value] # mypy limitation

    @property
    def all_paths(self) -> List[Path]:
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


@dataclass
class Options(CommonOptions):
    """Panblack formatter.

    Args:
        pandoc_args: additional args passes to pandoc.
    """

    pandoc_args: List[str] = field(default_factory=list)

    def __post_init__(self) -> None:
        self.require_idempotence_format = [
            self.input_format if f == "input_format" else f for f in self.require_idempotence_format
        ]

    @property
    def options_dict(self) -> dict:
        return {
            "input_format": self.input_format,
            "require_idempotence_format": self.require_idempotence_format,
            "del_jupytext_encoding": self.del_jupytext_encoding,
            "post_jupytext_sync": self.post_jupytext_sync,
            "paths": [str(path) for path in self.paths],
            "exts": self.exts,
            "excludes": self.excludes,
            "pandoc_args": self.pandoc_args,
        }

    def exec(
        self,
        executor: futures.Executor,
    ) -> List[futures.Future]:
        pandoc_args = [f"--template={TEMPLATE}"] + self.pandoc_args if self.is_markdown else self.pandoc_args
        pandoc_path = self.pandoc_path
        input_format = self.input_format
        require_idempotence_format = self.require_idempotence_format
        del_jupytext_encoding = self.del_jupytext_encoding
        post_jupytext_sync = self.post_jupytext_sync

        logger.info(
            "Running %s --standalone --from=%s %s ...",
            "pandoc" if pandoc_path is None else pandoc_path,
            self.input_format,
            list2cmdline(pandoc_args),
        )

        return [
            executor.submit(
                MarkdownFormatter,
                path,
                pandoc_args=pandoc_args,
                pandoc_path=pandoc_path,
                input_format=input_format,
                require_idempotence_format=require_idempotence_format,
                del_jupytext_encoding=del_jupytext_encoding,
                post_jupytext_sync=post_jupytext_sync,
                auto_write=True,
            )
            for path in self.all_paths
        ]


@dataclass
class CliOptions(CommonOptions):
    """Panblack formatter.

    Args:
        pandoc_args: additional args passes to pandoc, white-space-delimited.
        processes: the no. of concurrent processes, if not specified, default to no. of physical cores.
        mode: the mode to run concorrently, can be multithreading, multiprocessing.
        save: write current cli config into toml config.
        save_append: if specified, append to current toml config when saving.
        save_only: if save and save_only, only perform save to toml config and exit.
        toml_path: path towards the toml file containing the config. If tool.panblack keys exists, it has higher priority than cli options.
    """

    pandoc_args: str = ""
    processes: Optional[int] = None
    mode: str = "multiprocessing"
    save: bool = False
    save_append: bool = False
    save_only: bool = True
    toml_path: Path = Path("pyproject.toml")
    toml_key: ClassVar[str] = f"tool.{__name__}"

    @property
    def options_dict(self) -> dict:
        return {
            "pandoc_path": self.pandoc_path,
            "input_format": self.input_format,
            "require_idempotence_format": self.require_idempotence_format,
            "del_jupytext_encoding": self.del_jupytext_encoding,
            "post_jupytext_sync": self.post_jupytext_sync,
            "paths": self.paths,
            "exts": self.exts,
            "excludes": self.excludes,
            "pandoc_args": self.pandoc_args.split(),
        }

    @property
    def options(self) -> Options:
        return Options(**self.options_dict)

    @cached_property
    def toml(self) -> dict:
        toml_path = self.toml_path
        if toml_path.exists():
            try:
                with toml_path.open("r") as f:
                    return tomlkit.parse(f.read())  # type: ignore[return-value] # TOMLDocument is dict-like
            except Exception as e:
                logger.warning("Trouble parsing %s: %s", toml_path, e)
        return {}

    @property
    def has_toml_config(self) -> bool:
        return self.toml_key in self.toml

    @property
    def toml_config(self) -> List[dict]:
        return self.toml[self.toml_key] if self.has_toml_config else {}

    def write_toml(self, **data) -> None:
        """Dump self to a toml file."""
        config = self.toml
        config[self.toml_key] = (
            config[self.toml_key] + [data] if self.save_append and self.toml_key in config else [data]
        )
        with open(self.toml_path, "w") as f:
            f.write(tomlkit.dumps(config))  # type: ignore[arg-type] # TOMLDocument is dict-like

    def exec(self) -> None:
        processes = self.processes or psutil.cpu_count(logical=False)
        with EXECUTOR[self.mode](max_workers=processes) as executor:  # type: ignore[operator] # mypy limitation
            # use CliOptions
            fs: List[futures.Future] = []
            if self.save or not self.has_toml_config:
                logger.info("Using command line options")
                options = self.options
                if self.save:
                    self.write_toml(**options.options_dict)
                if not (self.save and self.save_only):
                    fs += options.exec(executor)
            # use options from toml
            else:
                logger.info("Using toml options from %s, %s", self.toml_key, self.toml_path)
                options_dict = self.options_dict
                for dict_ in self.toml_config:
                    # options = Options.from_dict(**(options_dict | dict_))  # py39+
                    options = Options.from_dict(**{**options_dict, **dict_})
                    fs += options.exec(executor)
            for f in fs:
                try:
                    f.result()
                except Exception as e:
                    logger.warning(e)
            logger.info("Finished processing %s files.", len(fs))


def cli():
    cli_options: CliOptions = defopt.run(
        CliOptions,
        strict_kwonly=False,
        show_types=True,
        no_negated_flags=True,
        version=True,
    )
    cli_options.exec()


if __name__ == "__main__":
    cli()
