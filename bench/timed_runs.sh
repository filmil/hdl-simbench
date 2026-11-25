#!/usr/bin/env bash
# Timed runs of case tests, one row of CSV per run.
#
# Build it, then run it from the workspace directory (not with "bazel run",
# which would hold the Bazel server while this script calls Bazel):
#
#   bazel build //bench:timed_runs
#   bazel-bin/bench/timed_runs --core 2 --repeats 5 --out results.csv \
#       //third_party/rtlmeter/designs/Example:kind_hello_verilator_test ...
#
# Needs on the host: taskset (util-linux) and GNU time as /usr/bin/time;
# without GNU time the user, system and peak RSS columns are empty.
#
# Each target is first built (unpinned, outside the measured window). Then
# each run is one "bazel test" of the target, pinned to --core with taskset
# (the runner, the simulator and its compile all inherit the pin). Bazel runs
# the test locally, outside the sandbox, with no cached result. The runner
# (rtlmeter_case.sh, or bench/vhdl/vhdl_case.sh) writes into the test's
# undeclared outputs timing.txt, with wall, user and system seconds and peak
# RSS per step (measured by /usr/bin/time) and the cycles simulated, and
# commands.txt, every command line as it ran.
#
# Around each run the script records the machine's state, so that runs
# disturbed by other work can be dropped by a rule stated in the report:
# the 1-minute load average before, after, and its maximum during the run
# (sampled every 2 s); and from /proc/stat over the run, the busy share of
# the pinned core, of its hyperthread sibling (which should be idle), of the
# other cores, and the CPU steal share of the whole machine.
#
# With --max-cycles, every run is capped at that many cycles by RTLMeter's
# +max_cycles: the throughput runs, the same cap for every simulator.
# Each run's commands.txt is copied to <out>.commands/, and the row names it.
#
# It stops before a run if the file system holding the Bazel output base has
# under --min-free-gb free (default 15).
set -euo pipefail
# /proc/loadavg and the CSV use "." for decimals, whatever the locale.
export LC_ALL=C

# Overridable for //bench:timed_runs_test.
PROC_STAT="${PROC_STAT:-/proc/stat}"
PROC_LOADAVG="${PROC_LOADAVG:-/proc/loadavg}"
SYSFS_CPU="${SYSFS_CPU:-/sys/devices/system/cpu}"

# A cpulist ("2,6", "2-3", "0-1,4") as one CPU number per line.
expand_cpulist() {
  tr ',' '\n' | awk -F- 'NF == 1 && $1 != "" { print $1 } NF == 2 { for (i = $1; i <= $2; i++) print i }'
}

# The "cpuN" (or "cpu") line of /proc/stat as "busy total steal" jiffies.
# Columns 2-9 (user nice system idle iowait irq softirq steal) only: guest
# and guest_nice are already counted in user and nice.
cpu_stat() {
  awk -v c="$1" '$1 == c {
    t = 0; for (i = 2; i <= 9; i++) t += $i
    print t - ($5 + $6), t, $9; f = 1
  } END { if (!f) print "0 0 0" }' "$PROC_STAT"
}
# All cores but $1 and $2 (the pinned core and its sibling), summed.
others_stat() {
  awk -v a="cpu$1" -v b="cpu$2" 'BEGIN { t = 0; idle = 0 }
  $1 ~ /^cpu[0-9]+$/ && $1 != a && $1 != b {
    for (i = 2; i <= 9; i++) t += $i
    idle += $5 + $6
  } END { print t - idle, t, 0 }' "$PROC_STAT"
}
# Four "busy total steal" triples: core, sibling, others, whole machine.
snapshot() {
  local sib="$(cpu_stat "cpu$2")"
  [[ -n "$2" ]] || sib="0 0 0"
  echo "$(cpu_stat "cpu$1") $sib $(others_stat "$1" "$2") $(cpu_stat cpu)"
}
# Percentage between two triples: field 1 busy, 3 steal; empty if no time
# passed (or no such CPU).
pct() {
  awk -v b="$1" -v a="$2" -v f="$3" 'BEGIN {
    split(b, x, " "); split(a, y, " ")
    dt = y[2] - x[2]; if (dt <= 0) { print ""; exit }
    printf "%.1f", 100 * (y[f] - x[f]) / dt
  }'
}
load1() { cut -d' ' -f1 "$PROC_LOADAVG"; }

# Fields of one step from timing.txt: "wall,user,sys,maxrss".
step() {
  awk -v s="$1" '$1 == s { print $2 "," $3 "," $4 "," $5; f = 1 } END { if (!f) print ",,," }' "$2"
}

# A label //pkg:name as "pkg name simulator case". The package is not the
# root, and the name is <case>_<simulator>_test or
# <case>_<simulator>_smoke_test.
parse_label() {
  local l="$1" pkg name base sim case_
  if [[ "$l" =~ ^//([^:[:space:]]+):([^:[:space:]]+)_test$ ]]; then
    pkg="${BASH_REMATCH[1]}"; base="${BASH_REMATCH[2]}"; base="${base%_smoke}"
    name="${l##*:}"; sim="${base##*_}"; case_="${base%_"$sim"}"
    if [[ "$base" == *_* && -n "$sim" && -n "$case_" && "$case_" != "$base" ]]; then
      echo "$pkg $name $sim $case_"
      return 0
    fi
  fi
  echo "need //pkg:<case>_<simulator>_test: $l" >&2
  return 1
}

# Sourced by the test with TIMED_RUNS_LIB=1: the helpers only.
[[ -n "${TIMED_RUNS_LIB:-}" ]] && return 0

core="" repeats=1 out="" min_free_gb=15 bazel="bazel" max_cycles=""
bazel_args=()
targets=()
usage() {
  echo "usage: timed_runs --core <n> --out <file.csv> [--repeats <n>] [--min-free-gb <n>]" >&2
  echo "                  [--max-cycles <n>] (the same +max_cycles cap for every simulator)" >&2
  echo "                  [--bazel <bazel or bazelisk>] [--bazel-arg <build/test option>]..." >&2
  echo "                  <//pkg:name test target>..." >&2
  exit 2
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --core) core="$2"; shift 2 ;;
    --repeats) repeats="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --min-free-gb) min_free_gb="$2"; shift 2 ;;
    --max-cycles) max_cycles="$2"; shift 2 ;;
    --bazel) bazel="$2"; shift 2 ;;
    --bazel-arg) bazel_args+=("$2"); shift 2 ;;
    -*) usage ;;
    *) targets+=("$1"); shift ;;
  esac
done
[[ -n "$core" && -n "$out" && ${#targets[@]} -gt 0 ]] || usage
[[ -f MODULE.bazel ]] || { echo "run from the workspace directory" >&2; exit 2; }
for t in "${targets[@]}"; do parse_label "$t" > /dev/null; done

# The simulators' versions, from MODULE.bazel.
dep_version() {
  sed -n 's/^bazel_dep(name = "'"$1"'", version = "\([^"]*\)").*/\1/p' MODULE.bazel | head -1
}
declare -A version=(
  [verilator]="$(dep_version verilator)"
  [iverilog]="$(dep_version iverilog)"
  [xezim]="$(dep_version xezim)"
  [ghdl]="$(dep_version ghdl)"
  [nvc]="$(dep_version nvc)"
)

sibling="$(expand_cpulist < "$SYSFS_CPU/cpu$core/topology/thread_siblings_list" |
  grep -v -x "$core" | head -1 || true)"
host="$(hostname -s)"

if [[ ! -s "$out" ]]; then
  echo "utc_start,host,simulator,simulator_version,design,case,target,repeat,status,max_cycles,commands_file,cycles,cycles_per_s,verilate_wall_s,verilate_user_s,verilate_sys_s,verilate_maxrss_kib,compile_wall_s,compile_user_s,compile_sys_s,compile_maxrss_kib,run_wall_s,run_user_s,run_sys_s,run_maxrss_kib,core,load1_before,load1_max_during,load1_after,core_busy_pct,sibling_busy_pct,others_busy_pct,steal_pct" > "$out"
fi

# Build options only: "bazel info" rejects test options.
testlogs="$("$bazel" info bazel-testlogs)"
outbase="$("$bazel" info output_base)"

samples="" sampler=""
cleanup() {
  [[ -n "$sampler" ]] && kill "$sampler" 2>/dev/null || true
  [[ -n "$samples" ]] && rm -f "$samples"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for target in "${targets[@]}"; do
  read -r pkg name sim case_ <<<"$(parse_label "$target")"
  design="${pkg##*/}"
  outputs="$testlogs/$pkg/$name/test.outputs"
  # Build first, with the same options as the runs (so that Bazel keeps
  # its analysis), so that no build or analysis runs in a measured window.
  test_opts=(
    --cache_test_results=no
    --strategy=TestRunner=local
    --local_test_jobs=1
    --nozip_undeclared_test_outputs
    --run_under="taskset -c $core"
    --test_output=errors
  )
  [[ -n "$max_cycles" ]] && test_opts+=(--test_env=SIMBENCH_MAX_CYCLES="$max_cycles")
  # "bazel build" with the runs' build option (--run_under); the test-only
  # options do not affect what is built.
  "$bazel" build "${bazel_args[@]}" --run_under="taskset -c $core" "$target" >&2
  for ((r = 1; r <= repeats; r++)); do
    free_gb="$(df -P -BG "$outbase" | awk 'NR == 2 { sub("G", "", $4); print $4 }')"
    if ((free_gb < min_free_gb)); then
      echo "stop: ${free_gb} GB free under $outbase, under ${min_free_gb} GB" >&2
      exit 1
    fi
    rm -f "$outputs/timing.txt" "$outputs/commands.txt"
    samples="$(mktemp)"
    ( while :; do load1 >> "$samples"; sleep 2; done ) &
    sampler=$!
    start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    l_before="$(load1)"
    before="$(snapshot "$core" "$sibling")"
    status=pass
    "$bazel" test "${bazel_args[@]}" "${test_opts[@]}" "$target" >&2 || status=fail
    after="$(snapshot "$core" "$sibling")"
    l_after="$(load1)"
    kill "$sampler" 2>/dev/null || true
    wait "$sampler" 2>/dev/null || true
    sampler=""
    l_max="$(sort -g "$samples" | tail -1)"
    rm -f "$samples"; samples=""

    read -r -a B <<<"$before"
    read -r -a A <<<"$after"
    core_pct="$(pct "${B[*]:0:3}" "${A[*]:0:3}" 1)"
    sib_pct=""
    [[ -n "$sibling" ]] && sib_pct="$(pct "${B[*]:3:3}" "${A[*]:3:3}" 1)"
    oth_pct="$(pct "${B[*]:6:3}" "${A[*]:6:3}" 1)"
    steal="$(pct "${B[*]:9:3}" "${A[*]:9:3}" 3)"

    cmdfile=""
    if [[ -f "$outputs/commands.txt" ]]; then
      mkdir -p "$out.commands"
      cmdfile="$out.commands/$(date -u +%Y%m%dT%H%M%S)-$name-$r.txt"
      cp "$outputs/commands.txt" "$cmdfile"
    fi
    if [[ -f "$outputs/timing.txt" ]]; then
      cycles="$(awk '$1 == "cycles" { print $2 }' "$outputs/timing.txt")"
      v="$(step verilate "$outputs/timing.txt")"
      c="$(step compile "$outputs/timing.txt")"
      x="$(step run "$outputs/timing.txt")"
    else
      cycles="" v=",,," c=",,," x=",,,"
      status=fail
    fi
    run_wall="${x%%,*}"
    cps="$(awk -v n="$cycles" -v t="$run_wall" 'BEGIN { if (n ~ /^[0-9]+$/ && t > 0) printf "%.1f", n / t }')"
    echo "$start,$host,$sim,${version[$sim]:-},$design,$case_,$target,$r,$status,$max_cycles,$cmdfile,$cycles,$cps,$v,$c,$x,$core,$l_before,$l_max,$l_after,$core_pct,$sib_pct,$oth_pct,$steal" >> "$out"
    echo "$target run $r: $status, ${run_wall:-?} s run, ${cycles:-?} cycles, load $l_before/$l_max/$l_after" >&2
  done
done
