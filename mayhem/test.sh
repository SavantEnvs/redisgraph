#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the known-answer probe that mayhem/build.sh built against RedisGraph's query front end.
#
# RedisGraph's own tests need a redis-server with the module loaded (flow tests) or a full
# server build (unit tests), so the oracle is mayhem/kat_probe: it compiles fixed Cypher queries
# through the real parser, validator, AST and execution-plan builder and evaluates real
# expressions. Every assertion below compares an exact computed value / plan shape.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PROBE=/mayhem/kat_probe
[ -x "$PROBE" ] || { echo "missing $PROBE (mayhem/build.sh builds it)" >&2; emit_ctrf "redisgraph-kat" 0 1 0; exit 1; }

OUT="$("$PROBE" 2>&1)"
echo "$OUT"

passed=0 failed=0
# expect <line number in probe output> <exact expected line> <description>
expect() {
  local got
  got="$(printf '%s\n' "$OUT" | sed -n "${1}p")"
  if [ "$got" = "$2" ]; then passed=$((passed+1)); echo "PASS: $3"
  else failed=$((failed+1)); echo "FAIL: $3: expected [$2] got [$got]" >&2; fi
}

# expression evaluation through parse -> AST -> AR_EXP: string functions, concatenation, integer math
expect 1 "value ABC-42"  "toUpper('abc') + '-' + toString(6 * 7)"
# list size + exponent: 3 + 10^2 (floating point result, as in Cypher)
expect 2 "value 103.000000" "size([1, 2, 3]) + 10 ^ 2"
# execution plan shape for a label scan with filter, projection, ordering and limit
expect 3 "plan Results Limit Sort Project Filter Node By Label Scan" "plan for MATCH/WHERE/RETURN/ORDER BY/LIMIT"
expect 4 "plan Results Project Unwind" "plan for UNWIND range(1, 3) AS i RETURN i"
# a syntax error must be rejected by the parser, not planned
expect 5 "rejected" "unbalanced MATCH (n RETURN n is rejected"
# and nothing else may be printed
[ "$(printf '%s\n' "$OUT" | wc -l)" -eq 5 ] && passed=$((passed+1)) || { failed=$((failed+1)); echo "FAIL: unexpected probe output length" >&2; }

emit_ctrf "redisgraph-kat" "$passed" "$failed" 0
