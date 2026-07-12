/* Disable LeakSanitizer only (keep ASan out-of-bounds/UAF + UBSan). dmg2img is a one-shot CLI
 * that never frees its process-lifetime allocations (output_file/plist/blkx/parts), so LSan flags
 * a benign leak on every input; worse, LSan ptrace-attaches at exit and dies 0-edge under Mayhem's
 * own ptrace. Baking the option into the binary holds regardless of the runtime ASAN_OPTIONS. */
__attribute__((weak)) const char *__asan_default_options(void) { return "detect_leaks=0"; }
