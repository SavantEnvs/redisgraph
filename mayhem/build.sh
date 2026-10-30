#!/usr/bin/env bash
#
# mayhem/build.sh — build RedisGraph's query front end for fuzzing, plus the known-answer probe test.sh runs.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem; air-gapped and re-runnable.
# RedisGraph is a redis module, so no redis-server is involved: every .c under src/ is compiled
# (except src/module.c, the module entry point) and linked with the harness, which drives
# parse -> validate -> AST -> execution plan directly (see mayhem/rg_harness.h).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# bin/ is gitignored upstream, so a `git clean -ffdX` removes everything built here
B="$SRC/bin/mayhem"
mkdir -p "$B"

# Two RedisGraph/dependency builds share one GraphBLAS: the sanitized one linked into the fuzzers,
# and a normal-flags one linked into the test probe.
#   san   : $SANITIZER_FLAGS $DEBUG_FLAGS + -fsanitize=fuzzer-no-link (coverage for libFuzzer)
#   plain : -O2 $COVERAGE_FLAGS
# Checks relaxed on the sanitized build, for benign upstream patterns that fire on every query:
#   alignment             src/util/arr.h puts a 12-byte header in front of the elements, so every
#                         array of pointers is 4-byte aligned, and libcypher-parser does the same
#   function              procedure registration calls constructors through a differently typed pointer
#   nonnull-attribute, pointer-overflow   libcypher-parser memcpy(dst, NULL, 0) / NULL + 0
RELAX="-fno-sanitize=alignment,function,nonnull-attribute,pointer-overflow"
SAN_FLAGS="-O1 -fPIC $SANITIZER_FLAGS $RELAX $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
PLAIN_FLAGS="-O2 -fPIC $COVERAGE_FLAGS"

# --- GraphBLAS (vendored; built once, not instrumented: the query-compile path never reaches it) ---
cmake -S deps/GraphBLAS -B "$B/gb" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="-fPIC -g -gdwarf-3" -DCMAKE_C_FLAGS_RELEASE="-O1 -DNDEBUG" \
    -DNSTATIC=off -DBUILD_TESTING=off -DCMAKE_POSITION_INDEPENDENT_CODE=on >/dev/null
cmake --build "$B/gb" --target graphblas_static -j"$MAYHEM_JOBS"

# --- libcypher-parser: autotools, generated in a scratch copy so the submodule stays clean ---
rm -rf "$B/cp-src"
cp -a deps/libcypher-parser "$B/cp-src"
rm -f "$B/cp-src/.git"
(cd "$B/cp-src" && ./autogen.sh >/dev/null 2>&1)

# build_variant <name> <cflags>  ->  $B/<name>/{obj/*.o,libs}
build_variant() {
    local name="$1" cflags="$2" d="$B/$1"
    rm -rf "$d"; mkdir -p "$d/obj" "$d/cp" "$d/small" "$d/onig"

    # libcypher-parser (only lib/src: the linter/CLI don't build without the full header set)
    (cd "$d/cp" && "$B/cp-src/configure" --disable-shared --enable-static --disable-werror CC="$CC" \
        CFLAGS="$cflags -DYY_BUFFER_SIZE=1048576 -w" >/dev/null \
     && make -C lib/src -j"$MAYHEM_JOBS" >/dev/null)

    # rax, xxHash, utf8proc
    $CC $cflags -w -c deps/rax/rax.c -o "$d/small/rax.o"
    $CC $cflags -w -c deps/xxHash/xxhash.c -o "$d/small/xxhash.o"
    $CC $cflags -w -DUTF8PROC_STATIC -c deps/utf8proc/utf8proc.c -o "$d/small/utf8proc.o"
    ar rcs "$d/small/libdeps.a" "$d/small"/rax.o "$d/small"/xxhash.o "$d/small"/utf8proc.o

    # oniguruma (cmake; only the library target, its windows test target needs MSVC flags)
    cmake -S deps/oniguruma -B "$d/onig" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="$cflags -w" -DBUILD_SHARED_LIBS=OFF -DENABLE_POSIX_API=OFF >/dev/null 2>&1
    cmake --build "$d/onig" --target onig -j"$MAYHEM_JOBS" >/dev/null

    # RedisGraph itself. -fcommon: upstream defines globals in headers (e.g. `dictType def_dt;`),
    # which gcc, the compiler upstream builds with, merges.
    export RG_CFLAGS="-std=gnu11 -fopenmp -D_GNU_SOURCE -DREDIS_MODULE_TARGET -DREDISMODULE_EXPERIMENTAL_API \
-DREDISEARCH_API_EXTERN -fcommon -DXXH_STATIC_LINKING_ONLY -I$SRC/src -I$SRC -I$SRC/deps -I$SRC/deps/rax \
-I$SRC/deps/xxHash -I$SRC/deps/utf8proc -I$SRC/deps/oniguruma -I$SRC/deps/RediSearch/src \
-I$SRC/deps/GraphBLAS/Include -I$SRC/deps/libcypher-parser/lib/src -I$d/cp/lib/src -w $cflags"
    export RG_OBJ="$d/obj"
    find src -name '*.c' ! -path src/module.c | sort | xargs -P "$MAYHEM_JOBS" -I{} bash -c \
        'o="$RG_OBJ/$(echo "{}" | tr / _).o"; '"$CC"' $RG_CFLAGS -c "{}" -o "$o"'

    # link glue (siphash + RediSearch C-API pointers) and the harness TUs
    $CC $RG_CFLAGS -c mayhem/deps_glue.c -o "$d/glue.o"
    $CC $RG_CFLAGS -c mayhem/fuzz_query_plan.c -o "$d/fuzz_query_plan.o"
    $CC $RG_CFLAGS -c mayhem/kat_probe.c -o "$d/kat_probe.o"
}

# libs in link order, relative to a variant dir
rg_libs() { echo "$1/obj/"*.o "$1/glue.o" "$1/cp/lib/src/.libs/libcypher-parser.a" "$B/gb/libgraphblas.a" \
    "$1/small/libdeps.a" "$1/onig/libonig.a" -lm -lpthread -ldl; }

# ===== 1) sanitized build + fuzz / standalone binaries =====
build_variant san "$SAN_FLAGS"

$CXX $SANITIZER_FLAGS -c mayhem/lsan_off.cc -o "$B/lsan_off.o"

$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE -fopenmp "$B/san/fuzz_query_plan.o" "$B/lsan_off.o" \
    $(rg_libs "$B/san") -o /mayhem/fuzz_query_plan
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -fopenmp "$STANDALONE_FUZZ_MAIN" "$B/san/fuzz_query_plan.o" "$B/lsan_off.o" \
    $(rg_libs "$B/san") -o /mayhem/fuzz_query_plan-standalone

# ===== 2) normal-flags build + known-answer probe for mayhem/test.sh =====
build_variant plain "$PLAIN_FLAGS"
$CC -fopenmp $COVERAGE_FLAGS "$B/plain/kat_probe.o" $(rg_libs "$B/plain") -o /mayhem/kat_probe
