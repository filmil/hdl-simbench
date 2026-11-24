#!/usr/bin/env bash
# Copyright 2026 hdl-simbench authors.
# SPDX-License-Identifier: Apache-2.0
#
# Runs rtlmeter_case.sh on a good case twice with a wrong expectation, and
# passes only if both runs fail with exit status 1 and say why.
#
# Usage: expect_failure.sh <rtlmeter_case.sh> <its arguments up to "--">
#            -- <sources>...

set -uo pipefail

case_sh="$1"; shift
opts=() srcs=()
while [[ $# -gt 0 && "$1" != "--" ]]; do opts+=("$1"); shift; done
shift
srcs=("$@")

check() {
  local what="$1" want="$2"; shift 2
  local out status
  out="$(bash "$case_sh" "${opts[@]}" "$@" -- "${srcs[@]}" 2>&1)"
  status=$?
  if [[ $status -ne 1 ]]; then
    echo "FAIL: $what: exit status $status, expected 1" >&2
    echo "$out" >&2
    exit 1
  fi
  if ! grep -q -F -- "$want" <<<"$out"; then
    echo "FAIL: $what: no \"$want\" in the output" >&2
    echo "$out" >&2
    exit 1
  fi
  echo "ok: $what"
}

# The Example runs 1000000 cycles.
check "wrong cycle count" "expected 999999" --cycles 999999
check "missing output line" "output lacks: no such line" \
  --cycles 1000000 --expect "no such line"
echo "PASS"
