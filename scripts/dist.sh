#!/usr/bin/env bash
# Package the built release for download: one self-contained tarball and a
# SHA256SUMS file over it, under dist/.
#
#   scripts/dist.sh    # needs `make release` to have run
#
# The tarball is a tree, not a renamed executable: bin/pickglass is a
# launcher over the bundled runtime, so the archive must carry both halves.
# The name carries the platform because the ERTS inside was copied from the
# machine that built it (scripts/platform.sh). Two assertions below pin the
# contract so a packaging regression cannot publish a launcher whose runtime
# was omitted.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

REL="$ROOT/build/release/pickglass"
[ -x "$REL/bin/pickglass" ] || {
  echo "dist.sh: no release at $REL — run \`make release\` first" >&2; exit 1; }

VERSION="$(sed -n 's/^version *= *"\(.*\)"/\1/p' packages/pickglass/gleam.toml | head -1)"
STEM="pickglass-$VERSION-$(scripts/platform.sh)"

DIST="$ROOT/dist"
rm -rf "$DIST"
mkdir -p "$DIST"

# Archive under a directory named for the stem so unpacking one release never
# overwrites another. The staging link keeps the build tree where it is.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ln -s "$REL" "$STAGE/$STEM"
tar -C "$STAGE" -czhf "$DIST/$STEM.tar.gz" "$STEM"

tar -tzf "$DIST/$STEM.tar.gz" | grep -Fx "$STEM/bin/pickglass" >/dev/null
tar -tzf "$DIST/$STEM.tar.gz" | grep -E "^$STEM/erts-[^/]+/bin/erl$" >/dev/null

SHA256=sha256sum
command -v sha256sum >/dev/null 2>&1 || SHA256="shasum -a 256"
( cd "$DIST" && $SHA256 "$STEM.tar.gz" > SHA256SUMS )

echo
echo "dist/:"
( cd "$DIST" && du -h ./* | sed 's/^/  /' )
