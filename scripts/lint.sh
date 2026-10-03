#!/usr/bin/env bash
# lint.sh — the house lint over Pickglass's Gleam sources.
#
# Usage: scripts/lint.sh [options] [path...]   (default: every packages/*/src)
#
# The linter is Loom's, vendored under tools/lint as its own package: it
# carries glance/glexer/simplifile dependencies no Pickglass package should.
# The rules are R0 unparseable sources, R1 eager fallbacks, R2 `case` nesting
# depth, R3 catch-all patterns, R4 `panic`/`let assert` in src, R5 O(n)
# answers to bounded questions, R6 the portable subset (`core`), R7 a
# `let assert` that names no invariant, R8 a long signature with one caller,
# R9 a naked `Bool` in a parameter or field, R10 a comment with no blank
# line above it, R11 a body written as one undivided block, R12 a closure
# capturing a whole value for its fields, the orientation rules R13 a large
# module's `## Flow` spine, R14 a transition table checked against its
# type, R15 state-machine types before the first function, R16 an
# unqualified import of a Pickglass function, and the censuses R17
# (call-flow order) and R18 (short helpers the module doc never names);
# tools/lint/CLAUDE.md says what each is for.
#
# R0, R2, R4, R6, R10, R13, R14, R15 and R16 are at ERROR level and this
# script exits non-zero on any of them; every other rule warns and costs
# nothing. The staging lives in `finding.error_by_default`, not here, so a
# promotion needs no change to this script or to the Makefile. To promote one
# rule for a single run:
#
#   scripts/lint.sh --error=R5
#
# Keep local changes to tools/lint at the minimum: it tracks Loom's
# packages/lint, and the vendoring commit message lists every deviation.
#
# The linter's last line is `# <errors> <warnings>`, which is what we read.
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(pwd)

paths=()
options=()
for argument in "$@"; do
	case $argument in
	-*) options+=("$argument") ;;
	*) paths+=("$root/${argument#"$root/"}") ;;
	esac
done

if [ ${#paths[@]} -eq 0 ]; then
	for directory in packages/*/src; do
		[ -d "$directory" ] && paths+=("$root/$directory")
	done
fi

output=$(cd tools/lint && gleam run -m lint/cli -- \
	${options[@]+"${options[@]}"} "${paths[@]}")
printf '%s\n' "$output"

tail=${output##*$'\n'}
case $tail in
"# "*)
	errors=${tail#\# }
	errors=${errors%% *}
	;;
*) errors=0 ;;
esac
case $errors in "" | *[!0-9]*) errors=0 ;; esac

if [ "$errors" -gt 0 ]; then
	echo "lint FAILED: $errors error(s)"
	exit 1
fi
