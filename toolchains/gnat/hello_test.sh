#!/usr/bin/env bash
# Copyright 2026 hdl-simbench authors.
# SPDX-License-Identifier: Apache-2.0
#
# The Ada program linked with //toolchains/gnat needs only glibc 2.31 or
# older from the host, and runs.
set -euo pipefail
bin="$1" readelf="$2"
needed="$("$readelf" -d "$bin" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
echo "NEEDED: $needed"
for n in $needed; do
  case " libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 ld-linux-x86-64.so.2 " in
    *" $n "*) ;;
    *) echo "FAIL: needs $n from the host" >&2; exit 1 ;;
  esac
done
glibc="$("$readelf" -V "$bin" | { grep -o 'GLIBC_[0-9][0-9.]*' || true; } | sed 's/GLIBC_//' | sort -V | tail -1)"
echo "GLIBC: ${glibc:-none}"
if [[ -n "$glibc" && "$(printf '%s\n2.31\n' "$glibc" | sort -V | tail -1)" != 2.31 ]]; then
  echo "FAIL: needs glibc $glibc, newer than the sysroot's 2.31" >&2
  exit 1
fi
out="$("$bin")"
[[ "$out" == "hello from GNAT" ]] || { echo "FAIL: output: $out" >&2; exit 1; }
echo PASS
