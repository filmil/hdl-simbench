#!/usr/bin/env bash
# Copyright 2026 hdl-simbench authors.
# SPDX-License-Identifier: Apache-2.0
#
# A simulator that cannot run a design: runs one case with
# rtlmeter_case.sh and passes only if it fails, with the given text in its
# output. If a newer simulator gains support, this test fails, so that the
# design's "unsupported" entry is removed and its cases are made.
#
# Usage: expect_unsupported.sh <text> <rtlmeter_case.sh> <its arguments>...

set -uo pipefail
want="$1"; case_sh="$2"; shift 2
out="$(bash "$case_sh" "$@" 2>&1)"
status=$?
if [[ $status -eq 0 ]]; then
  echo "FAIL: the case passed; the simulator now supports this design." >&2
  echo "Remove it from the design's unsupported list." >&2
  exit 1
fi
if ! grep -q -F -- "$want" <<<"$out"; then
  echo "FAIL: it failed (status $status), but not with \"$want\":" >&2
  echo "$out" >&2
  exit 1
fi
echo "ok: still unsupported (\"$want\")"
