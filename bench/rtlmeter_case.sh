#!/usr/bin/env bash
# Copyright 2026 hdl-simbench authors.
# SPDX-License-Identifier: Apache-2.0
#
# Runs one RTLMeter case with one SystemVerilog simulator, and checks it the
# way RTLMeter does: the harness (third_party/rtlmeter/rtl) counts cycles of
# the main clock and writes the count to _rtlmeter_cycles.txt when the
# simulation ends. The count must equal the case's expected cycles, and the
# output must contain each --expect line.
#
# Every simulator gets the same sources, defines, top module and plusargs.
# The compile step and the run step are timed separately, in seconds, and
# written to the --timing file (one "step seconds" pair per line) when given.
#
# Usage:
#   rtlmeter_case.sh --sim verilator|iverilog
#       --tool <simulator binary> [--tool2 <vvp, for iverilog>]
#       [--ivl-base <iverilog's base directory>] [--incdir <dir>]...
#       [--verilator-root <dir holding include/>]
#       --top <module> --clock <hierarchical clock, e.g. top.clk>
#       --cycles <expected cycles> [--define NAME[=VALUE]]...
#       [--plusarg +x=y]... [--expect <text>]... [--timing <file>]
#       -- <source files>...

set -euo pipefail

sim="" tool="" tool2="" vroot="" ivlbase="" top="" clock="" cycles="" timing=""
defines=() plusargs=() expects=() extra_incdirs=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sim) sim="$2"; shift 2 ;;
    --tool) tool="$2"; shift 2 ;;
    --tool2) tool2="$2"; shift 2 ;;
    --verilator-root) vroot="$2"; shift 2 ;;
    --ivl-base) ivlbase="$2"; shift 2 ;;
    --incdir) extra_incdirs+=("$2"); shift 2 ;;
    --top) top="$2"; shift 2 ;;
    --clock) clock="$2"; shift 2 ;;
    --cycles) cycles="$2"; shift 2 ;;
    --define) defines+=("$2"); shift 2 ;;
    --plusarg) plusargs+=("$2"); shift 2 ;;
    --expect) expects+=("$2"); shift 2 ;;
    --timing) timing="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
srcs=("$@")
for v in sim tool top clock cycles; do
  if [[ -z "${!v}" ]]; then echo "missing --${v}" >&2; exit 2; fi
done
if [[ ${#srcs[@]} -eq 0 ]]; then echo "no sources" >&2; exit 2; fi

# Absolute paths, since the steps below change directory.
abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
tool="$(abs "$tool")"
[[ -n "$tool2" ]] && tool2="$(abs "$tool2")"
[[ -n "$vroot" ]] && vroot="$(abs "$vroot")"
[[ -n "$ivlbase" ]] && ivlbase="$(abs "$ivlbase")"
asrcs=()
incdirs=()
for s in "${srcs[@]}"; do
  a="$(abs "$s")"
  asrcs+=("$a")
  incdirs+=("$(dirname "$a")")
done
# Every source directory is an include directory, and so is each --incdir
# (for example the one holding "__rtlmeter_top_include.vh", which designs
# include and which is never compiled on its own).
for d in "${extra_incdirs[@]}"; do
  d="$(abs "$d")"
  # A file names its own directory: Bazel hands over files, not directories.
  [[ -f "$d" ]] && d="$(dirname "$d")"
  incdirs+=("$d")
done
mapfile -t incdirs < <(printf '%s\n' "${incdirs[@]}" | sort -u)

work="${TEST_TMPDIR:-$(mktemp -d)}/work"
rm -rf "$work"
mkdir -p "$work"
cd "$work"

# The harness names the main clock through this define.
defines+=("__RTLMETER_MAIN_CLOCK=${clock}")

now() { date +%s.%N; }
record() { [[ -n "$timing" ]] && printf '%s %s\n' "$1" "$2" >> "$timing"; return 0; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", b - a }'; }

case "$sim" in
  verilator)
    # The prebuilt Verilator has no verilated.mk, so it cannot build its
    # own model with --binary. It writes the C++ here, and the C++ is
    # compiled below with the host compiler at -O2, the optimization level
    # Verilator's own build uses by default (OPT_FAST).
    # @verilator_prebuilt puts the binary at the repository root, beside
    # its include/ tree, so that root is the default VERILATOR_ROOT.
    if [[ -z "$vroot" ]]; then vroot="$(dirname "$tool")"; fi
    vargs=(--cc --main --timing --top-module "$top" -Wno-fatal -Wno-lint -Wno-style
           --Mdir obj -o sim)
    for d in "${defines[@]}"; do vargs+=("-D${d}"); done
    for i in "${incdirs[@]}"; do vargs+=("-I${i}"); done
    t0="$(now)"
    VERILATOR_ROOT="$vroot" "$tool" "${vargs[@]}" "${asrcs[@]}"
    inc="$vroot/include"
    cxx="${CXX:-c++}"
    "$cxx" -std=c++20 -O2 -fcoroutines -DVM_TRACE=0 -DVL_TIME_CONTEXT \
      -I obj -I "$inc" -I "$inc/vltstd" \
      obj/*.cpp \
      "$inc/verilated.cpp" "$inc/verilated_threads.cpp" \
      "$inc/verilated_timing.cpp" "$inc/verilated_random.cpp" \
      -o obj/sim -pthread -lpthread -latomic
    t1="$(now)"
    record compile "$(elapsed "$t0" "$t1")"
    t0="$(now)"
    ./obj/sim "${plusargs[@]}" | tee sim.log
    t1="$(now)"
    record run "$(elapsed "$t0" "$t1")"
    ;;
  iverilog)
    if [[ -z "$tool2" ]]; then echo "--tool2 <vvp> is needed" >&2; exit 2; fi
    if [[ -z "$ivlbase" ]]; then echo "--ivl-base is needed" >&2; exit 2; fi
    # -B: where the driver finds ivl, ivlpp and the code generators; in a
    # Bazel build that is @iverilog//:ivl_base, not an install prefix.
    iargs=(-B "$ivlbase" -g2012 -s "$top" -o sim.vvp)
    for d in "${defines[@]}"; do iargs+=("-D${d}"); done
    for i in "${incdirs[@]}"; do iargs+=("-I${i}"); done
    t0="$(now)"
    "$tool" "${iargs[@]}" "${asrcs[@]}"
    t1="$(now)"
    record compile "$(elapsed "$t0" "$t1")"
    t0="$(now)"
    # -M: where vvp finds system.vpi and the other VPI modules.
    "$tool2" -M "$ivlbase" -n sim.vvp "${plusargs[@]}" | tee sim.log
    t1="$(now)"
    record run "$(elapsed "$t0" "$t1")"
    ;;
  *)
    echo "unknown simulator: $sim" >&2
    exit 2
    ;;
esac

got="$(cat _rtlmeter_cycles.txt 2>/dev/null || echo missing)"
if [[ "$got" != "$cycles" ]]; then
  echo "FAIL: $sim ran $got cycles, expected $cycles" >&2
  exit 1
fi
for e in "${expects[@]}"; do
  if ! grep -q -F -- "$e" sim.log; then
    echo "FAIL: $sim output lacks: $e" >&2
    exit 1
  fi
done
echo "PASS: $sim, $got cycles"
