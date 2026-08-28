#!/usr/bin/env bash
#
# mayhem/build.sh -- build UPX's own upstream CTest suite (the functional oracle) and the two
# instrumented libFuzzer fuzz targets.
#
# Produces:
#   build-test/                NORMAL-flags CMake build tree, CTest-enabled -- mayhem/test.sh RUNS
#                              upstream's self-pack/self-unpack/compare_files suite from here.
#   /mayhem/upx                libFuzzer target `upx`        -- pack   (`--best --lzma`)
#   /mayhem/upx-unpack         libFuzzer target `upx-unpack` -- unpack (`-d`)
#   /mayhem/upx-list           libFuzzer target `upx-list`   -- list   (`-l`)
#   /mayhem/upx-test           libFuzzer target `upx-test`   -- test   (`-t`)
#   /mayhem/<target>-standalone    a run-once reproducer per target ($STANDALONE_FUZZ_MAIN)
#   /mayhem/upx-cli            the sanitized UPX *command line* binary, for reproducing a finding
#                              exactly the way a user would (`upx-cli -d <input>`).
# All of the above are ASan+UBSan instrumented (halting), carry DWARF 3, and have LeakSanitizer
# disabled at build time via mayhem/lsan_off.cc.
#
# WHY libFuzzer AND NOT A RAW FILE-INPUT CLI TARGET: see the header of mayhem/upx_fuzz.cpp. Short
# version: UPX exits 1 identically for "file too small", "not an executable" and "no such file", so
# Mayhem's file-input detection decides the target never reads the input and kills the run
# (runs #1-#3: tests_run=0, edges=0). Run #4 only completed because the Mayhemfile pinned
# MFUZZ_COMPAT_LEVEL, i.e. Mayhem's degraded compatibility execution mode -- which reported 155
# edges, against 8,963 edges covered by a SINGLE local execution of the sanitized binary (measured
# with a trace-pc-guard counting runtime over 97,359 instrumented edges). SPEC 6.2 item 11:
# "prefer an instrumented harness (libFuzzer ...) so the target is genuinely fuzzable".
#
# AIR-GAPPED CONTRACT (SPEC 6.5): UPX vendors zlib/ucl/lzma-sdk/zstd/bzip2/doctest/valgrind as git
# submodules (vendor/*). Those are fetched by a `git submodule update --init` RUN step in
# mayhem/Dockerfile -- a Dockerfile BUILD LAYER, not this script -- so their content is already on
# disk (baked into the image) before build.sh ever runs; this script itself makes NO network calls
# and re-runs cleanly with --network none.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) -- it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENVIRONMENT (overridable), sane defaults. SANITIZER_FLAGS uses `=` (not
# `:=`) so an explicit empty value (--build-arg SANITIZER_FLAGS=) is honored -> no sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${LIB_FUZZING_ENGINE=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS COVERAGE_FLAGS LIB_FUZZING_ENGINE

cd "$SRC"
OUT="${OUT:-/mayhem}"
HERE="$SRC/mayhem"

# SanitizerCoverage for the fuzz build. Kept SEPARATE from $SANITIZER_FLAGS so that an explicit
# `--build-arg SANITIZER_FLAGS=` (no-sanitizer build) still produces working fuzz binaries: with no
# ASan runtime to supply the sancov callbacks, libFuzzer's own runtime does, and -fsanitize=fuzzer
# implies the instrumentation anyway.
FUZZ_COV_FLAGS="-fsanitize=fuzzer-no-link"

# ---------------------------------------------------------------------------------------------
# (1) TEST-ORACLE build -- a CLEAN, normal-flags `upx` PLUS upstream's own CTest self-pack suite
# (misc/cmake/self_pack_test.cmake, wired in by CMakeLists.txt when UPX_CONFIG_CMAKE_DISABLE_TEST
# is not set): pack `upx` itself with every codec/filter, unpack, assert every unpacked copy is
# byte-identical (compare_files) to the pristine original, then execute the packed/unpacked
# binaries. mayhem/test.sh only RUNS this via `ctest --test-dir build-test`, never compiles.
# Separate build dir from the sanitized one below so the two never share/clobber object files.
echo "build.sh: configuring NORMAL (test-oracle) build in build-test/ ..." >&2
cmake -S . -B build-test -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build build-test -j"$MAYHEM_JOBS"
test -x build-test/upx || { echo "build.sh: build-test/upx missing after test-oracle build" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
# (2) SANITIZED + COVERAGE-INSTRUMENTED build of the whole project. UPX's own internal -fsanitize
# machinery (UPX_CONFIG_DISABLE_SANITIZE) defaults ON for a non-strict configure (the normal "built
# from a source tree" path we're on), so it never fights our injected $SANITIZER_FLAGS/$DEBUG_FLAGS,
# which flow in through the standard CMAKE_C_FLAGS/CMAKE_CXX_FLAGS (placed BEFORE CMake's per-config
# -O2/-DNDEBUG, so our -gdwarf-3 always wins over any -g a config preset might add).
# UPX_CONFIG_DISABLE_WERROR also defaults ON in this mode, so sanitizer-only clang warnings never
# turn into a build failure. CTest generation is off for this tree (the oracle above covers it).
echo "build.sh: configuring SANITIZED+SANCOV (fuzz) build in build-fuzz/ ..." >&2
cmake -S . -B build-fuzz -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $FUZZ_COV_FLAGS $DEBUG_FLAGS" \
      -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $FUZZ_COV_FLAGS $DEBUG_FLAGS" \
      -DUPX_CONFIG_CMAKE_DISABLE_TEST=ON
cmake --build build-fuzz -j"$MAYHEM_JOBS"
test -x build-fuzz/upx || { echo "build.sh: build-fuzz/upx missing after fuzz build" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
# (3) Link the two libFuzzer targets (+ their standalone reproducers) out of the objects CMake just
# produced. The harness supplies libFuzzer's entry point, so UPX's own `main` must not be in the
# link; every OTHER symbol from src/main.cpp (upx_main(), main_get_options(), main_set_exit_code(),
# ...) IS needed. Renaming just that one symbol in a COPY of the object file is how we get there
# without recompiling and, crucially, without editing src/main.cpp -- the additive invariant holds
# (the committed upstream tree stays byte-for-byte pristine; `git diff` vs upstream is all `A`).
echo "build.sh: linking libFuzzer targets ..." >&2
OBJDIR="build-fuzz/CMakeFiles/upx.dir"
test -f "$OBJDIR/src/main.cpp.o" || { echo "build.sh: $OBJDIR/src/main.cpp.o missing" >&2; exit 1; }

rm -rf build-fuzz/mayhem-link && mkdir -p build-fuzz/mayhem-link
objcopy --redefine-sym main=upx_cli_main_unused \
        "$OBJDIR/src/main.cpp.o" build-fuzz/mayhem-link/main_nomain.o

# Every upx object except src/main.cpp.o (replaced by the renamed copy above), plus the vendor
# static libs CMake built alongside them. Globbed rather than hardcoded so an upstream file
# addition/removal does not silently drop code from the fuzz targets.
UPX_OBJS_NOMAIN=()
while IFS= read -r o; do UPX_OBJS_NOMAIN+=("$o"); done < <(find "$OBJDIR" -name '*.o' ! -name 'main.cpp.o' | sort)
[ "${#UPX_OBJS_NOMAIN[@]}" -gt 10 ] || { echo "build.sh: only ${#UPX_OBJS_NOMAIN[@]} upx objects found -- link would be wrong" >&2; exit 1; }
# For the fuzz targets: UPX's `main` renamed away (libFuzzer supplies its own).
UPX_OBJS_FUZZ=("${UPX_OBJS_NOMAIN[@]}" build-fuzz/mayhem-link/main_nomain.o)
# For the CLI reproducer: the original object, `main` intact.
UPX_OBJS_CLI=("${UPX_OBJS_NOMAIN[@]}" "$OBJDIR/src/main.cpp.o")
VENDOR_LIBS=()
while IFS= read -r a; do VENDOR_LIBS+=("$a"); done < <(find build-fuzz -maxdepth 1 -name 'libupx_vendor_*.a' | sort)

# LSan off (SPEC 6.2 item 15) -- linked into every fuzz and -standalone binary.
"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$HERE/lsan_off.cc" -o build-fuzz/mayhem-link/lsan_off.o
# The standalone driver is C; compile it as a C object so clang++ does not mangle its reference to
# LLVMFuzzerTestOneInput (which the C++ harness defines as extern "C").
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build-fuzz/mayhem-link/standalone_main.o

# link_target <binary-name> <extra-harness-defines...>
link_target() {
  local name="$1" ; shift
  local harness="build-fuzz/mayhem-link/${name}_harness.o"
  "$CXX" $SANITIZER_FLAGS $FUZZ_COV_FLAGS $DEBUG_FLAGS "$@" -std=c++17 \
         -c "$HERE/upx_fuzz.cpp" -o "$harness"
  # libFuzzer build (the Mayhem target).
  "$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
         "$harness" "${UPX_OBJS_FUZZ[@]}" build-fuzz/mayhem-link/lsan_off.o \
         "${VENDOR_LIBS[@]}" -o "$OUT/$name"
  # Standalone (non-fuzzer) run-once reproducer for the same harness.
  "$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS \
         build-fuzz/mayhem-link/standalone_main.o \
         "$harness" "${UPX_OBJS_FUZZ[@]}" build-fuzz/mayhem-link/lsan_off.o \
         "${VENDOR_LIBS[@]}" -o "$OUT/${name}-standalone"
}

# One harness source, one binary per Mayhem target (see mayhem/upx_fuzz.cpp).
link_target upx        -DUPX_FUZZ_MODE=UPX_FUZZ_MODE_PACK
link_target upx-unpack -DUPX_FUZZ_MODE=UPX_FUZZ_MODE_UNPACK
link_target upx-list   -DUPX_FUZZ_MODE=UPX_FUZZ_MODE_LIST
link_target upx-test   -DUPX_FUZZ_MODE=UPX_FUZZ_MODE_TEST

# The CLI form of the same sanitized code, kept as a human reproducer (`upx-cli -d <input>`).
# Relinked from the same objects rather than copied from build-fuzz/upx so that it too gets
# lsan_off.o -- otherwise reproducing a finding by hand would drown in LeakSanitizer output.
"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS \
       "${UPX_OBJS_CLI[@]}" build-fuzz/mayhem-link/lsan_off.o \
       "${VENDOR_LIBS[@]}" -o "$OUT/upx-cli"

FUZZ_TARGETS=(upx upx-unpack upx-list upx-test)
BUILT=()
for t in "${FUZZ_TARGETS[@]}"; do BUILT+=("$OUT/$t" "$OUT/$t-standalone"); done
for b in "${BUILT[@]}" "$OUT/upx-cli"; do
  test -x "$b" || { echo "build.sh: $b missing after link" >&2; exit 1; }
done

echo "build.sh complete:"
ls -la "${BUILT[@]}" "$OUT/upx-cli" build-test/upx
