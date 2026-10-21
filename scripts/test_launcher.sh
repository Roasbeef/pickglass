#!/usr/bin/env bash
# Tests for scripts/launcher.sh.in: which arguments become emulator flags and
# which reach the program. A fake `erl` records its arguments, so the test
# needs no Erlang and no release build.
set -euo pipefail

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pickglass-test-launcher.XXXXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# A release tree in miniature: bin/pickglass is the real template, and the
# fake emulator prints one argument per line.
mkdir -p "$TMP/rel/bin" "$TMP/rel/erts-0/bin" "$TMP/rel/lib/app/ebin"
sed "s/@ERTS_VSN@/0/" "$HERE/launcher.sh.in" > "$TMP/rel/bin/pickglass"
chmod +x "$TMP/rel/bin/pickglass"
cat > "$TMP/rel/erts-0/bin/erl" <<'FAKE'
#!/bin/sh
printf '%s\n' "$@"
FAKE
chmod +x "$TMP/rel/erts-0/bin/erl"

run() { "$TMP/rel/bin/pickglass" "$@"; }

# Everything after -extra is what the program sees; everything before it is
# what the emulator sees.
after_extra() { printf '%s\n' "$1" | sed '1,/^-extra$/d'; }
before_extra() { printf '%s\n' "$1" | sed '/^-extra$/,$d'; }

# No options: no distribution flags, and the arguments pass through unchanged.
out=$(run attach --node app@127.0.0.1)
[ "$(after_extra "$out")" = "attach
--node
app@127.0.0.1" ] || fail "plain arguments were changed"
before_extra "$out" | grep -qx -- '-proto_dist' && fail "unrequested -proto_dist"

# The two options become emulator flags, in either spelling, wherever they
# appear, and the program never sees them.
out=$(run attach --proto-dist inet_tls --node app@127.0.0.1 \
  --ssl-dist-optfile "/a path/ssl_dist.conf")
[ "$(after_extra "$out")" = "attach
--node
app@127.0.0.1" ] || fail "the program saw a distribution option"
before_extra "$out" | grep -A1 -x -- '-proto_dist' | grep -qx inet_tls \
  || fail "-proto_dist inet_tls missing"
before_extra "$out" | grep -A1 -x -- '-ssl_dist_optfile' \
  | grep -qx "/a path/ssl_dist.conf" || fail "the optfile path lost its space"

out=$(run --proto-dist=inet_tls --ssl-dist-optfile=/f attach)
before_extra "$out" | grep -A1 -x -- '-ssl_dist_optfile' | grep -qx /f \
  || fail "the = spelling was not honoured"
[ "$(after_extra "$out")" = "attach" ] || fail "the = spelling leaked"

# --name fixes the viewer's node name and keeps it hidden and non-listening.
out=$(run attach --name me@127.0.0.1 --node app@127.0.0.1)
before_extra "$out" | grep -A1 -x -- '-name' | grep -qx me@127.0.0.1 \
  || fail "-name missing"
before_extra "$out" | grep -qx -- '-hidden' || fail "the named viewer is visible"
before_extra "$out" | grep -A1 -x -- '-dist_listen' | grep -qx false \
  || fail "the named viewer listens"
[ "$(after_extra "$out")" = "attach
--node
app@127.0.0.1" ] || fail "the program saw --name"

# After a bare -- the arguments are the program's, even if they look like ours.
out=$(run attach -- --name x --proto-dist y)
[ "$(after_extra "$out")" = "attach
--
--name
x
--proto-dist
y" ] || fail "arguments after -- were consumed"
before_extra "$out" | grep -qx -- '-name' && fail "-- did not stop the scan"

# A missing value is refused before the emulator starts.
if run attach --proto-dist 2>"$TMP/err"; then fail "a missing value was accepted"; fi
grep -q "needs a value" "$TMP/err" || fail "no reason was printed"

# -nocookie stays first, so no cookie file is created in the operator's home.
out=$(run --proto-dist inet_tls --ssl-dist-optfile /f)
before_extra "$out" | grep -qx -- '-nocookie' || fail "-nocookie is gone"

echo "launcher tests passed"
