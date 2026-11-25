#!/usr/bin/env bash
# Tests of //bench:timed_runs's helpers, on made-up /proc and /sys files.
set -euo pipefail

d="$(mktemp -d "${TEST_TMPDIR:-/tmp}/timed_runs_test.XXXXXX")"
fail=0
check() {
  if [[ "$2" != "$3" ]]; then
    echo "FAIL: $1: got '$2', want '$3'" >&2
    fail=1
  fi
}

export PROC_STAT="$d/stat" PROC_LOADAVG="$d/loadavg" SYSFS_CPU="$d/cpu"
TIMED_RUNS_LIB=1 source "$1"

# cpulists, with ranges.
check "cpulist list" "$(echo 2,6 | expand_cpulist | tr '\n' ' ')" "2 6 "
check "cpulist range" "$(echo 2-3 | expand_cpulist | tr '\n' ' ')" "2 3 "
check "cpulist mixed" "$(echo 0-1,4 | expand_cpulist | tr '\n' ' ')" "0 1 4 "

# /proc/stat: user nice system idle iowait irq softirq steal guest guest_nice.
# guest (500) is part of user and must not be counted twice.
cat > "$PROC_STAT" <<'EOF'
cpu  400 0 100 400 100 0 0 50 500 0
cpu0 100 0 0 100 0 0 0 0 500 0
cpu1 100 0 100 0 0 0 0 0 0 0
cpu2 100 0 0 100 0 0 0 50 0 0
cpu3 100 0 0 200 100 0 0 0 0 0
intr 1 2 3
EOF
check "cpu_stat cpu0" "$(cpu_stat cpu0)" "100 200 0"
check "cpu_stat cpu2" "$(cpu_stat cpu2)" "150 250 50"
check "cpu_stat missing" "$(cpu_stat cpu9)" "0 0 0"
check "others of 2 and 3" "$(others_stat 2 3)" "300 400 0"
check "others of 2 alone" "$(others_stat 2 "")" "400 800 0"

before="$(snapshot 2 3)"
check "snapshot fields" "$(wc -w <<<"$before")" "12"
check "snapshot without sibling" "$(snapshot 2 "" | wc -w)" "12"
sed -i 's/^cpu2 100 0 0 100 0 0 0 50/cpu2 190 0 0 110 0 0 0 50/' "$PROC_STAT"
after="$(snapshot 2 3)"
read -r -a B <<<"$before"
read -r -a A <<<"$after"
check "core busy" "$(pct "${B[*]:0:3}" "${A[*]:0:3}" 1)" "90.0"
check "sibling idle" "$(pct "${B[*]:3:3}" "${A[*]:3:3}" 1)" ""
check "steal unchanged" "$(pct "${B[*]:9:3}" "${A[*]:9:3}" 3)" ""
# The whole machine: 100 more jiffies, 25 of them steal.
check "steal" "$(pct "300 1000 50" "375 1100 75" 3)" "25.0"
# No other CPUs than the pinned core and its sibling: still three fields.
printf 'cpu  1 0 0 1 0 0 0 0 0 0\ncpu0 1 0 0 1 0 0 0 0 0 0\ncpu1 0 0 0 1 0 0 0 0 0 0\n' > "$d/stat2"
check "no others" "$(PROC_STAT="$d/stat2" others_stat 0 1)" "0 0 0"

echo "0.61 0.73 1.34 2/900 12345" > "$PROC_LOADAVG"
check "load1" "$(load1)" "0.61"

# timing.txt.
printf 'verilate 1.20 1.00 0.15 81234\ncompile 30.5 29.0 1.2 512000\nrun 4.00 3.95 0.02 20000\ncycles 123456\n' > "$d/timing.txt"
check "step compile" "$(step compile "$d/timing.txt")" "30.5,29.0,1.2,512000"
check "step missing" "$(step nosuch "$d/timing.txt")" ",,,"

# Labels.
check "label" "$(parse_label //third_party/rtlmeter/designs/VeeR-EL2:hiperf_cmark_iccm_xezim_test)" \
  "third_party/rtlmeter/designs/VeeR-EL2 hiperf_cmark_iccm_xezim_test xezim hiperf_cmark_iccm"
check "smoke label" "$(parse_label //a/b:kind_hello_verilator_smoke_test)" \
  "a/b kind_hello_verilator_smoke_test verilator kind_hello"
for bad in //a/b //:kind_hello_verilator_test //a/b:foo_test //a/b:_verilator_test; do
  if parse_label "$bad" > /dev/null 2>&1; then
    echo "FAIL: $bad must be refused" >&2
    fail=1
  fi
done

[[ $fail -eq 0 ]] && echo PASS
exit $fail
