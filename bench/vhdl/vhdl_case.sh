#!/usr/bin/env bash
# Copyright 2026 hdl-simbench authors.
# SPDX-License-Identifier: Apache-2.0
#
# Runs one VHDL case with one VHDL simulator, and checks its output.
#
# Every simulator gets the same sources, libraries, top entity and VHDL
# standard (2008). Compile and run are timed separately, as in
# bench/rtlmeter_case.sh; with --timing <file>, one "step seconds" pair per
# line is appended to it.
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
#       [--commands <file>]
#       -- [@lib=<library>] <file>... [@lib=<library> <file>...]...
#          [@ghdl-libs <file>...]
#
# The files after -- are analysed in the order given, each into the library
# the last @lib= names (work before any). The files after @ghdl-libs are
# GHDL's compiled std and ieee libraries (@ghdl//:vhdl_libs_v08); GHDL's
# prefix is the directory that holds their std/v08 and ieee/v08. Markers
# instead of flags let a Bazel $(rootpaths) expansion, which is one
# space-separated argument, follow a marker.

set -euo pipefail

sim="" tool="" prefix="" top="" timing="" commands=""
expects=() rejects=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sim) sim="$2"; shift 2 ;;
    --tool) tool="$2"; shift 2 ;;
    --top) top="$2"; shift 2 ;;
    --expect) expects+=("$2"); shift 2 ;;
    --reject) rejects+=("$2"); shift 2 ;;
    --timing) timing="$2"; shift 2 ;;
    --commands) commands="$2"; shift 2 ;;
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
    *)
      if [[ $mode == ghdl ]]; then
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

work="$(mktemp -d "${TEST_TMPDIR:-${TMPDIR:-/tmp}}/vhdl_case.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cd "$work"

now() { date +%s.%N; }
record() { [[ -n "$timing" ]] && printf '%s %s\n' "$1" "$2" >> "$timing"; return 0; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f", b - a }'; }
# step: runs the command after the step name, and records it.
step() {
  local name="$1"; shift
  if [[ -n "$commands" ]]; then
    { printf '%s' "$name"; printf ' %q' "$@"; printf '\n'; } >> "$commands"
  fi
  "$@"
}

case "$sim" in
  ghdl)
    if [[ -z "$prefix" ]]; then echo "ghdl needs @ghdl-libs with std/v08/std-obj08.cf" >&2; exit 2; fi
    export GHDL_PREFIX="$prefix"
    common=(--std=08 --workdir=lib -Plib)
    mkdir lib
    t0="$(now)"
    for s in "${srcs[@]}"; do
      step compile "$tool" -a "${common[@]}" --work="${s%% *}" "${s#* }"
    done
    t1="$(now)"
    # As NEORV32's own sim/ghdl.sh runs it.
    run=("$tool" -r "${common[@]}" "$top" --max-stack-alloc=0 --ieee-asserts=disable --assert-level=error)
    ;;
  nvc)
    common=(--std=2008)
    t0="$(now)"
    mkdir lib
    for s in "${srcs[@]}"; do
      l="${s%% *}"
      step compile "$tool" "${common[@]}" --work="$l:lib/$l" -L lib -a "${s#* }"
    done
    step compile "$tool" "${common[@]}" --work=work:lib/work -L lib -e "$top"
    t1="$(now)"
    run=("$tool" "${common[@]}" --work=work:lib/work -L lib -r "$top" --ieee-warnings=off --exit-severity=error)
    ;;
  *)
    echo "unknown simulator: $sim" >&2
    exit 2
    ;;
esac
record compile "$(elapsed "$t0" "$t1")"

t0="$(now)"
status=0
step run "${run[@]}" > stdout.log 2>&1 || status=$?
t1="$(now)"
record run "$(elapsed "$t0" "$t1")"
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
echo "PASS: $sim"
