"""Summarizes //bench:timed_runs CSV files by the rule in README.md.

  bazel run //tools:summarize_runs -- results/slot1.csv [more.csv ...]

"Which runs count" (README.md):
- A run is dropped if sibling_busy_pct > 25 or steal_pct > 1.
- Each cell (simulator, design, case, max_cycles) reports the median of its
  kept runs, with min and max, for: compile (verilate + compile), run,
  total (compile + run), and cycles per second of the run.
- A cell that loses more than a third of its runs is marked "more runs
  needed" instead of reported.
- A cell with a failing run is marked failing.
- A cell whose median run is under 1 s has its cycles per second marked
  "resolution-limited": the timer counts 0.01 s steps.

Prints a Markdown table, and with --csv <file> also writes the summary as
CSV.
"""

import argparse
import csv
import statistics
import sys

SIBLING_MAX = 25.0
STEAL_MAX = 1.0
# /usr/bin/time measures wall time in steps of 0.01 s: a run under 1 s has
# more than 1% timer error, so its cycles per second is "resolution-limited".
RESOLUTION_MIN_RUN_S = 1.0


def _f(row, key):
    v = row.get(key, "")
    return float(v) if v not in ("", None) else 0.0


def dropped(row):
    """Whether the README's rule drops this run."""
    return _f(row, "sibling_busy_pct") > SIBLING_MAX or _f(row, "steal_pct") > STEAL_MAX


def compile_s(row):
    return _f(row, "verilate_wall_s") + _f(row, "compile_wall_s")


def summarize(rows):
    """Returns a list of dicts, one per cell, in first-seen order."""
    cells = {}
    for r in rows:
        key = (r["simulator"], r["design"], r["case"], r.get("max_cycles", ""))
        cells.setdefault(key, []).append(r)
    out = []
    for (sim, design, case, cap), runs in cells.items():
        c = {
            "simulator": sim,
            "simulator_version": runs[0].get("simulator_version", ""),
            "design": design,
            "case": case,
            "max_cycles": cap,
            "runs": len(runs),
        }
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
        c["state"] = "ok"
        series = {
            "compile_s": [compile_s(r) for r in kept],
            "run_s": [_f(r, "run_wall_s") for r in kept],
            "total_s": [compile_s(r) + _f(r, "run_wall_s") for r in kept],
            "cycles_per_s": [_f(r, "cycles_per_s") for r in kept],
            "run_maxrss_kib": [_f(r, "run_maxrss_kib") for r in kept],
        }
        for name, vals in series.items():
            c[name] = statistics.median(vals)
            c[name + "_min"] = min(vals)
            c[name + "_max"] = max(vals)
        c["cycles"] = kept[0].get("cycles", "")
        c["resolution_limited"] = c["run_s"] < RESOLUTION_MIN_RUN_S
        commits = sorted({r.get("git_commit", "") for r in kept})
        c["git_commit"] = " ".join(x[:7] for x in commits)
        out.append(c)
    return out


def _cell(c, name, fmt):
    if c["state"] != "ok":
        return ""
    return (fmt + " [" + fmt + "-" + fmt + "]") % (c[name], c[name + "_min"], c[name + "_max"])


def markdown(cells):
    lines = [
        "| simulator | design | case | cap | cycles | kept/runs | compile s | run s | total s | M cycles/s | commit |",
        "|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for c in cells:
        state = c["state"]
        mcps = ""
        if state == "ok":
            mcps = "%.3f [%.3f-%.3f]" % (c["cycles_per_s"] / 1e6, c["cycles_per_s_min"] / 1e6, c["cycles_per_s_max"] / 1e6)
            if c["resolution_limited"]:
                mcps += " (resolution-limited)"
        lines.append("| %s %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            c["simulator"], c["simulator_version"], c["design"], c["case"], c["max_cycles"] or "-",
            c.get("cycles", ""),
            "%s/%s" % (c.get("kept", "-"), c["runs"]) if state == "ok" else state,
            _cell(c, "compile_s", "%.2f"), _cell(c, "run_s", "%.2f"), _cell(c, "total_s", "%.2f"),
            mcps, c.get("git_commit", "")))
    return "\n".join(lines)


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("csv_files", nargs="+")
    p.add_argument("--csv", help="also write the summary to this CSV file")
    a = p.parse_args(argv)
    rows = []
    for path in a.csv_files:
        with open(path, newline="") as f:
            rows.extend(csv.DictReader(f))
    cells = summarize(rows)
    print(markdown(cells))
    if a.csv:
        keys = sorted({k for c in cells for k in c})
        with open(a.csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=keys)
            w.writeheader()
            w.writerows(cells)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
