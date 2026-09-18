#!/bin/sh
# Build libnoquit.so. Requires gcc (or clang) only.
set -eu
cd "$(dirname "$0")"
CC="${CC:-cc}"
$CC -shared -fPIC -O2 -Wall -Wextra \
    -Wl,--version-script=noquit.map \
    -o libnoquit.so noquit.c

echo "built $(pwd)/libnoquit.so"
echo "exported versioned symbols:"
nm -D --with-symbol-versions libnoquit.so | grep ' T ' || true
