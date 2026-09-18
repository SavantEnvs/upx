/* mayhem/wrap-upx.c -- pads the input file up to 512 bytes before exec'ing the real /mayhem/upx.
 *
 * src/work.cpp's do_one_file() rejects any input with `stat().st_size < 512` ("file is too small
 * -- skipped") via a path-based stat() BEFORE ever calling open() on the file (verified with
 * strace in the commit image: a sub-512-byte input gets only an lstat, never an open/read).
 * Mayhem's own pre-flight sanity/smoke probes are smaller than that, so it observes upx never
 * touch the probe file and aborts the run with "does not seem to use the file input specified in
 * the Mayhemfile" before real fuzzing starts -- this reproduced even at MFUZZ_COMPAT_LEVEL 1 and
 * 2 (see the backport report). A shell-script wrapper does not work here: Mayhem's own fuzz-smoke
 * requires the cmd target to be an ELF (it attaches coverage instrumentation to it directly), so
 * this is a tiny standalone C program instead. Real corpus inputs (all far over 512 bytes
 * already) pass through byte-for-byte unmodified -- only genuinely tiny probes get padded, and
 * the pad bytes are appended after the original content, never overwriting it.
 *
 * Assumes the LAST argv is the input file path (matches this Mayhemfile's `@@` at the end of the
 * cmd line); every other argument is forwarded unchanged.
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MIN_SIZE 512

int main(int argc, char **argv) {
    if (argc < 2) {
        execv("/mayhem/upx", argv);
        perror("execv");
        return 1;
    }

    char *in_path = argv[argc - 1];
    struct stat st;
    static char tmp_path[] = "/tmp/upx-padded.XXXXXX";

    if (stat(in_path, &st) == 0 && st.st_size < MIN_SIZE) {
        int out_fd = mkstemp(tmp_path);
        if (out_fd >= 0) {
            int in_fd = open(in_path, O_RDONLY);
            if (in_fd >= 0) {
                char buf[4096];
                ssize_t n;
                while ((n = read(in_fd, buf, sizeof(buf))) > 0)
                    if (write(out_fd, buf, (size_t)n) != n) break;
                close(in_fd);
            }
            char zero[MIN_SIZE] = {0};
            off_t pad = MIN_SIZE - st.st_size;
            while (pad > 0) {
                size_t chunk = pad < (off_t)sizeof(zero) ? (size_t)pad : sizeof(zero);
                ssize_t w = write(out_fd, zero, chunk);
                if (w <= 0) break;
                pad -= w;
            }
            close(out_fd);
            argv[argc - 1] = tmp_path;
        }
    }

    execv("/mayhem/upx", argv);
    perror("execv");
    return 1;
}
