#!/usr/bin/env bash
# Copyright 2026 hdl-simbench authors.
# SPDX-License-Identifier: Apache-2.0
#
# Runs one RTLMeter case with one SystemVerilog simulator, and checks it the
# way RTLMeter does (src/rtlmeter/subcommands/run.py there):
#
#   - Sources and include files are linked, flattened by base name, into
#     verilogSourceFiles/ and verilogIncludeFiles/; the latter is the
#     include path. Test files are linked into the run directory.
#   - The design's post hook, if any, runs in the run directory after the
#     simulation, with the simulator's output in _execute/stdout.log.
#   - The harness's cycle count (_rtlmeter_cycles.txt) must equal the
#     expected cycles, when the case gives them.
#
# Every simulator gets the same sources, defines, parameters, top module and
# plusargs. Compile and run are timed separately; with --timing <file>, one
# "step seconds" pair per line is appended to it.
#
# Usage:
#   rtlmeter_case.sh --sim verilator|iverilog|xezim --tool <binary>
#       [--tool2 <vvp>] [--ivl-base <dir>] [--verilator-root <dir>]
#       --top <module> [--cycles <expected>]
#       [--define NAME=VALUE]... [--param NAME=VALUE]...
#       [--verilator-arg ARG]... [--plusarg +x=y]... [--expect <text>]...
#       [--include <file>]... [--file <file>]... [--post-hook <script>]
#       [--cpp-src <file>]... (DPI-C sources; Verilator only)
#       [--smoke]   (a run cut short by +max_cycles: as in RTLMeter, no
#                    cycle check and no post hook)
#       [--timing <file>]
#       -- <source files>...

set -euo pipefail

sim="" tool="" tool2="" vroot="" ivlbase="" top="" cycles="" timing="" posthook="" smoke=""
defines=() params=() vargs=() plusargs=() expects=() includes=() files=() cpps=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sim) sim="$2"; shift 2 ;;
    --tool) tool="$2"; shift 2 ;;
    --tool2) tool2="$2"; shift 2 ;;
    --verilator-root) vroot="$2"; shift 2 ;;
    --ivl-base) ivlbase="$2"; shift 2 ;;
    --top) top="$2"; shift 2 ;;
    --cycles) cycles="$2"; shift 2 ;;
    --define) defines+=("$2"); shift 2 ;;
    --param) params+=("$2"); shift 2 ;;
    --verilator-arg) vargs+=("$2"); shift 2 ;;
    --plusarg) plusargs+=("$2"); shift 2 ;;
    --expect) expects+=("$2"); shift 2 ;;
    --include) includes+=("$2"); shift 2 ;;
    --file) files+=("$2"); shift 2 ;;
    --post-hook) posthook="$2"; shift 2 ;;
    --cpp-src) cpps+=("$2"); shift 2 ;;
    --smoke) smoke=1; shift ;;
    --timing) timing="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
srcs=("$@")
for v in sim tool top; do
  if [[ -z "${!v}" ]]; then echo "missing --${v}" >&2; exit 2; fi
done
if [[ ${#srcs[@]} -eq 0 ]]; then echo "no sources" >&2; exit 2; fi

abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
tool="$(abs "$tool")"
[[ -n "$tool2" ]] && tool2="$(abs "$tool2")"
[[ -n "$vroot" ]] && vroot="$(abs "$vroot")"
[[ -n "$ivlbase" ]] && ivlbase="$(abs "$ivlbase")"
[[ -n "$timing" ]] && timing="$(abs "$timing")"
[[ -n "$posthook" ]] && posthook="$(abs "$posthook")"
cppfiles=()
for c in "${cpps[@]}"; do cppfiles+=("$(abs "$c")"); done

work="${TEST_TMPDIR:-$(mktemp -d)}/work"
rm -rf "$work"
mkdir -p "$work/verilogSourceFiles" "$work/verilogIncludeFiles" "$work/run/_execute"

# Link files by base name into a directory; two files with one name would
# make the case ambiguous, as in RTLMeter, so that is an error.
link_into() {
  local dir="$1"; shift
  local f
  for f in "$@"; do
    local dst="$dir/$(basename "$f")"
    if [[ -e "$dst" ]]; then echo "two files named $(basename "$f")" >&2; exit 2; fi
    ln -s "$(abs "$f")" "$dst"
  done
}
link_into "$work/verilogSourceFiles" "${srcs[@]}"
link_into "$work/verilogIncludeFiles" "${includes[@]}"
link_into "$work/run" "${files[@]}"

sources=()
for s in "${srcs[@]}"; do sources+=("$work/verilogSourceFiles/$(basename "$s")"); done
incdir="$work/verilogIncludeFiles"

now() { date +%s.%N; }
record() { [[ -n "$timing" ]] && printf '%s %s\n' "$1" "$2" >> "$timing"; return 0; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", b - a }'; }

cd "$work"
case "$sim" in
  verilator)
    # @verilator_prebuilt puts the binary at the repository root, beside
    # its include/ tree, so that root is the default VERILATOR_ROOT.
    if [[ -z "$vroot" ]]; then vroot="$(dirname "$tool")"; fi
    # The prebuilt Verilator has no verilated.mk, so it cannot build its
    # own model with --binary. It writes the C++ to obj/, and the C++ is
    # compiled below with the host compiler at -O2, the optimization level
    # Verilator's own build uses by default (OPT_FAST). The options are
    # RTLMeter's (src/rtlmeter/verilator.py), less --quiet-stats.
    a=(--cc --main --timing -Wno-fatal --top-module "$top" "+incdir+$incdir" --Mdir obj -o sim)
    for d in "${defines[@]}"; do a+=("+define+${d}"); done
    for p in "${params[@]}"; do a+=("-G${p}"); done
    a+=("${vargs[@]}")
    t0="$(now)"
    VERILATOR_ROOT="$vroot" "$tool" "${a[@]}" "${sources[@]}"
    inc="$vroot/include"
    "${CXX:-c++}" -std=c++20 -O2 -fcoroutines -DVM_TRACE=0 \
      -I obj -I "$inc" -I "$inc/vltstd" \
      obj/*.cpp "${cppfiles[@]}" \
      "$inc/verilated.cpp" "$inc/verilated_threads.cpp" \
      "$inc/verilated_timing.cpp" "$inc/verilated_random.cpp" \
      -o obj/sim -pthread -lpthread -latomic
    t1="$(now)"
    record compile "$(elapsed "$t0" "$t1")"
    run=("$work/obj/sim")
    ;;
  iverilog)
    if [[ ${#cpps[@]} -gt 0 ]]; then echo "Icarus has no DPI-C" >&2; exit 2; fi
    if [[ -z "$tool2" || -z "$ivlbase" ]]; then
      echo "--tool2 <vvp> and --ivl-base are needed" >&2; exit 2
    fi
    # The BCR build compiles in IVL_ROOT="ivl", a path relative to the
    # working directory, and looks for it before it reads -B; without it
    # the driver aborts in find_ivl_root. So ./ivl is the base directory
    # (@iverilog//:ivl_base), named also by -B and by IVL_BASE, as the
    # module's own smoke test does.
    ln -sfn "$ivlbase" ivl
    export IVL_BASE="$ivlbase"
    a=(-B "$ivlbase" -g2012 -s "$top" -I "$incdir" -o sim.vvp)
    for d in "${defines[@]}"; do a+=("-D${d}"); done
    # Parameter overrides of the top module: Verilator's -G<name>=<value>.
    for p in "${params[@]}"; do a+=("-P${top}.${p}"); done
    t0="$(now)"
    "$tool" "${a[@]}" "${sources[@]}"
    t1="$(now)"
    record compile "$(elapsed "$t0" "$t1")"
    # -M: where vvp finds system.vpi and the other VPI modules.
    run=("$tool2" -M "$ivlbase" -n "$work/sim.vvp")
    ;;
  xezim)
    # Compile and run are separate steps, so that they are timed apart:
    # --compile writes the elaborated design, which a second call runs.
    # --no-cache: xezim otherwise caches elaborated designs in ~/.cache,
    # and a cached compile would not be timed honestly. Strict IEEE 1800
    # (no --relax-* switch), as the other simulators get no allowances.
    a=(--no-cache --compile -o "$work/design.xzc" -s "$top" "+incdir+$incdir")
    for d in "${defines[@]}"; do a+=("+define+${d}"); done
    # Verilator's -G<name>=<value> sets a parameter of the top module;
    # -g/<top>/<name>=<value> is xezim's form limited to that module.
    for p in "${params[@]}"; do a+=("-g/${top}/${p}"); done
    t0="$(now)"
    "$tool" "${a[@]}" "${sources[@]}"
    t1="$(now)"
    record compile "$(elapsed "$t0" "$t1")"
    # DPI C/C++ sources are not part of the compiled design: they are named
    # again when it runs, and xezim compiles them with the host compiler.
    run=("$tool" --no-cache "$work/design.xzc" "${cppfiles[@]}")
    ;;
  *)
    echo "unknown simulator: $sim" >&2
    exit 2
    ;;
esac

cd "$work/run"
t0="$(now)"
status=0
"${run[@]}" "${plusargs[@]}" > _execute/stdout.log 2>&1 || status=$?
t1="$(now)"
record run "$(elapsed "$t0" "$t1")"
cat _execute/stdout.log
if [[ $status -ne 0 ]]; then
  echo "FAIL: $sim exited with status $status" >&2
  exit 1
fi

if [[ -n "$smoke" ]]; then posthook="" cycles=""; fi
if [[ -n "$posthook" ]]; then
  if ! bash "$posthook" > _execute/posthook.log 2>&1; then
    cat _execute/posthook.log >&2
    echo "FAIL: $sim: the post hook failed" >&2
    exit 1
  fi
fi
if [[ -n "$cycles" ]]; then
  got="$(cat _rtlmeter_cycles.txt 2>/dev/null || echo missing)"
  # One cycle fewer also passes. A design that calls $finish from a process
  # on the main clock's edge races the harness's cycle counter on the same
  # edge: IEEE 1800 (4.6, active region) lets either run first, so whether
  # the last edge is counted is the simulator's choice. Verilator and Icarus
  # count it; xezim finishes first (RTLMeter's Example: 999999 of 1000000).
  # The same tolerance applies to every simulator.
  if [[ "$got" != "$cycles" && "$got" != "$((cycles - 1))" ]]; then
    echo "FAIL: $sim ran $got cycles, expected $cycles (or one fewer)" >&2
    exit 1
  fi
fi
for e in "${expects[@]}"; do
  if ! grep -q -F -- "$e" _execute/stdout.log; then
    echo "FAIL: $sim output lacks: $e" >&2
    exit 1
  fi
done
echo "PASS: $sim, $(cat _rtlmeter_cycles.txt 2>/dev/null || echo '?') cycles"
