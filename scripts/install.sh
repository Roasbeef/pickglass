#!/bin/sh
# Install the built release under a prefix so that typing `pickglass` works.
#
#   scripts/install.sh              # PREFIX defaults to $HOME/.local
#   PREFIX=/opt/pg scripts/install.sh
#
# The release is copied into a fresh directory, $PREFIX/lib/pickglass/
# pickglass.XXXXXXXX, and never rewritten afterwards. A running viewer is an
# Erlang VM that loads modules from its release directory long after it
# boots, so replacing or deleting files under it can crash it. A reinstall
# therefore only adds a directory and repoints the `current` link at it, which
# changes what the next start runs and nothing about a VM already running.
#
# The launcher in $PREFIX/bin is a small shell script and not a symlink to
# the release's own bin/pickglass. That launcher finds its runtime relative to
# where it was started from, so it must be reached by its real path, and the
# shim resolves the `current` link with `pwd -P` on every start to get one.
#
# Once the new tree is in place the script removes the old ones it no longer
# needs, through scripts/prune_installs.sh. It keeps the tree `current` now
# points at, the tree it pointed at before this install, and any tree a live
# process still uses, found from the process command lines and, when lsof is
# installed, from open files and working directories. If that check cannot be
# made, nothing is removed. The prune script's header has the exact rules.
#
# This is the same shape as Loom's scripts/install.sh, scaled down to one
# release with no client variants.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
PREFIX=${PREFIX:-$HOME/.local}
SRC=$ROOT/build/release/pickglass

[ -x "$SRC/bin/pickglass" ] || {
  echo "install.sh: no release at $SRC; run \`make release\` first" >&2
  exit 1
}

LIB=$PREFIX/lib/pickglass
BIN=$PREFIX/bin
mkdir -p "$LIB" "$BIN"

# Resolve the directories once, so the shim and the link hold absolute
# physical paths even when PREFIX was relative or went through a symlink.
LIB=$(CDPATH= cd -- "$LIB" && pwd -P)
BIN=$(CDPATH= cd -- "$BIN" && pwd -P)

# A directory at either path would make the renames below move a file into
# it instead of replacing it, so refuse before copying anything.
for path in "$LIB/current" "$BIN/pickglass"; do
  if [ -d "$path" ] && [ ! -L "$path" ]; then
    echo "install.sh: $path is a directory; move it aside and rerun" >&2
    exit 1
  fi
done

# Staging files live beside their destinations so the final renames stay on
# one filesystem, which is what makes them atomic. They are removed on any
# exit; a release copy that was already published is deliberately not.
STAGE=$(mktemp -d "$LIB/.install.XXXXXXXX")
SHIM_STAGE=$(mktemp "$BIN/.pickglass-install.XXXXXXXX")
trap 'rm -rf "$STAGE" "$SHIM_STAGE"' EXIT

# The random suffix names this installation independently of the package
# version, so reinstalling an unchanged version still gets its own directory.
TREE=$(mktemp -d "$LIB/pickglass.XXXXXXXX")
cp -R "$SRC/." "$TREE/"

# Quote the path for the generated script, in case the prefix contains
# spaces, dollar signs or apostrophes.
quoted=$(printf '%s' "$LIB/current" | sed "s/'/'\\\\''/g")
{
  printf '%s\n' '#!/bin/sh'
  printf '%s\n' 'set -eu'
  printf "tree=\$(CDPATH= cd -- '%s' && pwd -P)\n" "$quoted"
  printf '%s\n' 'exec "$tree/bin/pickglass" "$@"'
} > "$SHIM_STAGE"
chmod 755 "$SHIM_STAGE"

# Repoint the link by renaming a new link over it. GNU mv needs -T and BSD mv
# needs -h to replace a symlink to a directory and not move the new link into
# the directory it points at. Either way a reader sees the old or the new
# tree, never a gap.
PREV=
if [ -L "$LIB/current" ]; then
  PREV=$(basename -- "$(readlink "$LIB/current")")
fi
ln -s "$TREE" "$STAGE/current"
if ! mv -T -f "$STAGE/current" "$LIB/current" 2>/dev/null; then
  mv -h -f "$STAGE/current" "$LIB/current"
fi

# Rename the finished shim into place, rather than truncating a script that a
# shell may be reading at this moment.
mv -f "$SHIM_STAGE" "$BIN/pickglass"

printf 'installed:\n  %s\n' "$BIN/pickglass"
printf 'release tree:\n  %s\n' "$TREE"

# A failed prune leaves extra trees on disk, which is not worth failing an
# install that has already succeeded.
"$ROOT/scripts/prune_installs.sh" "$LIB" "$(basename -- "$TREE")" "$PREV" ||
  echo "install.sh: pruning old release trees failed; they were left in place" >&2

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) printf 'Add %s to PATH, or run the launcher there directly.\n' "$BIN" ;;
esac
