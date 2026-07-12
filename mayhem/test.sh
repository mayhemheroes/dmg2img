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

# dmg2img ships NO upstream test suite (no make check / ctest / unit dir). We therefore run a
# behavioral known-answer oracle built by mayhem/build.sh:
#   1) dmg2img_selftest — asserts adc_decompress()/decode_base64()/cleanup_base64() known answers.
#   2) end-to-end: run the real `dmg2img` CLI on a generated known-answer sample.dmg and diff the
#      produced image against the recorded expected bytes.
# A neutered exit(0) binary (or a codec-breaking patch) makes these assertions fail.
passed=0; failed=0

SELFTEST=/mayhem/dmg2img_selftest
CLI=/mayhem/dmg2img-cli
DMG=/mayhem/testdata/sample.dmg
EXP=/mayhem/testdata/sample.expected
[ -x "$SELFTEST" ] || { echo "missing $SELFTEST (build.sh bug)" >&2; emit_ctrf "dmg2img" 0 1; exit $?; }
[ -x "$CLI" ]      || { echo "missing $CLI (build.sh bug)" >&2;      emit_ctrf "dmg2img" 0 1; exit $?; }
[ -f "$DMG" ] && [ -f "$EXP" ] || { echo "missing sample fixture (build.sh bug)" >&2; emit_ctrf "dmg2img" 0 1; exit $?; }

# 1) unit known-answer oracle: count per-test PASS/FAIL lines.
st_out="$("$SELFTEST" 2>&1)" || true
echo "$st_out"
up=$(printf '%s\n' "$st_out" | grep -c '^PASS ' || true)
uf=$(printf '%s\n' "$st_out" | grep -c '^FAIL ' || true)
# require the self-summary line to be present AND report zero failures (guards a silenced binary)
if ! printf '%s\n' "$st_out" | grep -q "^SELFTEST pass=${up} fail=${uf}$"; then
  echo "selftest summary missing/inconsistent" >&2; uf=$((uf + 1))
fi
passed=$((passed + up)); failed=$((failed + uf))

# 2) end-to-end oracle: decode the sample DMG and compare bytes.
out="$(mktemp /tmp/dmg2img-e2e.XXXXXX.img)"
if "$CLI" "$DMG" "$out" >/dev/null 2>&1 && cmp -s "$out" "$EXP"; then
  echo "PASS e2e_sample_dmg"; passed=$((passed + 1))
else
  echo "FAIL e2e_sample_dmg (dmg2img output != expected)"; failed=$((failed + 1))
fi
rm -f "$out"

emit_ctrf "dmg2img" "$passed" "$failed"
