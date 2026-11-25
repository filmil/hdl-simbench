#!/usr/bin/env bash
# Copyright 2026 hdl-simbench authors.
# SPDX-License-Identifier: Apache-2.0
#
# Tests vhdl_case.sh with a stub simulator: the commands it records for
# GHDL and NVC, grouping of files per library, and that a failed check
# writes no timings.
set -euo pipefail

case_sh="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
w="$(mktemp -d "${TEST_TMPDIR:-/tmp}/vhdl_case_test.XXXXXX")"
cd "$w"
mkdir -p p/std/v08
touch p/std/v08/std-obj08.cf a.vhd b.vhd c.vhd
cat > stub.sh <<'STUB'
#!/usr/bin/env bash
case " $* " in *" -r "*) echo "hello OK" ;; esac
STUB
chmod +x stub.sh
unset TEST_UNDECLARED_OUTPUTS_DIR

fail() { echo "FAIL: $*" >&2; exit 1; }
want() { # want <file> <line>
  grep -qxF -- "$2" "$1" || { cat "$1" >&2; fail "$1 lacks: $2"; }
}

files=(-- @lib=neo a.vhd b.vhd @lib=work c.vhd @ghdl-libs p/std/v08/std-obj08.cf)

bash "$case_sh" --sim ghdl --tool stub.sh --top top --expect "hello OK" \
  --timing t1 --commands c1 "${files[@]}" > /dev/null
want c1 "env GHDL_PREFIX=$w/p"
want c1 "compile $w/stub.sh -a --std=08 --workdir=lib -Plib --work=neo $w/a.vhd $w/b.vhd"
want c1 "compile $w/stub.sh -a --std=08 --workdir=lib -Plib --work=work $w/c.vhd"
want c1 "run $w/stub.sh -r --std=08 --workdir=lib -Plib top --max-stack-alloc=0 --ieee-asserts=disable --assert-level=error"
[[ "$(cut -d' ' -f1 t1 | tr '\n' ' ')" == "compile run " ]] || fail "t1: $(cat t1)"

bash "$case_sh" --sim nvc --tool stub.sh --top top --expect "hello OK" \
  --timing t2 --commands c2 "${files[@]}" > /dev/null
want c2 "compile $w/stub.sh --std=2008 --work=neo:lib/neo -L lib -a $w/a.vhd $w/b.vhd"
want c2 "compile $w/stub.sh --std=2008 --work=work:lib/work -L lib -a $w/c.vhd"
want c2 "compile $w/stub.sh --std=2008 --work=work:lib/work -L lib -e -O2 top"
want c2 "run $w/stub.sh --std=2008 --work=work:lib/work -L lib -r top --ieee-warnings=off --exit-severity=error"
[[ "$(cut -d' ' -f1 t2 | tr '\n' ' ')" == "compile run " ]] || fail "t2: $(cat t2)"

# A missing expected line or a rejected one fails the case and writes no
# timings.
if bash "$case_sh" --sim ghdl --tool stub.sh --top top --expect "absent" \
  --timing t3 "${files[@]}" > /dev/null 2>&1; then fail "missing --expect passed"; fi
[[ ! -e t3 ]] || fail "a failed run wrote timings"
if bash "$case_sh" --sim nvc --tool stub.sh --top top --reject "OK" \
  --timing t4 "${files[@]}" > /dev/null 2>&1; then fail "--reject match passed"; fi
[[ ! -e t4 ]] || fail "a rejected run wrote timings"
echo PASS
