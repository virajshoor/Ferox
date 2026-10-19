#!/bin/sh
# Compiles every Ferox shader module the way ShaderLibrary does: Common.metal
# prepended, Metal 3.0, invariance preserved. Requires Xcode's metal compiler.
# Usage: Scripts/compile-shaders.sh [output-directory]
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
src="$root/Sources/FeroxRender/Shaders"
out=${1:-$(mktemp -d)}
mkdir -p "$out"
for file in "$src"/*.metal; do
    name=$(basename "$file" .metal)
    if [ "$name" = "Common" ]; then
        continue
    fi
    combined="$out/$name.combined.metal"
    {
        cat "$src/Common.metal"
        printf '\n#line 1 "%s.metal"\n' "$name"
        cat "$file"
    } >"$combined"
    # `xcrun -sdk macosx` selects the SDK. The metal driver itself rejects `-sdk`.
    xcrun -sdk macosx metal -c "$combined" -o "$out/$name.air" \
        -std=macos-metal3.0 -fpreserve-invariance
    echo "compiled $name.metal"
done
echo "shader air files: $out"
