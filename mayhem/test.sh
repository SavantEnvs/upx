#!/usr/bin/env bash
#
# mayhem/test.sh — functional oracle: pack a real binary with the NORMAL-flags upx built by
# mayhem/build.sh (build-test/upx.out), unpack it, and assert with `cmp` that the unpacked copy
# is BYTE-IDENTICAL to the pristine original, then run it. A "fix" that makes decompression a
# no-op or corrupts the payload produces a missing/wrong/corrupt unpacked file, which fails this
# — not reward-hackable by a program that merely exits 0.
#
# Uses /bin/true (present in every Debian base image, so this needs no seed of its own) rather
# than the sanitized /mayhem/upx: at this commit, UBSan's strict array-bounds check fires inside
# UPX's own ELF Phdr-parsing code (p_lx_elf.cpp) for essentially every real ELF input — a genuine
# bug in the target (see the backport report), not a test artifact — so the sanitized binary
# cannot double as a "does packing still work" oracle here.
set -euo pipefail
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
}

UPX=build-test/upx.out
if [ ! -x "$UPX" ]; then
  echo "mayhem/test.sh: $UPX missing — mayhem/build.sh should have produced it" >&2
  emit_ctrf "upx-selfpack" 0 1
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp /bin/true "$WORK/orig"

if "$UPX" --best --lzma -f -o "$WORK/packed" "$WORK/orig" \
  && "$UPX" -d -f -o "$WORK/unpacked" "$WORK/packed" \
  && cmp "$WORK/orig" "$WORK/unpacked" \
  && chmod +x "$WORK/unpacked" \
  && "$WORK/unpacked"; then
  echo "mayhem/test.sh: pack/unpack round-trip OK"
  emit_ctrf "upx-selfpack" 1 0
else
  echo "mayhem/test.sh: pack/unpack round-trip FAILED" >&2
  emit_ctrf "upx-selfpack" 0 1
  exit 1
fi
