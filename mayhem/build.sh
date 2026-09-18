#!/usr/bin/env bash
#
# mayhem/build.sh — build the sanitized UPX fuzz target and a normal-flags UPX used as the
# functional pack/unpack oracle by mayhem/test.sh.
#
# UPX at this commit (pre-CMake, Jan 2020) uses its own GNU-make build system (top-level
# Makefile -> src/Makefile), not CMake — that migration happened later (see mayhem/Dockerfile on
# the mayhem branch). It hardcodes WITH_UCL=1 (src/conf.h) and links the standalone UCL
# compression library plus system zlib (`LIBS += -lucl -lz`, src/Makefile). UCL is not vendored
# in-tree at this commit and is not a Debian package under this name, so mayhem/Dockerfile fetches
# the same historical UCL sources the later CMake build vendors into /home/mayhem/vendor-ucl (an
# online Dockerfile build layer); this script compiles them into a static lib with zero network
# access, satisfying the AIR-GAPPED CONTRACT (SPEC §6.5).
#
# There is no LLVMFuzzerTestOneInput entry point for either Mayhem target — both wrap the
# sanitized `upx` binary directly (mayhem/Mayhemfile: `upx --best --lzma @@`) — so this produces
# no *-standalone reproducer: the sanitized /mayhem/upx binary itself reproduces any crash
# directly (`/mayhem/upx --best --lzma <crashing-file>`).
#
# Produces:
#   /mayhem/upx          sanitized (ASan+UBSan, DWARF<4) upx — the Mayhem fuzz target
#   build-test/upx.out   NORMAL-flags upx — mayhem/test.sh's pack/unpack/compare oracle
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${UCL_SRCDIR:=/home/mayhem/vendor-ucl}"

cd "$SRC"

echo "build.sh: compiling libucl.a from $UCL_SRCDIR ..." >&2
rm -rf .ucl-obj
mkdir -p .ucl-obj
for f in "$UCL_SRCDIR"/src/*.c; do
  "$CC" -O2 -fPIC -I"$UCL_SRCDIR" -I"$UCL_SRCDIR/include" -c "$f" -o ".ucl-obj/$(basename "${f%.c}").o"
done
ar rcs "$UCL_SRCDIR/libucl.a" .ucl-obj/*.o
rm -rf .ucl-obj

# UPX's own top-level Makefile runs a whole-repo git lint (check_whitespace_git.sh) as a build
# hook on every link of upx$(exeext): it walks all git-tracked files and rejects any with binary
# content. The committed Mayhem seed corpus (binary ELF files under mayhem/*/testsuite/) trips
# it. CHECK_WHITESPACE= disables the hook via the Makefile's own override variable, without
# touching the upstream script.
MAKE_COMMON=(
  -f "$SRC/src/Makefile" srcdir="$SRC/src" top_srcdir="$SRC"
  CXX="$CXX" UPX_UCLDIR="$UCL_SRCDIR" CXXFLAGS_WERROR= CHECK_WHITESPACE=
)

echo "build.sh: configuring NORMAL (test-oracle) build in build-test/ ..." >&2
mkdir -p build-test
( cd build-test && make "${MAKE_COMMON[@]}" -j"$MAYHEM_JOBS" all )
test -x build-test/upx.out || { echo "build.sh: build-test/upx.out missing after test-oracle build" >&2; exit 1; }

echo "build.sh: configuring SANITIZED (fuzz-target) build in build-fuzz/ ..." >&2
mkdir -p build-fuzz
( cd build-fuzz && make "${MAKE_COMMON[@]}" BUILD_TYPE_SANITIZE=1 CXXFLAGS_SANITIZE="$SANITIZER_FLAGS $DEBUG_FLAGS" -j"$MAYHEM_JOBS" all )
test -x build-fuzz/upx.out || { echo "build.sh: build-fuzz/upx.out missing after fuzz-target build" >&2; exit 1; }
install -m 0755 build-fuzz/upx.out /mayhem/upx

echo "build.sh: compiling the sub-512-byte input-padding wrapper (see mayhem/wrap-upx.c) ..." >&2
"$CC" -O2 $DEBUG_FLAGS -o /mayhem/upx-wrap mayhem/wrap-upx.c

echo "build.sh complete:"
ls -la /mayhem/upx /mayhem/upx-wrap build-test/upx.out
