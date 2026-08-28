// mayhem/upx_fuzz.cpp -- in-process libFuzzer harness for UPX.
//
// One source, compiled once per Mayhem target; -DUPX_FUZZ_MODE selects which UPX command the
// fuzzed bytes are fed to:
//
//   UPX_FUZZ_MODE_PACK    -> target `upx`        : `--best --lzma -o OUT IN`  (the packer)
//   UPX_FUZZ_MODE_UNPACK  -> target `upx-unpack` : `-d -o OUT IN`             (the unpacker)
//   UPX_FUZZ_MODE_LIST    -> target `upx-list`   : `-l IN`                    (header/format parse)
//   UPX_FUZZ_MODE_TEST    -> target `upx-test`   : `-t IN`                    (verify a packed file)
//
// The last three mirror, one-for-one, the three harnesses OSS-Fuzz builds for this project
// (projects/upx/fuzzers/{decompress,list,test}_packed_file_fuzzer.cpp) -- SPEC 6.2 item 12 requires
// an OSS-Fuzz project to ship ALL of them. `upx` (packing) is additional: it is the target the
// retired mayhemheroes integration measured, and its name and `--best --lzma` selection are kept so
// that run history stays attached to the code path it was attached to.
//
// WHY AN IN-PROCESS HARNESS AND NOT A RAW FILE-INPUT CLI TARGET (the 155-edge story).
// The first integration wired both Mayhem targets as raw CLI targets
// (`cmd: /mayhem/upx --best --lzma -o /tmp/packed --force-overwrite @@`). That shape is legitimate
// in this fleet, but it cannot work for UPX, for a reason visible in the binary itself: UPX returns
// the SAME exit status (1) for "file is too small", "not an executable" and "no such file", so
// Mayhem's file-input detection concludes the target never reads the staged input and aborts the
// run ("Your target runs but does not seem to use the file input specified in the Mayhemfile",
// tests_run=0, edges=0 -- runs #1-#3). The integration then papered over that with
// MFUZZ_COMPAT_LEVEL, which let run #4 complete but in Mayhem's degraded compatibility execution
// mode: 155 edges, when a SINGLE local execution of the sanitized upx binary already covers 8,963
// of its 97,359 instrumented edges (measured with a trace-pc-guard counting runtime; even a
// rejected 1-byte input covers 5,340 just reaching main()). 155 edges is ~1.7% of one execution --
// the number was never a statement about UPX's fuzz surface at all.
//
// SPEC 6.2 item 11 prescribes the fix: "prefer an instrumented harness (libFuzzer, or AFL via
// `afl: true`) so the target is genuinely fuzzable". In-process also removes a ~24ms fork+exec per
// input and gives Mayhem real SanitizerCoverage edge counts instead of black-box tracing.
//
// WHY upx_main() IS SAFE TO CALL IN A LOOP (upstream supports it; OSS-Fuzz relies on it too).
// src/main.cpp -- "Allow serial re-use of upx_main() as a subroutine" -- upx_main() resets
// `exit_code` and calls `opt->reset()` on entry, and src/work.cpp's do_files() wraps every file in
// a full try/catch ladder (Exception/Error/bad_alloc/std::exception/...). There is no exit() or
// abort() anywhere in src/ outside main.cpp's e_exit(), and e_exit() is only reachable from
// --help/--version/--sysinfo/usage errors, i.e. from argv -- and this harness supplies a fixed,
// valid argv. So no upstream source had to be touched: the diff stays purely additive (UPX's own
// `main` is renamed out of a COPY of its object file at link time; see mayhem/build.sh).

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits.h>
#include <unistd.h>

// upx's own re-entrant entry point (declared `noinline int upx_main(int, char **) may_throw;` in
// src/conf.h, where `may_throw` is `noexcept(false)`). Declared locally rather than including
// conf.h so the harness does not drag in UPX's whole configuration header.
int upx_main(int argc, char *argv[]) noexcept(false);
void upx_rand_init() noexcept;

#define UPX_FUZZ_MODE_PACK 0
#define UPX_FUZZ_MODE_UNPACK 1
#define UPX_FUZZ_MODE_LIST 2
#define UPX_FUZZ_MODE_TEST 3

#ifndef UPX_FUZZ_MODE
#define UPX_FUZZ_MODE UPX_FUZZ_MODE_PACK
#endif

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

// Mayhem/rlenv scratch contract (SPEC 6.2 item 13): never a hardcoded path, never anything under
// the read-only image dir -- $TMPDIR, falling back to /tmp.
static const char *fuzz_tmpdir() {
    const char *t = getenv("TMPDIR");
    return (t != nullptr && t[0] != '\0') ? t : "/tmp";
}

static bool write_all(int fd, const uint8_t *data, size_t size) {
    while (size > 0) {
        ssize_t n = write(fd, data, size);
        if (n <= 0)
            return false;
        data += (size_t) n;
        size -= (size_t) n;
    }
    return true;
}

extern "C" int LLVMFuzzerInitialize(int *argc, char ***argv) {
    (void) argc;
    (void) argv;
    // upx_main() runs UPX's entire embedded doctest self-test suite on EVERY call unless this is
    // set (src/check/dt_check.cpp). For the CLI that is a once-per-process cost; in-process it
    // would dominate every iteration -- and the self-tests are not the fuzz surface.
    setenv("UPX_DEBUG_DOCTEST_DISABLE", "1", 1);
    // main() does this once before upx_main(); upx_main() itself does not.
    upx_rand_init();
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    // UPX rejects an empty file before opening it; 32 MiB is a sanity cap so a pathological input
    // cannot make the harness itself the bottleneck.
    if (size == 0 || size > (32u << 20))
        return 0;

    char in_path[PATH_MAX];
    char out_path[PATH_MAX];
    if (snprintf(in_path, sizeof(in_path), "%s/upx-fuzz-XXXXXX", fuzz_tmpdir()) <= 0)
        return 0;
    int fd = mkstemp(in_path);
    if (fd < 0)
        return 0;
    const bool wrote = write_all(fd, data, size);
    (void) close(fd);
    // Derived from the mkstemp'd name so concurrent workers never collide on one output path.
    // (OSS-Fuzz's own harnesses hardcode /tmp/libfuzzer.<pid>; SPEC 6.2 item 13 asks for
    // $TMPDIR + mkstemp instead.)
    (void) snprintf(out_path, sizeof(out_path), "%s.upx", in_path);

    if (wrote) {
        // Writable argv: UPX's getopt implementation may permute it.
        char a_prog[] = "upx";
        char a_force[] = "--force-overwrite";
        // Silence the per-file banner and result table: at thousands of iterations per second UPX's
        // normal reporting costs more than the work itself. Error handling is unchanged.
        char a_quiet[] = "-qq";
        char a_o[] = "-o";
#if UPX_FUZZ_MODE == UPX_FUZZ_MODE_PACK
        // `--best --lzma`: the retired mayhemheroes integration's exact compression selection.
        char a_best[] = "--best";
        char a_lzma[] = "--lzma";
        char *args[] = {a_prog, a_best, a_lzma, a_force, a_quiet, a_o, out_path, in_path, nullptr};
#elif UPX_FUZZ_MODE == UPX_FUZZ_MODE_UNPACK
        // `-d`: decompress. UPX's unpacker / executable-format-detection code -- historically the
        // more productive surface (8 known defects: OOB read, improper input validation, uncaught
        // exception). == OSS-Fuzz's decompress_packed_file_fuzzer.
        char a_d[] = "-d";
        char *args[] = {a_prog, a_d, a_force, a_quiet, a_o, out_path, in_path, nullptr};
#elif UPX_FUZZ_MODE == UPX_FUZZ_MODE_LIST
        // `-l`: list. Parses the packed header without decompressing the payload.
        // == OSS-Fuzz's list_packed_file_fuzzer. No output file.
        char a_l[] = "-l";
        char *args[] = {a_prog, a_l, a_quiet, in_path, nullptr};
#elif UPX_FUZZ_MODE == UPX_FUZZ_MODE_TEST
        // `-t`: test. Decompresses and verifies a packed file in memory.
        // == OSS-Fuzz's test_packed_file_fuzzer. No output file.
        char a_t[] = "-t";
        char *args[] = {a_prog, a_t, a_quiet, in_path, nullptr};
#else
#error "unknown UPX_FUZZ_MODE"
#endif
        const int nargs = (int) (sizeof(args) / sizeof(args[0])) - 1;
        try {
            (void) upx_main(nargs, args);
        } catch (...) {
            // do_files() already catches per-file errors; this only guards the outer frame so a
            // throw can never escape into libFuzzer (which would abort on a non-crash).
        }
    }

    (void) unlink(in_path);
    (void) unlink(out_path);
    return 0;
}
