#!/bin/sh
# Part of wuffada (wuffs-ada: Wuffs to Ada).
# SPDX-License-Identifier: Apache-2.0 OR MIT
#
# Makes the source archive of a release: the Ada library alone, with its
# generated sources, as an Alire crate at the top of the archive. It needs
# neither Go nor the Wuffs checkout to be built or used.
#
#   ./release.sh VERSION [OUTDIR]     (OUTDIR defaults to ./dist)
#
# The archive is OUTDIR/wuffs_ada-VERSION.tar.gz; VERSION replaces the
# version of ada/alire.toml in it.
set -eu
[ $# -ge 1 ] || { echo "usage: $0 VERSION [OUTDIR]" >&2; exit 2; }
version="$1"
out="${2:-dist}"
cd "$(dirname "$0")"
name="wuffs_ada-$version"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
dst="$tmp/$name"
mkdir -p "$dst" "$out"

cp LICENSE "$dst/"
cp -r LICENSES "$dst/"
cp ada/wuffs_ada.gpr ada/wuffs_common.gpr ada/wuffs_simd.gpr ada/gnat.adc "$dst/"
sed "s/^version = .*/version = \"$version\"/" ada/alire.toml > "$dst/alire.toml"
grep -q "^version = \"$version\"\$" "$dst/alire.toml" || { echo "$0: no version line in ada/alire.toml" >&2; exit 1; }
mkdir -p "$dst/src"
for d in root base pixel ycck token runtime simd; do
    cp -r "ada/src/$d" "$dst/src/"
done
# Tools that regenerate parts of the sources are not part of the library.
rm -rf "$dst/src/pixel/tools" "$dst/src/ycck/tools"
find "$dst" -name __pycache__ -prune -exec rm -rf {} +
cp -r ada/gen "$dst/gen"
cat > "$dst/README.md" <<EOT
# wuffs_ada $version

Memory-safe decoders in pure Ada: the Wuffs standard library compiled to
Ada, on a SPARK-proved base library. This archive is the library alone,
with its generated sources, as an Alire crate.

    alr build                          # release profile, SIMD on (x86-64)
    alr build -- -XWUFFS_SIMD=off      # any other target
    alr build -- -XWUFFS_PROFILE=checked

Client units must be compiled as Ada 2022 (-gnat2022).

Sources, tests, proofs and documentation:
https://github.com/ovenpasta/wuffada
EOT
tar -C "$tmp" --sort=name --owner=0 --group=0 --numeric-owner -czf "$out/$name.tar.gz" "$name"
echo "$out/$name.tar.gz"
