| Setting | Description |
|---|---|
| `excludes` | Gitignore-style globs of paths to skip, relative to the config file; `.gitignore` is always respected as well, so most projects need nothing here. |
| `hooks` | Commands to run after a file is written, in order, with `{path}` substituted; a missing executable is an error with a non-zero exit code. |
