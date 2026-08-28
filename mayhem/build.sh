#!/usr/bin/env bash
#
# mayhem/build.sh — build the sanitized UPX fuzz target and UPX's own upstream CTest suite.
#
# UPX is a CLI packer/unpacker; BOTH Mayhem targets wrap the SAME sanitized `upx` binary this
# script produces, just with different cmd flags (mayhem/Mayhemfile: `upx --best --lzma @@`, the
# packer, historical name+cmd preserved for run-history continuity; mayhem/Mayhemfile_unpack:
# `upx -d @@`, the unpacker/format-detection surface — additive, not a replacement; 8 historical
# defects there: OOB read, improper input validation, uncaught exception). There is no
# LLVMFuzzerTestOneInput entry point for either, so this script does NOT link
# $LIB_FUZZING_ENGINE / $STANDALONE_FUZZ_MAIN and produces no *-standalone reproducer: the
# sanitized /mayhem/upx binary itself already reproduces any crash directly
# (`/mayhem/upx --best --lzma <crashing-file>` or `/mayhem/upx -d <crashing-file>`).
#
# Produces:
#   /mayhem/upx        sanitized (ASan+UBSan, DWARF<4) upx — the Mayhem fuzz target (both targets)
#   build-test/         NORMAL-flags CMake build tree, CTest-enabled — mayhem/test.sh RUNS the
#                        project's own self-pack/self-unpack/compare_files suite from here
#
# AIR-GAPPED CONTRACT (SPEC §6.5): UPX vendors zlib/ucl/lzma-sdk/zstd/bzip2/doctest/valgrind as git
# submodules (vendor/*). Those are fetched by a `git submodule update --init` RUN step in
# mayhem/Dockerfile — a Dockerfile BUILD LAYER, not this script — so their content is already on
# disk (baked into the image) before build.sh ever runs; this script itself makes NO network calls
# and re-runs cleanly with --network none.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENVIRONMENT (overridable), sane defaults. SANITIZER_FLAGS uses `=` (not
# `:=`) so an explicit empty value (--build-arg SANITIZER_FLAGS=) is honored -> no sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# ---------------------------------------------------------------------------------------------
# (1) TEST-ORACLE build — a CLEAN, normal-flags `upx` PLUS upstream's own CTest self-pack suite
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
# (2) FUZZ-TARGET build — sanitized `upx`, the Mayhemfile target. UPX's own internal
# -fsanitize machinery (UPX_CONFIG_DISABLE_SANITIZE) defaults ON for a non-strict configure (the
# normal "built from a source tree" path we're on), so it never fights our injected
# $SANITIZER_FLAGS/$DEBUG_FLAGS, which flow in through the standard CMAKE_C_FLAGS/CMAKE_CXX_FLAGS
# (placed BEFORE CMake's per-config -O2/-DNDEBUG, so our -gdwarf-3 always wins over any -g a
# config preset might add). UPX_CONFIG_DISABLE_WERROR also defaults ON in this mode, so sanitizer-
# only clang warnings never turn into a build failure. Test/CTest generation is disabled for this
# tree (UPX_CONFIG_CMAKE_DISABLE_TEST=ON) — the oracle above already covers that, and self-packing
# a *sanitized* upx with itself is not the functional oracle we want here.
echo "build.sh: configuring SANITIZED (fuzz-target) build in build-fuzz/ ..." >&2
cmake -S . -B build-fuzz -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
      -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
      -DUPX_CONFIG_CMAKE_DISABLE_TEST=ON
cmake --build build-fuzz -j"$MAYHEM_JOBS"
test -x build-fuzz/upx || { echo "build.sh: build-fuzz/upx missing after fuzz-target build" >&2; exit 1; }
install -m 0755 build-fuzz/upx /mayhem/upx

echo "build.sh complete:"
ls -la /mayhem/upx build-test/upx
