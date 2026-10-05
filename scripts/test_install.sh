#!/bin/sh
# Tests for scripts/prune_installs.sh and for how scripts/install.sh uses it.
#
# Everything runs under a scratch directory made with mktemp, with a fake
# release standing in for build/release, so the test needs no Erlang and no
# `make release`. It starts a few background processes of its own, and kills
# only those. The cases that depend on lsof are skipped when it is missing.
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pickglass-test-install.XXXXXXXX")
PIDS=
cleanup() {
  for pid in $PIDS; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# A fresh library directory holding the named trees, each with a file in it.
newlib() {
  LIB=$TMP/lib.$1
  mkdir -p "$LIB"
  shift
  for name in "$@"; do
    mkdir -p "$LIB/$name/bin"
    : > "$LIB/$name/bin/pickglass"
  done
}

exists() { [ -e "$LIB/$1" ] || [ -L "$LIB/$1" ]; }
must_exist() { exists "$1" || fail "$1 was removed but should be kept"; }
must_not_exist() { ! exists "$1" || fail "$1 is still there but should be removed"; }

# Directories whose names resemble a tree but are not one must survive.
decoys() {
  mkdir -p "$LIB/pickglass.short" "$LIB/pickglass.toolongname1" \
    "$LIB/pickglass.ab-d1234" "$LIB/.install.abcd1234" "$LIB/other.abcd1234"
  mkdir -p "$LIB/elsewhere"
  ln -s "$LIB/elsewhere" "$LIB/pickglass.linkLINK"
  : > "$LIB/pickglass.fileFILE"
}
decoys_survive() {
  for d in pickglass.short pickglass.toolongname1 pickglass.ab-d1234 \
    .install.abcd1234 other.abcd1234 elsewhere pickglass.linkLINK \
    pickglass.fileFILE; do
    must_exist "$d"
  done
}

# Case 1: unused old trees go; the two kept names stay; look-alikes stay.
newlib 1 pickglass.AAAAAAAA pickglass.BBBBBBBB pickglass.CCCCCCCC pickglass.DDDDDDDD
decoys
out=$("$HERE/prune_installs.sh" "$LIB" pickglass.CCCCCCCC pickglass.DDDDDDDD)
must_not_exist pickglass.AAAAAAAA
must_not_exist pickglass.BBBBBBBB
must_exist pickglass.CCCCCCCC
must_exist pickglass.DDDDDDDD
decoys_survive
[ "$(printf '%s\n' "$out" | grep -c '^removed: ')" -eq 2 ] || fail "want 2 removed lines: $out"
printf '%s\n' "$out" | grep -q '^removed 2 old release tree(s)$' || fail "no total: $out"
echo "ok: unused trees removed, kept and look-alike entries untouched"

# Case 2: a tree is kept while a process has its command line or working
# directory inside it, and is removed once that process is gone.
newlib 2 pickglass.AAAAAAAA pickglass.BBBBBBBB pickglass.CCCCCCCC
mkdir -p "$LIB/pickglass.AAAAAAAA/cwd"
sh -c 'while :; do sleep 1; done' "$LIB/pickglass.BBBBBBBB" &
ps_pid=$!
PIDS="$PIDS $ps_pid"
if command -v lsof > /dev/null 2>&1; then
  (cd "$LIB/pickglass.AAAAAAAA/cwd" && exec sleep 600) &
  cwd_pid=$!
  PIDS="$PIDS $cwd_pid"
fi
# Give the background processes a moment to appear in the process table.
sleep 1
out=$("$HERE/prune_installs.sh" "$LIB" pickglass.CCCCCCCC)
must_exist pickglass.BBBBBBBB
printf '%s\n' "$out" | grep -q "^kept (in use): .*pickglass.BBBBBBBB$" || fail "no kept line for ps: $out"
if command -v lsof > /dev/null 2>&1; then
  must_exist pickglass.AAAAAAAA
  printf '%s\n' "$out" | grep -q "^kept (in use): .*pickglass.AAAAAAAA$" || fail "no kept line for lsof: $out"
  kill "$cwd_pid"
  echo "ok: tree held by a working directory is kept"
else
  echo "skip: lsof is not installed, working-directory case not run"
fi
kill "$ps_pid"
wait "$ps_pid" 2>/dev/null || true
sleep 1
"$HERE/prune_installs.sh" "$LIB" pickglass.CCCCCCCC > /dev/null
must_not_exist pickglass.BBBBBBBB
echo "ok: tree named on a command line is kept, then removed once it exits"

# Case 3: when the in-use check fails, nothing is deleted. A fake ps or lsof
# that fails is put first on PATH.
for tool in ps lsof; do
  if [ "$tool" = lsof ] && ! command -v lsof > /dev/null 2>&1; then
    echo "skip: lsof is not installed, lsof failure case not run"
    continue
  fi
  newlib 3 pickglass.AAAAAAAA pickglass.BBBBBBBB
  mkdir -p "$TMP/fakebin.$tool"
  printf '#!/bin/sh\nexit 1\n' > "$TMP/fakebin.$tool/$tool"
  chmod 755 "$TMP/fakebin.$tool/$tool"
  PATH="$TMP/fakebin.$tool:$PATH" "$HERE/prune_installs.sh" "$LIB" pickglass.BBBBBBBB \
    > /dev/null 2> "$TMP/err" || fail "prune exited nonzero when $tool failed"
  must_exist pickglass.AAAAAAAA
  must_exist pickglass.BBBBBBBB
  grep -q 'keeping every old release tree' "$TMP/err" || fail "no warning when $tool failed"
  echo "ok: nothing deleted when $tool fails"
done

# Case 4: install.sh end to end. A fake release in a scratch copy of the
# repository layout is installed four times. Only the current tree and the
# one before it remain, and the shim still runs.
ROOT=$TMP/root
mkdir -p "$ROOT/scripts" "$ROOT/build/release/pickglass/bin"
cp "$HERE/install.sh" "$HERE/prune_installs.sh" "$ROOT/scripts/"
printf '#!/bin/sh\necho "pickglass fake"\n' > "$ROOT/build/release/pickglass/bin/pickglass"
chmod 755 "$ROOT/build/release/pickglass/bin/pickglass"
PREFIX=$TMP/prefix
LIB=$PREFIX/lib/pickglass
prev_tree=
for n in 1 2 3 4; do
  PREFIX=$PREFIX "$ROOT/scripts/install.sh" > "$TMP/install.out"
  cur=$(readlink "$LIB/current")
  count=$(ls -d "$LIB"/pickglass.* | wc -l | tr -d ' ')
  want=$n
  [ "$n" -le 2 ] || want=2
  [ "$count" -eq "$want" ] || fail "install $n left $count trees, want $want"
  [ -d "$cur" ] || fail "install $n: current points at a missing tree"
  if [ -n "$prev_tree" ]; then
    [ -d "$prev_tree" ] || fail "install $n removed the previous tree"
  fi
  prev_tree=$cur
done
[ "$(env -i PATH=/usr/bin:/bin HOME="$HOME" "$PREFIX/bin/pickglass")" = "pickglass fake" ] ||
  fail "shim did not run the installed release"
grep -q 'removed 1 old release tree' "$TMP/install.out" || fail "install output has no prune total"
echo "ok: install keeps current and previous, shim runs"

echo "install tests passed"
