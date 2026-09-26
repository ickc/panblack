#!/usr/bin/env bash
# Golden test: panblack 1.0 against the 0.x oracle on pandoc's own markdown.
#
# usage: golden/run.sh PANBLACK ORACLE WORKDIR
#   PANBLACK  the 1.0 binary (cabal list-bin exe:panblack)
#   ORACLE    the 0.x entry point (the panblack of the 0.x branch, see docs/design.md)
#   WORKDIR   scratch directory; the pandoc source is fetched into it
#
# Both use the pandoc on PATH for 0.x, which must be the pinned version.
# For each setting, 0.x and 1.0 format separate copies of the corpus, with
# no normalizations (0.x has none), and the resulting files are compared.
set -euo pipefail
PB=$(realpath "$1"); ORACLE=$(realpath "$2"); W=$(realpath -m "$3")
pinned=$("$PB" --version | sed -n 's/.*(pandoc \(.*\))/\1/p')
[[ $(pandoc --version | head -1) == "pandoc $pinned" ]] || { echo "pandoc on PATH is not $pinned" >&2; exit 3; }
mkdir -p "$W"; cd "$W"
[[ -d pandoc-$pinned ]] || cabal get "pandoc-$pinned" >/dev/null
src=pandoc-$pinned
rm -rf corpus && mkdir corpus
for f in "$src"/MANUAL.txt "$src"/*.md "$src"/test/{testsuite,markdown-reader-more,markdown-citations,pipe-tables}.txt \
         "$src"/test/lhs-test.markdown "$src"/test/command/*.md; do
  rel=${f#"$src"/}; cp "$f" "corpus/${rel//\//__}.md"
done
echo "corpus: $(ls corpus | wc -l) files"

# name | 0.x --pandoc-args | 0.x -r | 1.0 pandoc: keys | 1.0 check
settings=(
  "default||input_format|{}|[source]"
  "default+html||input_format html|{}|[source, html]"
  "preserve+html|--wrap=preserve --columns=120 --reference-location=block|input_format html|{wrap: preserve, columns: 120, reference-location: block}|[source, html]"
)
for s in "${settings[@]}"; do
  IFS='|' read -r name args checks0 pandoc1 checks1 <<<"$s"
  rm -rf "$name" && mkdir -p "$name" && cp -r corpus "$name/old" && cp -r corpus "$name/new"
  (cd "$name/old" && "$ORACLE" --paths . -r $checks0 --pandoc-args "$args" -t none.toml --no-post-jupytext-sync >../old.log 2>&1 || true)
  printf -- '- paths: [.]\n  check: %s\n  normalize: []\n  pandoc: %s\n' "$checks1" "$pandoc1" > "$name/new/.panblack.yaml"
  (cd "$name/new" && "$PB" --no-cache >../new.log 2>&1 || true)
  python3 - "$name" <<'PY'
import sys, pathlib, collections
name = sys.argv[1]; d = pathlib.Path(name)
counts = collections.Counter(); rows = []
for orig in sorted(pathlib.Path("corpus").iterdir()):
    o = orig.read_bytes(); a = (d/"old"/orig.name).read_bytes(); b = (d/"new"/orig.name).read_bytes()
    oc, nc = ("changed" if a != o else "same"), ("changed" if b != o else "same")
    # 0.x strips pandoc's output (panflute's convert_text), so it writes no
    # final newline; that is its bug, not a style to mirror.
    if a != o and a + b"\n" == b: counts["identical but 0.x's final newline"] += 1
    elif a == b: counts["identical"] += 1
    else:
        counts[f"differ: 0.x {oc}, 1.0 {nc}"] += 1; rows.append(f"{orig.name}\t0.x {oc}\t1.0 {nc}")
(d/"differ.tsv").write_text("\n".join(rows) + "\n")
print(f"{name}: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
PY
done
