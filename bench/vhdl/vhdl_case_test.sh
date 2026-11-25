#!/usr/bin/env bash
# Copyright 2026 hdl-simbench authors.
# SPDX-License-Identifier: Apache-2.0
#
# Tests vhdl_case.sh with a stub simulator: the commands it records for
# GHDL and NVC, grouping of files per library, the timing record (steps
# and cycles), the host-library check, and that a failed check writes no
# timings.
set -euo pipefail

case_sh="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
w="$(mktemp -d "${TEST_TMPDIR:-/tmp}/vhdl_case_test.XXXXXX")"
cd "$w"
mkdir -p p/std/v08
touch p/std/v08/std-obj08.cf a.vhd b.vhd c.vhd
cat > stub.sh <<'STUB'
#!/usr/bin/env bash
case " $* " in *" -r "*) echo "hello OK"; echo "tb.vhd:1:1:(report note): simbench cycles ${CYCLES-42}" ;; esac
STUB
# A readelf that reports the NEEDED list in $NEEDED and the symbol
# versions in $VERSIONS.
cat > readelf.sh <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == -d ]]; then
  for n in $NEEDED; do echo " 0x0000000000000001 (NEEDED) Shared library: [$n]"; done
elif [[ "$1" == -V ]]; then
  for v in $VERSIONS; do echo "  0x0010:   Name: $v  Flags: none  Version: 2"; done
elif [[ "$1" == --dyn-syms ]]; then
  for v in $VERSIONS; do echo "     1: 0000000000000000     0 FUNC    GLOBAL DEFAULT   UND sym_${v#GLIBC_}@$v (2)"; done
fi
[[ -z "${READELF_FAIL:-}" ]]
STUB
chmod +x readelf.sh
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
[[ "$(cut -d' ' -f1 t1 | tr '\n' ' ')" == "compile run cycles " ]] || fail "t1: $(cat t1)"
want t1 "cycles 42"
# With /usr/bin/time, each step has wall, user, system and max RSS.
if [[ -x /usr/bin/time ]] && /usr/bin/time -f %e -a -o /dev/null true 2> /dev/null; then
  awk '$1 != "cycles" && NF != 5 { exit 1 }' t1 || fail "t1 steps lack fields: $(cat t1)"
fi

bash "$case_sh" --sim nvc --tool stub.sh --top top --expect "hello OK" \
  --timing t2 --commands c2 "${files[@]}" > /dev/null
want c2 "compile $w/stub.sh --std=2008 --work=neo:lib/neo -L lib -a $w/a.vhd $w/b.vhd"
want c2 "compile $w/stub.sh --std=2008 --work=work:lib/work -L lib -a $w/c.vhd"
want c2 "compile $w/stub.sh --std=2008 --work=work:lib/work -L lib -e -O2 top"
want c2 "run $w/stub.sh --std=2008 --work=work:lib/work -L lib -r top --ieee-warnings=off --exit-severity=error"
[[ "$(cut -d' ' -f1 t2 | tr '\n' ' ')" == "compile run cycles " ]] || fail "t2: $(cat t2)"

# The host-library check: glibc passes, anything else fails unless allowed.
NEEDED="libc.so.6 libm.so.6" bash "$case_sh" --sim ghdl --tool stub.sh --top top \
  --readelf readelf.sh --commands c5 "${files[@]}" > /dev/null
want c5 "elf $w/stub.sh NEEDED:\\ libc.so.6\\ libm.so.6 GLIBC:\\ none"
if NEEDED="libc.so.6 libgcc_s.so.1" bash "$case_sh" --sim ghdl --tool stub.sh \
  --top top --readelf readelf.sh --timing t6 "${files[@]}" > /dev/null 2>&1; then
  fail "a binary needing the host's libgcc_s passed"
fi
[[ ! -e t6 ]] || fail "a failed host-library check wrote timings"
NEEDED="libc.so.6 libgcc_s.so.1" bash "$case_sh" --sim ghdl --tool stub.sh --top top \
  --readelf readelf.sh --allow-host-lib libgcc_s.so.1 --commands c7 "${files[@]}" > /dev/null
grep -q "^host-lib $w/stub.sh libgcc_s.so.1 " c7 || { cat c7 >&2; fail "c7 lacks the host-lib record"; }

# glibc symbol versions: 2.31 passes and is recorded; newer, or one tied to
# a particular glibc, fails.
NEEDED="libc.so.6" VERSIONS="GLIBC_2.2.5 GLIBC_2.31" bash "$case_sh" --sim ghdl \
  --tool stub.sh --top top --readelf readelf.sh --commands c8 "${files[@]}" > /dev/null
want c8 "elf $w/stub.sh NEEDED:\\ libc.so.6 GLIBC:\\ 2.31"
# The failure names the symbols that need the newer glibc.
if NEEDED="libc.so.6" VERSIONS="GLIBC_2.2.5 GLIBC_2.34" bash "$case_sh" --sim ghdl \
  --tool stub.sh --top top --readelf readelf.sh "${files[@]}" > /dev/null 2> e10; then
  fail "a binary needing GLIBC_2.34 passed"
fi
grep -qF "sym_2.34@GLIBC_2.34" e10 || { cat e10 >&2; fail "the failure does not name the symbol"; }
grep -qF "sym_2.2.5@" e10 && fail "the failure names a symbol old enough"
# A readelf that fails fails the case.
if READELF_FAIL=1 NEEDED="libc.so.6" bash "$case_sh" --sim ghdl --tool stub.sh --top top \
  --readelf readelf.sh "${files[@]}" > /dev/null 2>&1; then
  fail "a failing readelf passed"
fi
for v in GLIBC_2.34 GLIBC_PRIVATE GLIBC_ABI_DT_RELR; do
  if NEEDED="libc.so.6" VERSIONS="GLIBC_2.2.5 $v" bash "$case_sh" --sim ghdl \
    --tool stub.sh --top top --readelf readelf.sh "${files[@]}" > /dev/null 2>&1; then
    fail "a binary needing $v passed"
  fi
done

# The cycles line is required, and must be a positive whole number.
for c in "" 0 12.5 12abc; do
  if CYCLES="$c" bash "$case_sh" --sim ghdl --tool stub.sh --top top \
    --timing t9 "${files[@]}" > /dev/null 2>&1; then
    fail "cycles '$c' passed"
  fi
  [[ ! -e t9 ]] || fail "cycles '$c' wrote timings"
done

# A missing expected line or a rejected one fails the case and writes no
# timings.
if bash "$case_sh" --sim ghdl --tool stub.sh --top top --expect "absent" \
  --timing t3 "${files[@]}" > /dev/null 2>&1; then fail "missing --expect passed"; fi
[[ ! -e t3 ]] || fail "a failed run wrote timings"
if bash "$case_sh" --sim nvc --tool stub.sh --top top --reject "OK" \
  --timing t4 "${files[@]}" > /dev/null 2>&1; then fail "--reject match passed"; fi
[[ ! -e t4 ]] || fail "a rejected run wrote timings"
echo PASS
