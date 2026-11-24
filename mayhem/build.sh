#!/usr/bin/env bash
#
# mayhem/build.sh — build trmnl-firmware's fuzz harnesses and its native unit tests.
#
# The firmware is ESP32 (PlatformIO) code; what runs off-device is what upstream's own
# `pio test -e native` builds: lib/trmnl (host-testable parsers) on ArduinoFake + ArduinoJson.
# The image draw path (src/png_render.cpp, jpeg_render.cpp, color_reduce.cpp, board_config.cpp)
# is built the same way against bb_epaper in its memory-only mode (frames drawn into RAM), with
# PNGdec/JPEGDEC — the libraries and pins of platformio.ini [deps_common], cached in the image
# under /opt/toolchains/deps (SPEC §6.2 item 19). Deps are built uninstrumented; the firmware
# sources and the harnesses get $SANITIZER_FLAGS. Objects go to mayhem/out/ (gitignored).
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${DEPS:=/opt/toolchains/deps}"
# SanitizerCoverage for the fuzzed code and the harnesses ($LIB_FUZZING_ENGINE only links libFuzzer)
: "${FUZZ_COV_FLAGS=-fsanitize=fuzzer-no-link}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
AJ="$DEPS/ArduinoJson-7.4.2/src/src"
FAKE="$DEPS/ArduinoFake-0.4.0/src/src"
PNGDEC="$DEPS/PNGdec-1.1.6/src/src"
JPEGDEC="$DEPS/JPEGDEC-1.8.4/src/src"
EPD="$DEPS/bb_epaper-bfd1b4dc/src/src"
UNITY="$DEPS/Unity-2.6.0/src/src"
for d in "$AJ" "$FAKE" "$PNGDEC" "$JPEGDEC" "$EPD" "$UNITY"; do
  [ -d "$d" ] || { echo "missing dependency $d (built into the image by mayhem/Dockerfile)" >&2; exit 1; }
done

OUT="$SRC/mayhem/out"
mkdir -p "$OUT"

# compile <obj dir> <compiler> <flags...> -- <sources...>: one object per source, in parallel
compile() {
  local dir="$1" cc="$2"; shift 2
  local flags=()
  while [ "$1" != "--" ]; do flags+=("$1"); shift; done
  shift
  mkdir -p "$dir"
  printf '%s\n' "$@" | xargs -P "$MAYHEM_JOBS" -I{} sh -c \
    'src="$1"; shift; cc="$1"; shift; dir="$1"; shift; o="$dir/$(basename "$src").o"; exec "$cc" "$@" -c "$src" -o "$o"' \
    _ {} "$cc" "$dir" "${flags[@]}"
}

# ---------------------------------------------------------------------------------------------
# 1) lib/trmnl harnesses (upstream's [env:native] flags, minus ARDUINOJSON_DEBUG's asserts)
# ---------------------------------------------------------------------------------------------
LIBDEFS=(-DARDUINOJSON_ENABLE_ARDUINO_STRING=1 -DARDUINO=111 -include stdint.h -std=gnu++17
         -Wno-missing-template-arg-list-after-template-kw
         -I"$FAKE" -I"$FAKE/arduino" -I"$AJ" -I"$SRC/lib/trmnl/include" -I"$SRC/lib/trmnl/include/api-client")
# deps (ArduinoFake's Arduino core + mocks): uninstrumented
compile "$OUT/fuzz-deps-fake" "$CXX" $DEBUG_FLAGS -O1 -w "${LIBDEFS[@]}" -- \
  "$FAKE"/*.cpp "$FAKE"/arduino/*.cpp
compile "$OUT/fuzz-deps-fake" "$CC" $DEBUG_FLAGS -O1 -w -- "$FAKE/arduino/noniso.c"
# lib/trmnl (the fuzzed code): sanitized. test_logger.cpp is the unit tests' printf logger;
# the harnesses link mayhem/harnesses/quiet_log.cpp instead.
LIBSRCS=()
for f in "$SRC"/lib/trmnl/src/*.cpp "$SRC"/lib/trmnl/src/api-client/*.cpp; do
  [ "$(basename "$f")" = test_logger.cpp ] || LIBSRCS+=("$f")
done
compile "$OUT/fuzz-lib" "$CXX" $SANITIZER_FLAGS $FUZZ_COV_FLAGS $DEBUG_FLAGS "${LIBDEFS[@]}" -- \
  "${LIBSRCS[@]}" "$SRC/mayhem/harnesses/quiet_log.cpp"
# the unit tests' in-memory Persistence, for the log-store harness
compile "$OUT/fuzz-lib-test" "$CXX" $SANITIZER_FLAGS $FUZZ_COV_FLAGS $DEBUG_FLAGS -DPIO_UNIT_TESTING "${LIBDEFS[@]}" \
  -I"$SRC/test/common" -- "$SRC/test/common/memory_persistence.cpp"

$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$OUT/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OUT/lsan_off.o"

LIBOBJS=("$OUT"/fuzz-lib/*.o "$OUT"/fuzz-deps-fake/*.o "$OUT/lsan_off.o")
for h in api_response modem_scan http_utils stored_logs; do
  $CXX $SANITIZER_FLAGS $FUZZ_COV_FLAGS $DEBUG_FLAGS "${LIBDEFS[@]}" -DPIO_UNIT_TESTING -I"$SRC/test/common" \
    -c "$SRC/mayhem/harnesses/fuzz_$h.cpp" -o "$OUT/fuzz_$h.o"
  objs=("$OUT/fuzz_$h.o" "${LIBOBJS[@]}")
  [ "$h" = stored_logs ] && objs+=("$OUT/fuzz-lib-test/memory_persistence.cpp.o")
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "${objs[@]}" -o "/mayhem/fuzz_$h"
  $CXX $SANITIZER_FLAGS $FUZZ_COV_FLAGS $DEBUG_FLAGS "$OUT/standalone_main.o" "${objs[@]}" -o "/mayhem/fuzz_$h-standalone"
done

# ---------------------------------------------------------------------------------------------
# 2) image draw path: firmware render sources on bb_epaper (memory-only) + PNGdec + JPEGDEC,
#    configured as the original TRMNL board ([env:trmnl]: BOARD_TRMNL, PNG_MAX_BUFFERED_PIXELS)
# ---------------------------------------------------------------------------------------------
IMGDEFS=(-DBOARD_TRMNL -DDEVICE_MODEL='"og"' -DPNG_MAX_BUFFERED_PIXELS=6432 -D__LINUX__ -D__MEM_ONLY__
         -I"$SRC/mayhem/shim" -I"$SRC/include" -I"$SRC/lib/trmnl/include" -I"$EPD" -I"$PNGDEC" -I"$JPEGDEC")
# deps: uninstrumented. bb_epaper's own platform switch: __MACH__ skips the ESP-IDF I/O include.
compile "$OUT/img-deps" "$CXX" $DEBUG_FLAGS -O1 -w -std=gnu++17 "${IMGDEFS[@]}" -D__MACH__ -- \
  "$SRC/mayhem/harnesses/bb_epaper_mem.cpp"
compile "$OUT/img-deps" "$CXX" $DEBUG_FLAGS -O1 -w -std=gnu++17 "${IMGDEFS[@]}" -- \
  "$PNGDEC/PNGdec.cpp" "$JPEGDEC/JPEGDEC.cpp"
compile "$OUT/img-deps" "$CC" $DEBUG_FLAGS -O1 -w -D__LINUX__ -- "$PNGDEC"/*.c
# firmware sources (the fuzzed code): sanitized
compile "$OUT/img-fw" "$CXX" $SANITIZER_FLAGS $FUZZ_COV_FLAGS $DEBUG_FLAGS -std=gnu++17 "${IMGDEFS[@]}" -- \
  "$SRC/src/png_render.cpp" "$SRC/src/jpeg_render.cpp" "$SRC/src/color_reduce.cpp" \
  "$SRC/src/board_config.cpp" "$SRC/lib/trmnl/src/png_flip.cpp" \
  "$SRC/mayhem/harnesses/fuzz_image_render.cpp"
# parseBMPHeader() reads its header fields with unaligned uint32_t/uint16_t loads at fixed offsets
# (data[18], data[22], ...) of every BMP, by design; UBSan's `alignment` check alone is relaxed on
# that one file so it does not fire on every BMP input. ASan and the rest of UBSan stay on.
compile "$OUT/img-fw" "$CXX" $SANITIZER_FLAGS -fno-sanitize=alignment $FUZZ_COV_FLAGS $DEBUG_FLAGS -std=gnu++17 \
  "${IMGDEFS[@]}" -- "$SRC/lib/trmnl/src/bmp.cpp"
IMGOBJS=("$OUT"/img-fw/*.o "$OUT"/img-deps/*.o "$OUT/lsan_off.o")
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "${IMGOBJS[@]}" -o /mayhem/fuzz_image_render
$CXX $SANITIZER_FLAGS $FUZZ_COV_FLAGS $DEBUG_FLAGS "$OUT/standalone_main.o" "${IMGOBJS[@]}" -o /mayhem/fuzz_image_render-standalone

# The same harness built as the 4-colour TRMNL ([env:trmnl_4clr]: BOARD_TRMNL_4CLR compiles in
# png_render.cpp's png_draw_4clr path). Deps are identical (PNG_MAX_BUFFERED_PIXELS matches).
IMG4DEFS=("${IMGDEFS[@]/-DBOARD_TRMNL/-DBOARD_TRMNL_4CLR}")
IMG4DEFS=("${IMG4DEFS[@]/-DDEVICE_MODEL=\"og\"/-DDEVICE_MODEL=\"og_4clr\"}")
compile "$OUT/img4-fw" "$CXX" $SANITIZER_FLAGS $FUZZ_COV_FLAGS $DEBUG_FLAGS -std=gnu++17 "${IMG4DEFS[@]}" -- \
  "$SRC/src/png_render.cpp" "$SRC/src/jpeg_render.cpp" "$SRC/src/color_reduce.cpp" \
  "$SRC/src/board_config.cpp" "$SRC/lib/trmnl/src/png_flip.cpp" \
  "$SRC/mayhem/harnesses/fuzz_image_render.cpp"
compile "$OUT/img4-fw" "$CXX" $SANITIZER_FLAGS -fno-sanitize=alignment $FUZZ_COV_FLAGS $DEBUG_FLAGS -std=gnu++17 \
  "${IMG4DEFS[@]}" -- "$SRC/lib/trmnl/src/bmp.cpp"
IMG4OBJS=("$OUT"/img4-fw/*.o "$OUT"/img-deps/*.o "$OUT/lsan_off.o")
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "${IMG4OBJS[@]}" -o /mayhem/fuzz_image_render_4clr
$CXX $SANITIZER_FLAGS $FUZZ_COV_FLAGS $DEBUG_FLAGS "$OUT/standalone_main.o" "${IMG4OBJS[@]}" -o /mayhem/fuzz_image_render_4clr-standalone

# ---------------------------------------------------------------------------------------------
# 3) upstream's native unit tests (test/test_*), normal flags, as `pio test -e native` builds them
# ---------------------------------------------------------------------------------------------
TESTDEFS=(-DARDUINOJSON_ENABLE_ARDUINO_STRING=1 -DARDUINOJSON_DEBUG=1 -DARDUINO=111 -DPIO_UNIT_TESTING
          -Wno-missing-template-arg-list-after-template-kw -include stdint.h -std=gnu++17 -I"$FAKE" -I"$FAKE/arduino" -I"$AJ" -I"$UNITY"
          -I"$SRC/lib/trmnl/include" -I"$SRC/lib/trmnl/include/api-client" -I"$SRC/test/common"
          -I"$SRC/include" $COVERAGE_FLAGS)
compile "$OUT/test-deps" "$CXX" -O1 -w "${TESTDEFS[@]}" -- "$FAKE"/*.cpp "$FAKE"/arduino/*.cpp
compile "$OUT/test-deps" "$CC" -O1 -w -I"$UNITY" -- "$FAKE/arduino/noniso.c" "$UNITY/unity.c"
compile "$OUT/test-lib" "$CXX" -O1 "${TESTDEFS[@]}" -- \
  "$SRC"/lib/trmnl/src/*.cpp "$SRC"/lib/trmnl/src/api-client/*.cpp "$SRC/test/common/memory_persistence.cpp"
mkdir -p "$OUT/tests"
for t in "$SRC"/test/test_*/; do
  name=$(basename "$t")
  $CXX -O1 "${TESTDEFS[@]}" "$t"*.cpp "$OUT"/test-lib/*.o "$OUT"/test-deps/*.o $COVERAGE_FLAGS \
    -o "$OUT/tests/$name"
done
echo "build.sh: done"
