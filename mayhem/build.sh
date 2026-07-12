#!/usr/bin/env bash
#
# mayhem/build.sh — build dmg2img's Mayhem fuzz target (the real CLI, instrumented), the
# functional-test CLI, the unit-test oracle, and a known-answer sample.dmg fixture.
# Runs inside the commit image as `mayhem` in /mayhem.
#
# Target `dmg2img` (file-input): the real dmg2img converter built from dmg2img.c + base64.c +
# adc.c with ASan/UBSan + coverage instrumentation, driven over a whole .dmg file (@@). This is
# the original mayhemheroes target's code path (koly -> XML plist -> base64 -> mishblk ->
# ADC/zlib/bzip2 decompress), preserved as a file-input target and seeded with a valid .dmg so
# the coverage-guided run reaches the decompressors instead of dying at the koly check.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# ---------------------------------------------------------------------------
# 1) Fuzz target `dmg2img`: the real converter, instrumented (ASan+UBSan halting, DWARF-3),
#    linked against zlib + bzip2 exactly as upstream's Makefile does.
# ---------------------------------------------------------------------------
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/dmg2img.c" -o /tmp/dmg2img.fuzz.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/base64.c"  -o /tmp/base64.fuzz.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/adc.c"     -o /tmp/adc.fuzz.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/asan_options.c" -o /tmp/asan_options.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS \
    /tmp/dmg2img.fuzz.o /tmp/base64.fuzz.o /tmp/adc.fuzz.o /tmp/asan_options.o -lz -lbz2 \
    -o /mayhem/dmg2img

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
