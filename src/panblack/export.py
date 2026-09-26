"""Export a 0.x config to panblack 1.0's ``.panblack.yaml``.

See "Migration from 0.x" in panblack 1.0's design doc (docs/design.md in https://github.com/ickc/panblack).
"""

from __future__ import annotations

import json
import re
import subprocess  # nosec
from pathlib import Path
from typing import Dict, List, Optional

# pandoc options that 1.0 accepts in a profile's ``pandoc:`` key, with how to
# read their value from the command line.
PANDOC_OPTIONS = {
    "wrap": str,
    "columns": int,
    "tab-stop": int,
    "indented-code-classes": lambda v: v.split(","),
    "abbreviations": str,
    "markdown-headings": str,
    "reference-location": str,
    "eol": str,
}
PANDOC_FLAGS = ("reference-links", "ascii")

# A regex that is a literal name, with ``.`` or ``\.`` as a literal dot.
LITERAL = re.compile(r"(?:[\w-]|\\?\.)+")

RUFF_HOOK = ["jupytext", "--sync", "--pipe", "ruff check --select I --fix-only -", "--pipe", "ruff format -", "{path}"]


class ExportError(Exception):
    pass


def pandoc_options(args: List[str], notes: List[str]) -> Dict[str, object]:
    """Translate 0.x's ``pandoc_args`` to the keys of a pandoc defaults file."""
    res: Dict[str, object] = {}
    it = iter(args)
    for arg in it:
        name, eq, value = arg[2:].partition("=") if arg.startswith("--") else (arg, "", "")
        if name == "sandbox":
            continue
        if name == "atx-headers":
            res["markdown-headings"] = "atx"
        elif name in PANDOC_FLAGS:
            res[name] = not eq or value == "true"
        elif name in PANDOC_OPTIONS or name == "ipynb-output":
            if not eq:
                value = next(it, None)
                if value is None:
                    raise ExportError(f"pandoc_args: {arg} needs a value")
            if name == "ipynb-output":
                notes.append(f"{arg} dropped: 1.0 formats markdown cells only and never changes outputs")
            else:
                res[name] = PANDOC_OPTIONS[name](value)
        else:
            raise ExportError(
                f"pandoc_args: 1.0 doesn't support {arg}; it accepts --{', --'.join((*PANDOC_OPTIONS, *PANDOC_FLAGS))}"
                " (see the Formatter options in panblack 1.0's docs/design.md)"
            )
    return res


def glob_exclude(regex: str) -> str:
    """Translate an exclude regex that is a literal name, as 0.x matched it anywhere in the path, to a glob."""
    is_dir = regex.endswith("/")
    name = regex[:-1] if is_dir else regex
    if not LITERAL.fullmatch(name):
        raise ExportError(f"excludes: can't translate the regex {regex!r} to a glob; change it to a plain name first")
    name = name.replace("\\.", ".")
    # "name/" matched a directory whose name ends with name, "name" a name containing it
    return f"*{name}/" if is_dir else f"*{name}*"


def list_extensions(pandoc: str, format: str) -> Dict[str, bool]:
    try:
        out = subprocess.run([pandoc, f"--list-extensions={format}"], capture_output=True, text=True, check=True)  # nosec
    except (OSError, subprocess.CalledProcessError) as e:
        raise ExportError(f"can't list pandoc's extensions for {format}: {e}") from e
    return {line[1:]: line[0] == "+" for line in out.stdout.split()}


def cell_format(input_format: str, pandoc: str) -> str:
    """The markdown flavour that pandoc's ipynb reader used for markdown cells, relative to ``markdown``.

    The ``ipynb`` format has its own extensions (close to GFM), which pandoc's markdown reader and
    writer use for the cells.
    """
    m = re.fullmatch(r"ipynb((?:[+-]\w+)*)", input_format)
    if m is None:
        raise ExportError(f"input_format: can't read {input_format!r}")
    exts = list_extensions(pandoc, "ipynb")
    for sign, name in re.findall(r"([+-])(\w+)", m.group(1)):
        exts[name] = sign == "+"
    markdown = list_extensions(pandoc, "markdown")
    return "markdown" + "".join(
        ("+" if on else "-") + name for name, on in sorted(exts.items()) if name in markdown and markdown[name] != on
    )


def export_profile(options, notes: List[str]) -> Dict[str, object]:
    """A 1.0 profile from a 0.x one, as ``Options`` (so with 0.x's defaults filled in)."""
    profile: Dict[str, object] = {
        "paths": [str(path) for path in options.paths],
        "exts": list(options.exts),
        "excludes": [glob_exclude(regex) for regex in options.excludes],
        # the "input_format" entry was resolved to input_format; "" skipped the check
        "check": ["source" if f == options.input_format else f for f in options.require_idempotence_format if f],
        # 0.x had no normalizations
        "normalize": [],
    }
    pandoc = pandoc_options(list(options.pandoc_args), notes)
    if options.pandoc_path is not None:
        notes.append("pandoc_path dropped: 1.0 bundles pandoc")
    if options.is_ipynb:
        if options.del_jupytext_encoding:
            notes.append("del_jupytext_encoding dropped: 1.0 never changes notebook metadata")
        profile["pandoc"] = pandoc
        profile["ipynb"] = {"cell-format": cell_format(options.input_format, str(options.pandoc_path or "pandoc"))}
        if options.post_jupytext_sync:
            args = [str(arg) for arg in options.jupytext_args]
            profile["hooks"] = [["jupytext", "--sync", *args, "{path}"]]
            if any("black" in arg or "isort" in arg for arg in args):
                notes.append(f"hooks: black and isort kept; ruff would be {json.dumps(RUFF_HOOK)}")
    else:
        profile["pandoc"] = {"from": options.input_format, **pandoc}
    return profile


def to_yaml(profiles: List[Dict[str, object]], source: Path) -> str:
    """Write the profiles as YAML, with JSON (which YAML reads) for the values."""

    def value(v: object) -> str:
        return json.dumps(v, ensure_ascii=False)

    lines = [
        f"# Exported from {source} by panblack 0.2.0 export-config.",
        "# normalize: [] keeps 0.x's output; remove it to get 1.0's default normalizations.",
    ]
    for profile in profiles:
        for i, (key, v) in enumerate(profile.items()):
            prefix = f"{'- ' if i == 0 else '  '}{key}:"
            if isinstance(v, dict):
                lines += [prefix] + [f"    {k}: {value(x)}" for k, x in v.items()]
            elif key == "hooks":
                lines += [prefix] + [f"    - {value(hook)}" for hook in v]  # type: ignore[attr-defined]
            else:
                lines.append(f"{prefix} {value(v)}")
    return "\n".join(lines) + "\n"


def export(toml_config: List[dict], source: Path, notes: List[str]) -> str:
    from . import Options

    profiles = []
    for i, dict_ in enumerate(toml_config, 1):
        profile_notes: List[str] = []
        try:
            profiles.append(export_profile(Options.from_dict(**dict_), profile_notes))
        except (ExportError, TypeError) as e:
            raise ExportError(f"profile {i}: {e}") from e
        notes += [f"profile {i}: {note}" for note in profile_notes]
    return to_yaml(profiles, source)


def write(text: str, output: Optional[Path]) -> None:
    if output is None:
        print(text, end="")
    else:
        try:
            with output.open("x", encoding="utf-8") as f:
                f.write(text)
        except FileExistsError as e:
            raise ExportError(f"{output} exists; remove it, or use --output") from e
