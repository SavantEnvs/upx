#!/usr/bin/env bash
#
# mayhem/test.sh — RUNS UPX's own upstream CTest suite (built by mayhem/build.sh into build-test/,
# NORMAL flags; never compiles here).
#
# What it asserts (behavioral, not exit-code-only): the suite packs `upx` itself with every
# codec/filter combination (nrv2b/nrv2d/nrv2e/lzma, with/without filters), UNPACKS each, and
# asserts with `cmake -E compare_files` that every unpacked copy is BYTE-IDENTICAL to the
# pristine pre-pack original — a pack -> unpack round-trip must reproduce the exact original bytes
# — then executes both the packed and unpacked binaries (`--version-short`) to confirm they still
# run. A patch that "fixes" a bug by making decompression a no-op (or exit(0)) produces a missing/
# wrong-sized/corrupt unpacked file, which fails the compare_files assertion and/or the run step —
# this is NOT reward-hackable by a program that merely exits 0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # ctest parallelism; env-overridable, falls back to nproc
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

TESTDIR="build-test"
if [ ! -d "$TESTDIR" ] || [ ! -f "$TESTDIR/CTestTestfile.cmake" ]; then
  echo "mayhem/test.sh: $TESTDIR/CTestTestfile.cmake missing — mayhem/build.sh should have produced it" >&2
  emit_ctrf "cmake-ctest" 0 1
  exit 1
fi

JUNIT="$(mktemp -t upx-ctest-junit.XXXXXX.xml)"
trap 'rm -f "$JUNIT"' EXIT

# Clear leftover pack/unpack artifacts from a PRIOR run before testing. The self-pack suite writes
# its packed/unpacked outputs into $TESTDIR/XTesting/Release (upx_add_test's fixed WORKING_DIRECTORY
# in misc/cmake/functions.cmake) and mayhem/build.sh already ran this suite once (baking those
# output files into the commit image). Without clearing them, a neutered/no-op `upx` binary would
# never overwrite the files, and `cmake -E compare_files` would silently pass by comparing the
# STALE already-correct files from that earlier run — this run's compare/run assertions must be
# satisfied by work THIS invocation actually did.
WD="$TESTDIR/XTesting/Release"
[ -d "$WD" ] && find "$WD" -mindepth 1 -delete

# Do NOT compile — just RUN the suite build.sh already built. -j: the self-pack suite is 1500
# independent, short-lived subprocess tests (pack/unpack/compare/run) — run them in parallel.
ctest --test-dir "$TESTDIR" -j"$MAYHEM_JOBS" --output-on-failure --output-junit "$JUNIT"
ctest_rc=$?

# Parse ctest's JUnit summary (<testsuite tests=".." failures=".." errors=".." skipped=".."/>).
read -r TOTAL FAILED SKIPPED < <(python3 - "$JUNIT" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
ts = root if root.tag == "testsuite" else root.find("testsuite")
def n(a): return int(ts.get(a, "0") or 0)
total = n("tests")
failed = n("failures") + n("errors")
skipped = n("skipped") + n("disabled")
print(total, failed, skipped)
PY
)

passed=$(( TOTAL - FAILED - SKIPPED ))
[ "$passed" -lt 0 ] && passed=0

emit_ctrf "cmake-ctest" "$passed" "$FAILED" "$SKIPPED"
rc=$?
[ "$ctest_rc" -eq 0 ] && [ "$rc" -eq 0 ]
