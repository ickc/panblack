# panblack

A black-like formatter for pandoc users: it formats markdown and notebooks with pandoc, and writes a file only if pandoc renders it the same before and after.

panblack 1.0 is a rewrite in Haskell, in progress; see [the design doc](docs/design.md). The Python 0.x is in the history, tagged; its last release, [`v0.2.0`](https://github.com/ickc/panblack/tree/v0.2.0), has `panblack export-config` to migrate a config to 1.0.

Licensed under GPL-2.0-or-later; see [COPYRIGHT](COPYRIGHT).
