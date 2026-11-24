#!/usr/bin/env bash
# Timed runs of RTLMeter case tests, one row of CSV per run.
#
# Build it, then run it from the workspace directory (not with "bazel run",
# which would hold the Bazel server while this script calls Bazel):
#
#   bazel build //bench:timed_runs
#   bazel-bin/bench/timed_runs --core 2 --repeats 5 --out results.csv \
#       //third_party/rtlmeter/designs/Example:kind_hello_verilator_test ...
#
# Each run is one "bazel test" of one target, pinned to --core with taskset
# (the runner, the simulator and its compile all inherit the pin). Bazel runs
# the test locally, outside the sandbox, with no cached result. The runner
# (rtlmeter_case.sh) writes timing.txt into the test's undeclared outputs:
# wall, user and system seconds and peak RSS per step, measured by
# /usr/bin/time, and the cycles simulated.
#
# Around each run the script records the machine's state, so that runs
# disturbed by other work can be dropped by a rule stated in the report:
# the 1-minute load average before, after, and its maximum during the run
# (sampled every 2 s); and from /proc/stat over the run, the busy share of
# the pinned core, of its hyperthread sibling (which should be idle), of the
# other cores, and the CPU steal share of the whole machine.
#
# It stops before a run if the file system holding the Bazel output base has
# under --min-free-gb free (default 15).
set -euo pipefail

core="" repeats=1 out="" min_free_gb=15 bazel="bazel"
bazel_args=()
targets=()
usage() {
  echo "usage: timed_runs --core <n> --out <file.csv> [--repeats <n>] [--min-free-gb <n>]" >&2
  echo "                  [--bazel <bazel or bazelisk>] [--bazel-arg <arg>]... <test target>..." >&2
  exit 2
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --core) core="$2"; shift 2 ;;
    --repeats) repeats="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --min-free-gb) min_free_gb="$2"; shift 2 ;;
    --bazel) bazel="$2"; shift 2 ;;
    --bazel-arg) bazel_args+=("$2"); shift 2 ;;
    -*) usage ;;
    *) targets+=("$1"); shift ;;
  esac
done
[[ -n "$core" && -n "$out" && ${#targets[@]} -gt 0 ]] || usage
[[ -f MODULE.bazel ]] || { echo "run from the workspace directory" >&2; exit 2; }

# The simulators' versions, from MODULE.bazel.
dep_version() {
  sed -n 's/^bazel_dep(name = "'"$1"'", version = "\([^"]*\)").*/\1/p' MODULE.bazel | head -1
}
declare -A version=(
  [verilator]="$(dep_version verilator)"
  [iverilog]="$(dep_version iverilog)"
  [xezim]="$(dep_version xezim)"
)

sibling="$(tr ',' '\n' < "/sys/devices/system/cpu/cpu$core/topology/thread_siblings_list" |
  grep -v -x "$core" | head -1 || true)"
host="$(hostname -s)"

# "cpuN" (or "cpu") line of /proc/stat as "busy total steal" jiffies.
cpu_stat() {
  awk -v c="$1" '$1 == c {
    t = 0; for (i = 2; i <= NF; i++) t += $i
    idle = $5 + $6
    print t - idle, t, $9
  }' /proc/stat
}
# All cores but the pinned one and its sibling, summed.
others_stat() {
  awk -v a="cpu$core" -v b="cpu${sibling:-none}" '$1 ~ /^cpu[0-9]+$/ && $1 != a && $1 != b {
    for (i = 2; i <= NF; i++) t += $i
    idle += $5 + $6
  } END { print t - idle, t, 0 }' /proc/stat
}
snapshot() {
  echo "$(cpu_stat "cpu$core") $(cpu_stat "cpu${sibling:-none}" || true) $(others_stat) $(cpu_stat cpu)"
}
# Percentage of (busy or steal) between two snapshots of one "busy total
# steal" triple; field: 1 busy, 3 steal.
pct() {
  awk -v b="$1" -v a="$2" -v f="$3" 'BEGIN {
    split(b, x, " "); split(a, y, " ")
    dt = y[2] - x[2]; if (dt <= 0) { print ""; exit }
    printf "%.1f", 100 * (y[f] - x[f]) / dt
  }'
}
load1() { cut -d' ' -f1 /proc/loadavg; }

# Fields of one step from timing.txt: wall user sys maxrss.
step() {
  awk -v s="$1" '$1 == s { print $2 "," $3 "," $4 "," $5; f = 1 } END { if (!f) print ",,," }' "$2"
}

if [[ ! -s "$out" ]]; then
  echo "utc_start,host,simulator,simulator_version,design,case,target,repeat,status,cycles,cycles_per_s,verilate_wall_s,verilate_user_s,verilate_sys_s,verilate_maxrss_kib,compile_wall_s,compile_user_s,compile_sys_s,compile_maxrss_kib,run_wall_s,run_user_s,run_sys_s,run_maxrss_kib,core,load1_before,load1_max_during,load1_after,core_busy_pct,sibling_busy_pct,others_busy_pct,steal_pct" > "$out"
fi

testlogs="$("$bazel" info "${bazel_args[@]}" bazel-testlogs 2>/dev/null)"
outbase="$("$bazel" info "${bazel_args[@]}" output_base 2>/dev/null)"

for target in "${targets[@]}"; do
  pkg="${target#//}"; pkg="${pkg%%:*}"; name="${target##*:}"
  design="${pkg##*/}"
  sim="${name%_test}"; sim="${sim##*_}"
  case_="${name%_"${sim}"_test}"
  for ((r = 1; r <= repeats; r++)); do
    free_gb="$(df -P -BG "$outbase" | awk 'NR == 2 { sub("G", "", $4); print $4 }')"
    if ((free_gb < min_free_gb)); then
      echo "stop: ${free_gb} GB free under $outbase, under ${min_free_gb} GB" >&2
      exit 1
    fi
    samples="$(mktemp)"
    ( while :; do load1 >> "$samples"; sleep 2; done ) &
    sampler=$!
    start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    l_before="$(load1)"
    before="$(snapshot)"
    status=pass
    "$bazel" test "${bazel_args[@]}" \
      --cache_test_results=no \
      --strategy=TestRunner=local \
      --local_test_jobs=1 \
      --nozip_undeclared_test_outputs \
      --run_under="taskset -c $core" \
      --test_output=errors \
      "$target" >&2 || status=fail
    after="$(snapshot)"
    l_after="$(load1)"
    kill "$sampler" 2>/dev/null || true
    wait "$sampler" 2>/dev/null || true
    l_max="$(sort -g "$samples" | tail -1)"
    rm -f "$samples"

    read -r -a B <<<"$before"
    read -r -a A <<<"$after"
    if [[ -n "$sibling" ]]; then
      core_pct="$(pct "${B[*]:0:3}" "${A[*]:0:3}" 1)"
      sib_pct="$(pct "${B[*]:3:3}" "${A[*]:3:3}" 1)"
      oth_pct="$(pct "${B[*]:6:3}" "${A[*]:6:3}" 1)"
      steal="$(pct "${B[*]:9:3}" "${A[*]:9:3}" 3)"
    else
      core_pct="$(pct "${B[*]:0:3}" "${A[*]:0:3}" 1)"
      sib_pct=""
      oth_pct="$(pct "${B[*]:3:3}" "${A[*]:3:3}" 1)"
      steal="$(pct "${B[*]:6:3}" "${A[*]:6:3}" 3)"
    fi

    timing="$testlogs/$pkg/$name/test.outputs/timing.txt"
    if [[ -f "$timing" ]]; then
      cycles="$(awk '$1 == "cycles" { print $2 }' "$timing")"
      v="$(step verilate "$timing")"
      c="$(step compile "$timing")"
      x="$(step run "$timing")"
    else
      cycles="" v=",,," c=",,," x=",,,"
      status=fail
    fi
    run_wall="${x%%,*}"
    cps="$(awk -v n="$cycles" -v t="$run_wall" 'BEGIN { if (n ~ /^[0-9]+$/ && t > 0) printf "%.1f", n / t }')"
    echo "$start,$host,$sim,${version[$sim]:-},$design,$case_,$target,$r,$status,$cycles,$cps,$v,$c,$x,$core,$l_before,$l_max,$l_after,$core_pct,$sib_pct,$oth_pct,$steal" >> "$out"
    echo "$target run $r: $status, ${run_wall:-?} s run, ${cycles:-?} cycles, load $l_before/$l_max/$l_after" >&2
  done
done
