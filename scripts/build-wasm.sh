#!/usr/bin/env bash
# Build the wasm builds and stage them in $1:
#
#   $1/panblack.wasm        the CLI
#   $1/panblack-lite.wasm   the small build for editors
#   $1/COPYING.md, $1/COPYRIGHT
#
# Mirrors pandoc-forge/pandoc-feedstock's scripts/build-wasm.sh. Installs the
# GHC wasm toolchain (ghc-wasm-meta at $GHC_WASM_META_REV, flavour
# $GHC_WASM_FLAVOUR; see pins.env) to $GHC_WASM_PREFIX (default ~/.ghc-wasm)
# unless it is already there. Needs native alex and happy on PATH.
set -euo pipefail

mkdir -p "$1"
out=$(cd "$1" && pwd)
cd "$(dirname "$0")/.."
repo=$PWD
prefix=${GHC_WASM_PREFIX:-$HOME/.ghc-wasm}
stamp="$GHC_WASM_META_REV $GHC_WASM_FLAVOUR"

if [[ $(cat "$prefix/.ghc-wasm-meta-rev" 2>/dev/null) != "$stamp" ]]; then
	tmp=$(mktemp -d)
	curl -fL --retry 5 "https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta/-/archive/$GHC_WASM_META_REV/ghc-wasm-meta-$GHC_WASM_META_REV.tar.gz" |
		tar xz --strip-components=1 -C "$tmp"
	# setup.sh wipes $PREFIX, so keep the cabal store (which may come from
	# the CI cache) out of its way.
	[[ -d $prefix/.cabal ]] && mv "$prefix/.cabal" "$tmp/.cabal-keep"
	(cd "$tmp" && PREFIX="$prefix" FLAVOUR="$GHC_WASM_FLAVOUR" ./setup.sh)
	[[ -d $tmp/.cabal-keep ]] && mv "$tmp/.cabal-keep" "$prefix/.cabal"
	echo "$stamp" >"$prefix/.ghc-wasm-meta-rev"
	rm -rf "$tmp"
fi

# shellcheck disable=SC1091
source "$prefix/env"
wasm32-wasi-ghc --version
cabal=(wasm32-wasi-cabal --project-file=cabal.project.wasm --builddir=dist-wasm)
"${cabal[@]}" update
"${cabal[@]}" build exe:panblack exe:panblack-lite
for exe in panblack panblack-lite; do
	# The last line: git checkouts of the patched packages print to stdout.
	binpath=$("${cabal[@]}" list-bin "exe:$exe" | tail -n 1)
	echo "Built: $binpath"
	wasm-opt -Oz "$binpath" -o "$out/$exe.wasm"
done
cp COPYING.md COPYRIGHT "$out/"
ls -l "$out"/*.wasm

echo "Smoke test with $(wasmtime --version)..."
cd "$(mktemp -d)"
run() { wasmtime run --dir . "$@"; }
run "$out/panblack.wasm" --version
run "$out/panblack-lite.wasm" --version
printf 'Title\n=====\n\n_a_\n' >doc.md
printf '# Title\n\n*a*\n' >expected.md
run "$out/panblack-lite.wasm" --check=source,html <doc.md | diff - expected.md
run "$out/panblack.wasm" - <doc.md | diff - expected.md
echo "Checking that files are formatted in place..."
run "$out/panblack.wasm" doc.md
diff doc.md expected.md
echo "Checking that hooks are skipped with a warning..."
mkdir hooks
printf -- '- paths: [.]\n  hooks: [[touch, hooked]]\n' >hooks/.panblack.yaml
cp doc.md hooks/
(cd hooks && run "$out/panblack.wasm" 2>err)
grep -q "can't run hooks; run them yourself: touch hooked" hooks/err
[[ ! -e hooks/hooked ]]

# panblack-lite must format as the CLI does with the same profile.
echo "Checking panblack-lite against the CLI..."
cp "$repo"/*.md "$repo"/docs/*.md .
settings=(
	"||"
	"--check=source,html --wrap=preserve --columns=120 --reference-location=block|check: [source, html]|{wrap: preserve, columns: 120, reference-location: block}"
	"--from=gfm --to=gfm-yaml_metadata_block --normalize=|normalize: []|{from: gfm, to: gfm-yaml_metadata_block}"
)
for s in "${settings[@]}"; do
	IFS='|' read -r args keys pandoc <<<"$s"
	printf -- '- paths: [.]\n  %s\n  pandoc: %s\n' "${keys:-exts: [md]}" "${pandoc:-{\}}" >cfg.yaml
	for f in *.md; do
		lite=0 cli=0
		# shellcheck disable=SC2086
		run "$out/panblack-lite.wasm" $args <"$f" >lite.out 2>/dev/null || lite=$?
		run "$out/panblack.wasm" --config cfg.yaml --stdin-filename "$f" - <"$f" >cli.out 2>/dev/null || cli=$?
		if [[ $lite != "$cli" ]] || ! cmp -s lite.out cli.out; then
			echo "$f with '$args': panblack-lite (exit $lite) and the CLI (exit $cli) differ" >&2
			exit 1
		fi
	done
done
echo "panblack-lite matches the CLI"

