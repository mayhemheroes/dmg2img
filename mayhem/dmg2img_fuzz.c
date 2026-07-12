/*
 * mayhem/dmg2img_fuzz.c — in-process libFuzzer harness for dmg2img.
 *
 * WHY (target conversion): the prior integration fuzzed the raw dmg2img CLI as a file-input
 * target compiled with ASan+UBSan. Under Mayhem that binary entered a mayhem-fuzz restart loop
 * (rc 254 / "Error running your target") and produced 0 edges (run #17, failed). A sanitized
 * one-shot CLI is not a fuzzable file-input target here. Per PORTING.md §6, we convert it to an
 * in-process libFuzzer harness over the SAME code path (koly -> XML plist -> base64 -> mishblk
 * -> ADC/zlib/bzip2 decompress) so libFuzzer's own coverage instrumentation drives it.
 *
 * HOW (no upstream edits — additive only): dmg2img.c is compiled with `-Dmain=dmg2img_cli_main`
 * so we can invoke the unmodified CLI entry point in-process. dmg2img is an allocate-and-exit
 * batch tool: it calls exit() on malformed input and leaks its process-lifetime state / file
 * handles on error returns. To reuse it across libFuzzer iterations we:
 *   - intercept exit() via `-Wl,--wrap=exit` and siglongjmp back out of the iteration;
 *   - reclaim any file descriptors the tool leaked (it does not close FIN/FOUT on many error
 *     `return`/`exit` paths) by closing every fd opened during the iteration;
 *   - reset the tool's globals to their program defaults.
 * detect_leaks=0 (mayhem/asan_options.c) covers the benign allocate-and-exit heap leaks; ASan
 * out-of-bounds/UAF + UBSan stay fully armed on the fuzzed code.
 */
#include <dirent.h>
#include <fcntl.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* dmg2img.c, compiled with -Dmain=dmg2img_cli_main */
extern int dmg2img_cli_main(int argc, char *argv[]);

/* Globals owned by dmg2img.c that must be reset between iterations. */
extern FILE *FIN, *FOUT, *FDBG;
extern int debug, verbose, listparts, extractpart;

/* --- exit() interception ------------------------------------------------- */
extern void __real_exit(int) __attribute__((noreturn));
static sigjmp_buf g_exit_jmp;
static int g_in_target;

void __wrap_exit(int code)
{
	if (g_in_target) {
		g_in_target = 0;
		siglongjmp(g_exit_jmp, (code & 0xff) ? (code & 0xff) : 256);
	}
	__real_exit(code);
}

/* --- fd bookkeeping: reclaim descriptors the tool leaks on error paths ---- */
#define FD_MAX 4096
static unsigned char g_fd_baseline[FD_MAX]; /* fds open before the iteration */

static void snapshot_open_fds(unsigned char *out)
{
	memset(out, 0, FD_MAX);
	DIR *d = opendir("/proc/self/fd");
	if (!d)
		return;
	struct dirent *e;
	while ((e = readdir(d)) != NULL) {
		if (e->d_name[0] < '0' || e->d_name[0] > '9')
			continue;
		long fd = strtol(e->d_name, NULL, 10);
		if (fd >= 0 && fd < FD_MAX)
			out[fd] = 1;
	}
	closedir(d);
}

/* Close every fd that the tool opened during this iteration (leaked FIN/FOUT/FDBG). */
static void close_fds_opened_since(const unsigned char *baseline)
{
	unsigned char now[FD_MAX];
	snapshot_open_fds(now);
	for (int fd = 3; fd < FD_MAX; fd++)
		if (now[fd] && !baseline[fd])
			close(fd);
}

static void reset_globals(void)
{
	/* Do NOT fclose here: on its normal path the tool already fclose()d these and left the
	 * globals dangling; the fd sweep reclaims descriptors leaked on error paths. */
	FIN = NULL;
	FOUT = NULL;
	FDBG = NULL;
	debug = 0;
	verbose = 1;
	listparts = 0;
	extractpart = -1;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	/* Stage under /dev/shm: the commit image (incl. /tmp) is read-only during Mayhem coverage
	 * collection, so /dev/shm is the writable location. Output goes to /dev/null (a device, always
	 * writable) so large SectorCounts can't fill the fs. */
	static char in_path[64];
	if (in_path[0] == '\0')
		snprintf(in_path, sizeof(in_path), "/dev/shm/dmg2img_fuzz_%d.dmg", (int)getpid());

	int fd = open(in_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		return 0;
	if (write(fd, data, size) != (ssize_t)size) {
		close(fd);
		return 0;
	}
	close(fd);

	unsigned char baseline[FD_MAX];
	snapshot_open_fds(baseline);

	reset_globals();
	/* -s (silent) + discard output to /dev/null so huge SectorCounts don't fill the disk. */
	char *argv[] = { "dmg2img", "-s", in_path, "/dev/null", NULL };
	g_in_target = 1;
	if (sigsetjmp(g_exit_jmp, 1) == 0)
		dmg2img_cli_main(4, argv);
	g_in_target = 0;

	close_fds_opened_since(baseline);
	reset_globals();
	return 0;
}
