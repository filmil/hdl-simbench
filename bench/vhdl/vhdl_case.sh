#!/usr/bin/env bash
# Copyright 2026 hdl-simbench authors.
# SPDX-License-Identifier: Apache-2.0
#
# Runs one VHDL case with one VHDL simulator, and checks its output.
#
# Every simulator gets the same sources, libraries, top entity and VHDL
# standard (2008). Compile and run are timed separately, in the format of
# bench/rtlmeter_case.sh, which //bench:timed_runs reads. With --timing
# <file>, one line per step is appended to it,
#   <step> <wall s> <user s> <system s> <max RSS KiB>
# summed over the step's commands (RSS: the largest), measured by
# GNU time as /usr/bin/time, or "<step> <wall s>" alone without it; then
# "cycles <n>", the clock cycles the design simulated.
#
# The testbench must print "simbench cycles <n>" (n > 0) when it ends, with
# or without --timing: a run without that line fails.
#
#   compile  GHDL: analysis of every file. NVC: analysis and elaboration,
#            where NVC generates the design's machine code.
#   run      GHDL: `ghdl -r`, which with the mcode back end also generates
#            the design's machine code before it simulates. NVC: `nvc -r`.
#
# So "compile" and "run" split the work differently for the two; the sum is
# the comparable number.
#
# With --commands <file>, every simulator command is appended to it, one
# per line, as "<step> <command>", the arguments shell-quoted. Together with
# the tool's version that is the full record of how the case was built and
# run, so that the flags are on file next to each timing.
#
# Usage:
#   vhdl_case.sh --sim ghdl|nvc --tool <binary> --top <entity>
#       [--expect <text>]... [--reject <text>]... [--timing <file>]
#       [--commands <file>] [--readelf <llvm-readelf>]
#       [--allow-host-lib <soname>]...
#       -- [@lib=<library>] <file>... [@lib=<library> <file>...]...
#          [@ghdl-libs <file>...] [@nvc-libs <dir>]
#
# With --readelf, the simulator binary may take nothing from the host but
# glibc 2.31 or older, and the libraries --allow-host-lib names, as in
# rtlmeter_case.sh; its NEEDED list goes in the command record.
#
# The files after -- are analysed in the order given, each into the library
# the last @lib= names (work before any). The files after @ghdl-libs are
# GHDL's compiled std and ieee libraries (@ghdl//:vhdl_libs_v08); GHDL's
# prefix is the directory that holds their std/v08 and ieee/v08. The
# directory after @nvc-libs holds NVC's compiled standard libraries
# (@nvc_prebuilt//:std), which NVC gets with -L. Markers
# instead of flags let a Bazel $(rootpaths) expansion, which becomes one
# argument per file, follow a marker.
#
# Consecutive files of one library are analysed by one simulator command,
# in the order given, so that process start-up is not counted per file.
# The timings are written only when the run passes every check.

set -euo pipefail

sim="" tool="" prefix="" nvclibs="" top="" timing="" commands="" readelf=""
expects=() rejects=() allowed=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sim) sim="$2"; shift 2 ;;
    --tool) tool="$2"; shift 2 ;;
    --top) top="$2"; shift 2 ;;
    --expect) expects+=("$2"); shift 2 ;;
    --reject) rejects+=("$2"); shift 2 ;;
    --timing) timing="$2"; shift 2 ;;
    --commands) commands="$2"; shift 2 ;;
    --readelf) readelf="$2"; shift 2 ;;
    --allow-host-lib) allowed+=("$2"); shift 2 ;;
    --) shift; break ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
abs() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }

# srcs: "<library> <absolute file>" per entry, in analysis order.
srcs=() lib=work mode=src
for a in "$@"; do
  case "$a" in
    @lib=*) lib="${a#@lib=}"; mode=src ;;
    @ghdl-libs) mode=ghdl ;;
    @nvc-libs) mode=nvc ;;
    *)
      if [[ $mode == nvc ]]; then
        nvclibs="$(abs "$a")"
      elif [[ $mode == ghdl ]]; then
        # .../<prefix>/std/v08/std-obj08.cf -> <prefix>
        if [[ "$a" == */std/v08/std-obj08.cf ]]; then prefix="$(abs "${a%/std/v08/std-obj08.cf}")"; fi
      else
        srcs+=("$lib $(abs "$a")")
      fi
      ;;
  esac
done
if [[ -z "$sim" || -z "$tool" || -z "$top" || ${#srcs[@]} -eq 0 ]]; then
  echo "usage: vhdl_case.sh --sim ghdl|nvc --tool <binary> --top <entity> ... -- <files>" >&2
  exit 2
fi
tool="$(abs "$tool")"
# Under bazel test, the records go to the test's undeclared outputs by
# default, as rtlmeter_case.sh does, so one driver collects both sides.
if [[ -n "${TEST_UNDECLARED_OUTPUTS_DIR:-}" ]]; then
  [[ -z "$timing" ]] && timing="$TEST_UNDECLARED_OUTPUTS_DIR/timing.txt"
  [[ -z "$commands" ]] && commands="$TEST_UNDECLARED_OUTPUTS_DIR/commands.txt"
fi
[[ -n "$timing" ]] && timing="$(abs "$timing")"
[[ -n "$commands" ]] && commands="$(abs "$commands")"
[[ -n "$readelf" ]] && readelf="$(abs "$readelf")"

work="$(mktemp -d "${TEST_TMPDIR:-${TMPDIR:-/tmp}}/vhdl_case.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cd "$work"

now() { date +%s.%N; }
log_command() {
  [[ -n "$commands" ]] || return 0
  { printf '%s' "$1"; shift; printf ' %q' "$@"; printf '\n'; } >> "$commands"
}
# GNU time's -f, -a and -o; another /usr/bin/time (BusyBox) takes the
# fallback.
gnu_time=0
if [[ -x /usr/bin/time ]] && /usr/bin/time -f %e -a -o /dev/null true 2> /dev/null; then gnu_time=1; fi
# step: runs the command after the step name, records it, and appends its
# measurement, "<step> <wall> <user> <system> <max RSS>", to steps.txt.
# The timing file gets the sums only once the run has passed.
step() {
  local name="$1" st=0 t0 t1; shift
  log_command "$name" "$@"
  if [[ $gnu_time == 1 ]]; then
    /usr/bin/time -f "$name %e %U %S %M" -a -o "$work/steps.txt" "$@" || st=$?
  else
    t0="$(now)"
    "$@" || st=$?
    t1="$(now)"
    awk -v s="$name" -v a="$t0" -v b="$t1" 'BEGIN { printf "%s %.3f\n", s, b - a }' >> "$work/steps.txt"
  fi
  return $st
}
# The same rule as rtlmeter_case.sh's check_elf.
glibc_libs=" libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 libutil.so.1 libresolv.so.2 libmvec.so.1 ld-linux-x86-64.so.2 "
check_elf() {
  [[ -n "$readelf" ]] || return 0
  local bin="$1" needed glibc bad="" n a path sum
  local dyn ver odd
  dyn="$("$readelf" -d "$bin")" || { echo "FAIL: $readelf -d $bin failed" >&2; exit 1; }
  ver="$("$readelf" -V "$bin")" || { echo "FAIL: $readelf -V $bin failed" >&2; exit 1; }
  needed="$(sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' <<< "$dyn" | tr '\n' ' ')"
  glibc="$({ grep -o 'GLIBC_[0-9][0-9.]*' <<< "$ver" || true; } | sed 's/GLIBC_//' | sort -V | tail -1)"
  # Symbol versions that are not a release number (GLIBC_PRIVATE,
  # GLIBC_ABI_DT_RELR from glibc 2.36) tie a binary to a newer or a
  # particular glibc.
  odd="$({ grep -o 'GLIBC_[A-Za-z0-9_.]*' <<< "$ver" || true; } | { grep -v '^GLIBC_[0-9][0-9.]*$' || true; } | sort -u | tr '\n' ' ')"
  log_command elf "$bin" "NEEDED: ${needed% }" "GLIBC: ${glibc:-none}"
  if command -v ldd > /dev/null; then
    { ldd "$bin" 2>&1 || true; } | while IFS= read -r l; do log_command ldd "$bin" "$l"; done
  fi
  for n in $needed; do
    [[ "$glibc_libs" == *" $n "* ]] && continue
    for a in "${allowed[@]}"; do
      if [[ "$n" == "$a" ]]; then
        path="$({ ldd "$bin" 2>/dev/null || true; } | awk -v l="$a" '$1 == l { print $3 }')"
        sum=""
        [[ -f "$path" ]] && sum="$(sha256sum "$path" | cut -d' ' -f1)"
        log_command host-lib "$bin" "$a" "${path:-?}" "sha256:${sum:-?}"
        continue 2
      fi
    done
    bad+=" $n"
  done
  if [[ -n "$odd" ]]; then
    echo "FAIL: $bin needs glibc symbol versions tied to a newer or particular glibc: ${odd% }" >&2
    exit 1
  fi
  if [[ -n "$bad" ]]; then
    echo "FAIL: $bin needs libraries from the host other than glibc's:$bad" >&2
    exit 1
  fi
  if [[ -n "$glibc" && "$(printf '%s\n2.31\n' "$glibc" | sort -V | tail -1)" != 2.31 ]]; then
    echo "FAIL: $bin needs glibc $glibc, newer than the sysroot's 2.31" >&2
    # Which symbols: those bound to a version newer than 2.31.
    "$readelf" --dyn-syms --wide "$bin" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /@GLIBC_[0-9]/) print $i }' |
      sed -n 's/.*@\(GLIBC_[0-9.]*\).*/&/p' | sort -u |
      while IFS= read -r sym; do
        v="${sym##*@GLIBC_}"
        if [[ "$(printf '%s\n2.31\n' "$v" | sort -V | tail -1)" != 2.31 ]]; then echo "  $sym" >&2; fi
      done || true
    exit 1
  fi
}
check_elf "$tool"
# groups: one "<library>\t<file> <file>..." entry per run of consecutive
# files in the same library, in analysis order.
groups=() glib="" gfiles=""
for s in "${srcs[@]}"; do
  l="${s%% *}" f="${s#* }"
  if [[ "$l" != "$glib" && -n "$gfiles" ]]; then groups+=("$glib"$'\t'"$gfiles"); gfiles=""; fi
  glib="$l" gfiles="${gfiles:+$gfiles }$f"
done
groups+=("$glib"$'\t'"$gfiles")

case "$sim" in
  ghdl)
    if [[ -z "$prefix" ]]; then echo "ghdl needs @ghdl-libs with std/v08/std-obj08.cf" >&2; exit 2; fi
    export GHDL_PREFIX="$prefix"
    if [[ -n "$commands" ]]; then printf 'env GHDL_PREFIX=%q\n' "$GHDL_PREFIX" >> "$commands"; fi
    common=(--std=08 --workdir=lib -Plib)
    mkdir lib
    for g in "${groups[@]}"; do
      read -r -a files <<< "${g#*$'\t'}"
      step compile "$tool" -a "${common[@]}" --work="${g%%$'\t'*}" "${files[@]}"
    done
    # As NEORV32's own sim/ghdl.sh runs it.
    run=("$tool" -r "${common[@]}" "$top" --max-stack-alloc=0 --ieee-asserts=disable --assert-level=error)
    ;;
  nvc)
    if [[ -z "$nvclibs" ]]; then echo "nvc needs @nvc-libs <dir>" >&2; exit 2; fi
    common=(--std=2008 -L "$nvclibs")
    mkdir lib
    for g in "${groups[@]}"; do
      l="${g%%$'\t'*}"
      read -r -a files <<< "${g#*$'\t'}"
      step compile "$tool" "${common[@]}" --work="$l:lib/$l" -L lib -a "${files[@]}"
    done
    # -O2 is NVC's default code generation level, written out so that the
    # record shows it.
    step compile "$tool" "${common[@]}" --work=work:lib/work -L lib -e -O2 "$top"
    run=("$tool" "${common[@]}" --work=work:lib/work -L lib -r "$top" --ieee-warnings=off --exit-severity=error)
    ;;
  *)
    echo "unknown simulator: $sim" >&2
    exit 2
    ;;
esac
status=0
step run "${run[@]}" > stdout.log 2>&1 || status=$?
cat stdout.log
if [[ $status -ne 0 ]]; then
  echo "FAIL: $sim exited with status $status" >&2
  exit 1
fi
for e in "${expects[@]}"; do
  if ! grep -q -F -- "$e" stdout.log; then
    echo "FAIL: $sim output lacks: $e" >&2
    exit 1
  fi
done
for r in "${rejects[@]}"; do
  if grep -q -F -- "$r" stdout.log; then
    echo "FAIL: $sim output has: $r" >&2
    exit 1
  fi
done
cycles="$(sed -n -E 's/.*simbench cycles ([1-9][0-9]*)([^0-9.A-Za-z_]|$).*/\1/p' stdout.log | tail -1)"
if [[ -z "$cycles" ]]; then
  echo "FAIL: $sim output lacks the testbench's \"simbench cycles <n>\" line, n > 0" >&2
  exit 1
fi
if [[ -n "$timing" ]]; then
  for s in compile run; do
    awk -v s="$s" '$1 == s {
        w += $2; u += $3; y += $4; if ($5 > m) m = $5; n = NF
      }
      END {
        if (n >= 5) printf "%s %.2f %.2f %.2f %d\n", s, w, u, y, m
        else printf "%s %.3f\n", s, w
      }' "$work/steps.txt" >> "$timing"
  done
  echo "cycles $cycles" >> "$timing"
fi
echo "PASS: $sim"
