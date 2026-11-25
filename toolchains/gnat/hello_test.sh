#!/usr/bin/env bash
# Copyright 2026 hdl-simbench authors.
# SPDX-License-Identifier: Apache-2.0
#
# The Ada program linked with //toolchains/gnat: lld linked it, it needs
# only glibc 2.31 or older from the host, with no symbol version tied to a
# newer or particular glibc, and it runs (including a call that reaches
# fcntl through libgnat). The libgnat.a copy has no fcntl64 left.
set -euo pipefail
bin="$1" readelf="$2" libgnat="$3" nm="$4"
fail() { echo "FAIL: $*" >&2; exit 1; }

"$readelf" -p .comment "$bin" | grep -q 'Linker: LLD' || fail "not linked by lld"
needed="$("$readelf" -d "$bin" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
echo "NEEDED: $needed"
for n in $needed; do
  case " libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 ld-linux-x86-64.so.2 " in
    *" $n "*) ;;
    *) fail "needs $n from the host" ;;
  esac
done
ver="$("$readelf" -V "$bin")"
glibc="$({ grep -o 'GLIBC_[0-9][0-9.]*' <<< "$ver" || true; } | sed 's/GLIBC_//' | sort -V | tail -1)"
echo "GLIBC: ${glibc:-none}"
if [[ -n "$glibc" && "$(printf '%s\n2.31\n' "$glibc" | sort -V | tail -1)" != 2.31 ]]; then
  fail "needs glibc $glibc, newer than the sysroot's 2.31"
fi
odd="$({ grep -o 'GLIBC_[A-Za-z0-9_.]*' <<< "$ver" || true; } | { grep -v '^GLIBC_[0-9][0-9.]*$' || true; } | sort -u | tr '\n' ' ')"
[[ -z "$odd" ]] || fail "needs glibc symbol versions $odd"
if "$nm" "$libgnat" 2>/dev/null | grep -qw fcntl64; then fail "$libgnat still has fcntl64"; fi
out="$("$bin")"
[[ "$out" == "hello from GNAT" ]] || fail "output: $out"
echo PASS
