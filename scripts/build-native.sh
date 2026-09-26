#!/usr/bin/env bash
# Build and test panblack, and stage the binary in $1:
#
#   $1/panblack[.exe]
#   $1/COPYING.md, $1/COPYRIGHT
#
# Mirrors pandoc-forge/pandoc-feedstock's scripts/build-native.sh. Extra
# cabal and GHC options come from $CABALOPTS and $GHCOPTS.
set -euo pipefail

mkdir -p "$1"
out=$(cd "$1" && pwd)
cd "$(dirname "$0")/.."

CABALOPTS="--enable-tests ${CABALOPTS:-}"
GHCOPTS=${GHCOPTS:-}
exe=
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*) exe=.exe ;;
esac

cabal update
# shellcheck disable=SC2086
cabal build $CABALOPTS --ghc-options="$GHCOPTS" exe:panblack test:spec
# shellcheck disable=SC2086
cabal test $CABALOPTS --ghc-options="$GHCOPTS" test:spec
# shellcheck disable=SC2086
binpath=$(cabal list-bin $CABALOPTS --ghc-options="$GHCOPTS" exe:panblack)
echo "Built executable: $binpath"

cp "$binpath" "$out/panblack$exe"
[[ -z $exe ]] && strip "$out/panblack"
cp COPYING.md COPYRIGHT "$out/"

panblack="$out/panblack$exe"
"$panblack" --version
echo "Checking the bundled pandoc..."
"$panblack" --version | grep -q "(pandoc $(sed -n 's/^ *, pandoc *==\([0-9.]*\)$/\1/p' haskell/panblack.cabal))"
echo "Checking that stdin is formatted..."
cd "$(mktemp -d)"
printf 'Title\n=====\n\n_a_\n' | "$panblack" - | tr -d '\r' | diff - <(printf '# Title\n\n*a*\n')
if [[ $(uname -s) == Linux ]]; then
	echo "Checking that the binary is statically linked..."
	file "$panblack" | grep -q 'statically linked'
fi
