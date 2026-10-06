#!/bin/sh
# Remove old release trees that scripts/install.sh left under a library
# directory and that nothing needs any more.
#
#   scripts/prune_installs.sh LIB KEEP...
#
# LIB is $PREFIX/lib/pickglass. Each KEEP is the name of a tree to keep: the
# one `current` points at and the one it pointed at before this install.
# install.sh runs this after it has repointed `current`, and it can be run on
# its own.
#
# A tree is a candidate only if it is a real directory, not a symlink, whose
# name is `pickglass.` followed by exactly eight letters or digits, which is
# what `mktemp` makes in install.sh. Anything else under LIB is left alone,
# including the `.install.*` staging directory of an install running at the
# same time.
#
# A candidate is kept, and reported, while a live process uses it:
#
#   - a process whose command line contains the tree's path (`ps`), or
#   - a process with a file open or its working directory inside the tree
#     (`lsof`).
#
# A running viewer is an Erlang VM that loads modules from its tree for as
# long as it lives, and deleting a file under it can crash it. If `lsof` is
# not installed, only the `ps` check runs. If `ps` or an installed `lsof`
# fails, this script cannot tell what is in use, so it deletes nothing and
# exits 0, because a tree that stays on disk costs space and a tree that is
# removed under a viewer costs the viewer.
#
# Another install that is copying a release at this moment has a tree that
# matches the pattern, is not `current` yet and is not in use, so it can be
# removed. Do not run two installs into one prefix at once.
set -eu

[ "$#" -ge 1 ] || {
  echo "usage: prune_installs.sh LIB KEEP..." >&2
  exit 2
}
# lsof reports physical paths, so a LIB reached through a symlink (macOS's
# /var is a link to /private/var) would never match a tree in use. Resolve it
# once so every candidate path below is physical.
LIB=$(CDPATH= cd -- "$1" && pwd -P)
shift

work=$(mktemp -d "${TMPDIR:-/tmp}/pickglass-prune.XXXXXXXX")
trap 'rm -rf "$work"' EXIT

# The candidate list, one path per line, minus the kept trees. The pattern is
# checked in two steps because a glob cannot say "exactly eight of these".
: > "$work/candidates"
for tree in "$LIB"/pickglass.*; do
  name=${tree##*/}
  suffix=${name#pickglass.}
  [ -d "$tree" ] && [ ! -L "$tree" ] || continue
  [ "${#suffix}" -eq 8 ] || continue
  case $suffix in *[!A-Za-z0-9]*) continue ;; esac
  keep=
  for k in "$@"; do
    [ "$k" = "$name" ] && keep=1
  done
  [ -n "$keep" ] || printf '%s\n' "$tree" >> "$work/candidates"
done

# With nothing to remove there is nothing to ask the process table.
if [ ! -s "$work/candidates" ]; then
  echo "removed 0 old release tree(s)"
  exit 0
fi

# Take one snapshot of every process's command line and one of every open
# file and working directory, and match each candidate against them. `-F n`
# prints only names, `-n` and `-w` skip DNS lookups and warnings.
if ! ps -axo command > "$work/ps" 2>/dev/null; then
  echo "prune: could not list processes; keeping every old release tree" >&2
  exit 0
fi
: > "$work/lsof"
if command -v lsof > /dev/null 2>&1; then
  if ! lsof -n -w -F n > "$work/lsof" 2>/dev/null; then
    echo "prune: lsof failed; keeping every old release tree" >&2
    exit 0
  fi
fi

removed=0
while IFS= read -r tree; do
  if grep -F -q -- "$tree" "$work/ps" || grep -F -q -- "$tree" "$work/lsof"; then
    echo "kept (in use): $tree"
    continue
  fi
  rm -rf "$tree"
  echo "removed: $tree"
  removed=$((removed + 1))
done < "$work/candidates"

echo "removed $removed old release tree(s)"
