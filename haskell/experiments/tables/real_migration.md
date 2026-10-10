| 0.x (`pyproject.toml`) | 1.0 (`.panblack.yaml`) |
|---|---|
| `input_format` | `pandoc.from`; for ipynb profiles, `ipynb.cell-format` (with the `ipynb` prefix removed) |
| `require_idempotence_format` | `check`, same meaning. The `"input_format"` entry becomes `source`. |
| `paths`, `exts` | unchanged |
| `excludes` (regex) | `excludes` (see [Open questions]) |
| `pandoc_args` | `pandoc:` keys, e.g. `--wrap=preserve` → `wrap: preserve`. `--sandbox` is dropped (always on). Unknown args cause an error with a pointer to the docs. |
| `del_jupytext_encoding` | `ipynb.drop-jupytext-encoding` |
| `post_jupytext_sync`, `jupytext_args` | `hooks: [[jupytext, --sync, ...args, '{path}']]`. `export-config` keeps black/isort pipes as they are and prints the ruff equivalent as a suggestion. |
| `pandoc_path` | removed (pandoc is bundled) |
| `processes`, `mode` | `-j` |
| `toml_path`, `save*` | `--config`, `panblack init` |
