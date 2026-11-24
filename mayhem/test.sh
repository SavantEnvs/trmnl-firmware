#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
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

# RUN upstream's native unit tests (test/test_*, Unity), built by mayhem/build.sh exactly as
# `pio test -e native` builds them. Each binary prints Unity's summary line
# "<N> Tests <F> Failures <I> Ignored"; a binary that crashes or prints no summary counts as failed.
TESTS_DIR="$SRC/mayhem/out/tests"
if [ ! -d "$TESTS_DIR" ] || [ -z "$(ls -A "$TESTS_DIR" 2>/dev/null)" ]; then
  echo "test.sh: no test binaries in $TESTS_DIR — mayhem/build.sh must build them" >&2
  emit_ctrf "unity" 0 1 0
  exit 1
fi
passed=0; failed=0; skipped=0
for bin in "$TESTS_DIR"/test_*; do
  name=$(basename "$bin")
  out=$("$bin" 2>&1); rc=$?
  summary=$(printf '%s\n' "$out" | grep -E '^[0-9]+ Tests [0-9]+ Failures [0-9]+ Ignored' | tail -1)
  if [ -z "$summary" ]; then
    echo "FAIL $name: no Unity summary (exit $rc)"; printf '%s\n' "$out" | tail -5
    failed=$((failed + 1)); continue
  fi
  read -r n _ f _ i _ <<<"$summary"
  p=$((n - f - i))
  passed=$((passed + p)); failed=$((failed + f)); skipped=$((skipped + i))
  if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then failed=$((failed + 1)); fi
  echo "$name: $summary (exit $rc)"
  [ "$f" -eq 0 ] || printf '%s\n' "$out" | grep -E ':FAIL' || true
done
emit_ctrf "unity" "$passed" "$failed" "$skipped"
