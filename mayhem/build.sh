#!/usr/bin/env bash
#
# mayhem/build.sh — build dmg2img's Mayhem fuzz target (in-process libFuzzer harness), a
# standalone reproducer, the functional-test CLI, the unit-test oracle, and a known-answer
# sample.dmg fixture. Runs inside the commit image as `mayhem` in /mayhem.
#
# Target `dmg2img` (in-process libFuzzer): dmg2img.c is compiled with -Dmain=dmg2img_cli_main so
# the harness (mayhem/dmg2img_fuzz.c) can drive the real CLI code path in-process (koly -> XML
# plist -> base64 -> mishblk -> ADC/zlib/bzip2 decompress). It replaces the prior raw file-input
# CLI target, which was unfuzzable under Mayhem (sanitized one-shot CLI -> mayhem-fuzz restart
# loop, 0 edges). The library code (dmg2img.c/base64.c/adc.c) is built with ASan+UBSan + DWARF-3
# so the fuzzed code — not just the harness — is instrumented.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# ---------------------------------------------------------------------------
# 1) Fuzz target `dmg2img`: in-process libFuzzer harness over the real CLI code path.
#    Library (dmg2img.c/base64.c/adc.c) instrumented with ASan+UBSan (halting) + DWARF-3; dmg2img.c
#    built with -Dmain=dmg2img_cli_main so the harness invokes the CLI entry point in-process.
#    exit() is wrapped (-Wl,--wrap=exit) so malformed-input exits bail the iteration, not the run.
#    Linked against zlib + bzip2 exactly as upstream's Makefile does.
# ---------------------------------------------------------------------------
# Compile with -fsanitize=fuzzer-no-link so SanitizerCoverage counters are inserted into the FUZZED
# code (the library + harness), not just the linked engine — otherwise libFuzzer/Mayhem see no
# coverage and the campaign collapses to 0 edges.
FUZZ_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
$CC $FUZZ_FLAGS -Dmain=dmg2img_cli_main -c "$SRC/dmg2img.c" -o /tmp/dmg2img.fuzz.o
$CC $FUZZ_FLAGS -c "$SRC/base64.c"              -o /tmp/base64.fuzz.o
$CC $FUZZ_FLAGS -c "$SRC/adc.c"                 -o /tmp/adc.fuzz.o
$CC $FUZZ_FLAGS -c "$SRC/mayhem/asan_options.c" -o /tmp/asan_options.o
$CC $FUZZ_FLAGS -c "$SRC/mayhem/dmg2img_fuzz.c" -o /tmp/dmg2img_fuzz.o
FUZZ_OBJS="/tmp/dmg2img_fuzz.o /tmp/dmg2img.fuzz.o /tmp/base64.fuzz.o /tmp/adc.fuzz.o /tmp/asan_options.o"

# (a) libFuzzer binary — Mayhem detects LLVMFuzzerTestOneInput and runs it natively. $LIB_FUZZING_ENGINE
#     (-fsanitize=fuzzer) links the libFuzzer driver + the SanitizerCoverage runtime.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE -Wl,--wrap=exit $FUZZ_OBJS -lz -lbz2 -o /mayhem/dmg2img

# (b) standalone (non-fuzzer) reproducer: same objects + $STANDALONE_FUZZ_MAIN, runs one input.
#     -fsanitize=fuzzer-no-link at link pulls in the coverage runtime (satisfies the counter symbols)
#     WITHOUT the libFuzzer main, which $STANDALONE_FUZZ_MAIN provides instead.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -Wl,--wrap=exit \
    "$STANDALONE_FUZZ_MAIN" $FUZZ_OBJS -lz -lbz2 -o /mayhem/dmg2img-standalone

# ---------------------------------------------------------------------------
# 2) Functional-test artifacts, built with the project's NORMAL flags (independent, clean build)
#    plus optional $COVERAGE_FLAGS. mayhem/test.sh only RUNS these.
#    (a) the real dmg2img CLI for the end-to-end oracle;
#    (b) a unit-test binary asserting adc/base64/endianness known answers;
#    (c) a generator that materializes a known-answer sample.dmg.
# ---------------------------------------------------------------------------
NORMAL_FLAGS="-O2 -g $COVERAGE_FLAGS"

# (a) real dmg2img CLI (upstream build: dmg2img.c + base64.c + adc.c, -lz -lbz2)
$CC $NORMAL_FLAGS -c "$SRC/dmg2img.c" -o /tmp/dmg2img.o
$CC $NORMAL_FLAGS -c "$SRC/base64.c"  -o /tmp/base64.o
$CC $NORMAL_FLAGS -c "$SRC/adc.c"     -o /tmp/adc.o
$CC $NORMAL_FLAGS -o /mayhem/dmg2img-cli /tmp/dmg2img.o /tmp/base64.o /tmp/adc.o -lz -lbz2

# (b) unit-test oracle (adc + base64), links the project's own codec objects
$CC $NORMAL_FLAGS "$SRC/mayhem/dmg2img_selftest.c" /tmp/base64.o /tmp/adc.o -I"$SRC" \
    -o /mayhem/dmg2img_selftest

# (c) sample-DMG generator + fixture (regenerated each build — no committed binary blob)
$CC $NORMAL_FLAGS "$SRC/mayhem/gen_sample_dmg.c" -o /tmp/gen_sample_dmg
mkdir -p /mayhem/testdata
/tmp/gen_sample_dmg /mayhem/testdata/sample.dmg /mayhem/testdata/sample.expected

echo "build.sh: done"
