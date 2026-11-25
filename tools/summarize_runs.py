"""Summarizes //bench:timed_runs CSV files by the rule in README.md.

  bazel run //tools:summarize_runs -- results/slot1.csv [more.csv ...]

Relative paths are taken from the directory "bazel run" was started in.

"Which runs count" (README.md):
- A run is dropped if sibling_busy_pct > 25 or steal_pct > 1.
- A cell is one simulator (and version) on one host running one case of one
  design at one cycle cap. It reports the median of its kept runs, with min
  and max, of: compile (verilate + compile), run, total (compile + run of
  the same run), cycles per second of the run, and the run's peak RSS.
- A cell that loses more than a third of its runs is marked "more runs
  needed" instead of reported.
- A cell with a failing run is marked failing.
- A cell whose median run is under 1 s, or that has a run of 0 s, has its
  cycles per second marked "resolution-limited" (the timer counts 0.01 s
  steps); with a 0 s run, or a run without a rate, it has no rate at all.
- A cell whose kept runs simulated different cycle counts is marked
  "cycles differ".

Each cell names the commits, dirty flags and lockfile hashes of its runs.

Prints a Markdown table, and with --csv <file> also writes the summary as
CSV, always with the same columns.
"""

import argparse
import csv
import os
import statistics
import sys

SIBLING_MAX = 25.0
STEAL_MAX = 1.0
# /usr/bin/time measures wall time in steps of 0.01 s: a run under 1 s has
# more than 1% timer error.
RESOLUTION_MIN_RUN_S = 1.0

METRICS = ["compile_s", "run_s", "total_s", "cycles_per_s", "run_maxrss_kib"]
CSV_COLUMNS = (
    ["host", "simulator", "simulator_version", "design", "case", "max_cycles",
     "state", "runs", "kept", "cycles", "resolution_limited"]
    + [m + sfx for m in METRICS for sfx in ("", "_min", "_max")]
    + ["git_commit", "git_dirty", "lock_sha256"]
)


def _num(row, key):
    """The field as a float, or None when it is empty or missing."""
    v = row.get(key)
    if v in ("", None):
        return None
    return float(v)


def _f(row, key):
    v = _num(row, key)
    return 0.0 if v is None else v


def dropped(row):
    """Whether the README's rule drops this run."""
    return _f(row, "sibling_busy_pct") > SIBLING_MAX or _f(row, "steal_pct") > STEAL_MAX


def compile_s(row):
    return _f(row, "verilate_wall_s") + _f(row, "compile_wall_s")


def summarize(rows):
    """Returns a list of dicts, one per cell, in first-seen order."""
    cells = {}
    for r in rows:
        key = (r.get("host", ""), r["simulator"], r.get("simulator_version", ""),
               r["design"], r["case"], r.get("max_cycles", ""))
        cells.setdefault(key, []).append(r)
    out = []
    for (host, sim, version, design, case, cap), runs in cells.items():
        c = {k: "" for k in CSV_COLUMNS}
        c.update({
            "host": host, "simulator": sim, "simulator_version": version,
            "design": design, "case": case, "max_cycles": cap,
            "runs": len(runs),
            "git_commit": " ".join(sorted({(r.get("git_commit") or "?")[:7] for r in runs})),
            "git_dirty": " ".join(sorted({(r.get("git_dirty") or "?") for r in runs})),
            "lock_sha256": " ".join(sorted({(r.get("lock_sha256") or "?")[:12] for r in runs})),
        })
        if any(r["status"] != "pass" for r in runs):
            c["state"] = "failing"
            out.append(c)
            continue
        kept = [r for r in runs if not dropped(r)]
        c["kept"] = len(kept)
        if len(runs) - len(kept) > len(runs) / 3:
            c["state"] = "more runs needed"
            out.append(c)
            continue
        cycles = {r.get("cycles", "") for r in kept}
        if len(cycles) > 1:
            c["state"] = "cycles differ"
            out.append(c)
            continue
        c["state"] = "ok"
        c["cycles"] = cycles.pop()
        runs_s = [_f(r, "run_wall_s") for r in kept]
        series = {
            "compile_s": [compile_s(r) for r in kept],
            "run_s": runs_s,
            "total_s": [compile_s(r) + _f(r, "run_wall_s") for r in kept],
            "run_maxrss_kib": [_f(r, "run_maxrss_kib") for r in kept],
        }
        rates = [_num(r, "cycles_per_s") for r in kept]
        zero_run = any(t <= 0 for t in runs_s)
        if not zero_run and all(x is not None and x > 0 for x in rates):
            series["cycles_per_s"] = rates
        for name, vals in series.items():
            c[name] = statistics.median(vals)
            c[name + "_min"] = min(vals)
            c[name + "_max"] = max(vals)
        if "cycles_per_s" not in series:
            for name in ("cycles_per_s", "cycles_per_s_min", "cycles_per_s_max"):
                c[name] = None
        c["resolution_limited"] = zero_run or c["run_s"] < RESOLUTION_MIN_RUN_S
        out.append(c)
    return out


def _cell(c, name, fmt):
    if c["state"] != "ok" or c.get(name) is None:
        return ""
    return (fmt + " [" + fmt + "-" + fmt + "]") % (c[name], c[name + "_min"], c[name + "_max"])


def markdown(cells):
    lines = [
        "| simulator | design | case | cap | cycles | kept/runs | compile s | run s | total s | cycles/s | commit |",
        "|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for c in cells:
        state = c["state"]
        rate = ""
        if state == "ok":
            if c["cycles_per_s"] is None:
                rate = "n/a"
            else:
                rate = "%.4g [%.4g-%.4g]" % (c["cycles_per_s"], c["cycles_per_s_min"], c["cycles_per_s_max"])
            if c["resolution_limited"]:
                rate += " (resolution-limited)"
        commit = c["git_commit"]
        if "dirty" in c["git_dirty"].split():
            commit += " (dirty)"
        lines.append("| %s %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            c["simulator"], c["simulator_version"], c["design"], c["case"], c["max_cycles"] or "-",
            c["cycles"],
            "%s/%s" % (c["kept"], c["runs"]) if state == "ok" else state,
            _cell(c, "compile_s", "%.2f"), _cell(c, "run_s", "%.2f"), _cell(c, "total_s", "%.2f"),
            rate, commit))
    return "\n".join(lines)


def _path(p):
    """A path as the caller meant it: "bazel run" starts in runfiles."""
    base = os.environ.get("BUILD_WORKING_DIRECTORY")
    if base and not os.path.isabs(p):
        return os.path.join(base, p)
    return p


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("csv_files", nargs="+")
    p.add_argument("--csv", help="also write the summary to this CSV file")
    a = p.parse_args(argv)
    rows = []
    for path in a.csv_files:
        with open(_path(path), newline="") as f:
            rows.extend(csv.DictReader(f))
    cells = summarize(rows)
    print(markdown(cells))
    if a.csv:
        with open(_path(a.csv), "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
            w.writeheader()
            w.writerows(cells)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
