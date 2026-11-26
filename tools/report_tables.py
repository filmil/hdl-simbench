"""Writes the report's LaTeX tables from //tools:summarize_runs CSV output.

  report_tables --out tables.tex --provenance provenance.tex \
      <results dir>/<campaign>/summary.csv [...]

A campaign is named by the directory of its summary.csv. Each campaign gets
one table per host and language: SystemVerilog, and VHDL (the cells of the
VHDL simulators, GHDL and NVC). A cell shows the median of its kept runs
with [minimum-maximum], as summarize_runs computed them; nothing is
recomputed here. Cells that summarize_runs did not report (more runs
needed, failing, cycles differ) are listed with their state and no
numbers. A rate marked resolution-limited gets a dagger; a missing rate
reads n/a. Each campaign and host also yields the commits and lockfile
hashes its cells ran at, for the report's provenance section.
"""

import argparse
import csv
import os
import sys

LANGUAGES = [("sv", "SystemVerilog"), ("vhdl", "VHDL")]
VHDL_SIMULATORS = {"ghdl", "nvc"}

# Design names as the report shows them: the VHDL case's package is named
# after the language, its design is NEORV32.
DESIGN_NAMES = {"vhdl": "NEORV32"}


def tex(s):
    """s with LaTeX's special characters escaped."""
    out = []
    for c in str(s):
        if c in "&%$#_{}":
            out.append("\\" + c)
        elif c == "~":
            out.append("\\textasciitilde{}")
        elif c == "^":
            out.append("\\textasciicircum{}")
        elif c == "\\":
            out.append("\\textbackslash{}")
        else:
            out.append(c)
    return "".join(out)


def language(row):
    return "vhdl" if row["simulator"] in VHDL_SIMULATORS else "sv"


def num(v, digits):
    """A number rounded to the given decimals, or, when it rounds to 10^5
    or more, three significant digits in exponent form."""
    x = round(float(v), digits)
    if abs(x) >= 1e5:
        return "%.2e" % x
    return "%.*f" % (digits, x)


def rng(row, key, digits):
    """'median [min-max]' for one metric; '--' for any part that is empty."""
    def one(k):
        v = row.get(k, "")
        return "--" if v == "" else num(v, digits)
    if row.get(key, "") == "":
        return "--"
    return "%s [%s--%s]" % (one(key), one(key + "_min"), one(key + "_max"))


def mib(row):
    """Peak RSS of the run in MiB, median [min-max]."""
    def one(k):
        v = row.get(k, "")
        return "--" if v == "" else "%.0f" % (float(v) / 1024.0)
    if row.get("run_maxrss_kib", "") == "":
        return "--"
    return "%s [%s--%s]" % (
        one("run_maxrss_kib"), one("run_maxrss_kib_min"), one("run_maxrss_kib_max"))


def cell_row(row):
    sim = "%s %s" % (row["simulator"], row["simulator_version"])
    cap = row["max_cycles"] or "--"
    design = DESIGN_NAMES.get(row["design"], row["design"])
    head = [tex(sim), tex(design), tex(row["case"]), tex(cap)]
    if row["state"] != "ok":
        return head + [
            "\\multicolumn{7}{l}{%s (%s of %s runs kept)}"
            % (tex(row["state"]), tex(row["kept"]), tex(row["runs"]))
        ]
    rate = rng(row, "cycles_per_s", 0)
    if rate == "--":
        rate = "n/a"
    if row["resolution_limited"] == "True":
        rate += "$^\\dagger$"
    return head + [
        tex(row["cycles"]),
        "%s/%s" % (tex(row["kept"]), tex(row["runs"])),
        rng(row, "compile_s", 2),
        rng(row, "run_s", 2),
        rng(row, "total_s", 2),
        rate,
        mib(row),
    ]


def table(campaign, host, lang_name, rows):
    lines = [
        "\\begin{table}[htbp]",
        "\\centering\\scriptsize",
        "\\caption{%s, campaign %s, host %s: median [min--max] of the kept runs.}"
        % (lang_name, tex(campaign), tex(host)),
        # Scaled down to the text width only when wider than it.
        "\\resizebox{\\ifdim\\width>\\textwidth\\textwidth\\else\\width\\fi}{!}{%",
        "\\begin{tabular}{llllrrllllr}",
        "\\hline",
        "Simulator & Design & Case & Cap & Cycles & Kept & Compile (s) & "
        "Run (s) & Total (s) & Cycles/s & Peak RSS (MiB) \\\\",
        "\\hline",
    ]
    for r in rows:
        lines.append(" & ".join(cell_row(r)) + " \\\\")
    lines += ["\\hline", "\\end{tabular}}", "\\end{table}", ""]
    return "\n".join(lines)


def provenance(campaign, rows):
    items = []
    for host in sorted({r["host"] for r in rows}):
        seen = []
        for r in rows:
            if r["host"] != host:
                continue
            key = (r["git_commit"], r["git_dirty"], r["lock_sha256"])
            if key not in seen:
                seen.append(key)
        parts = [
            "commit \\texttt{%s} (%s), lockfile \\texttt{%s}" % (tex(c), tex(d), tex(l))
            for c, d, l in seen
        ]
        items.append("\\item Campaign %s, host %s: %s.\n" % (
            tex(campaign), tex(host), "; ".join(parts)))
    return "".join(items)


def campaign_name(path):
    return os.path.basename(os.path.dirname(os.path.abspath(path)))


def main(argv):
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True)
    p.add_argument("--provenance", required=True)
    p.add_argument("summaries", nargs="+", help="<campaign>/summary.csv")
    a = p.parse_args(argv)
    tables, prov = [], []
    # Campaign directories are dates, so their names sort in the order the
    # campaigns ran.
    for path in sorted(a.summaries, key=campaign_name):
        name = campaign_name(path)
        with open(path, newline="") as f:
            rows = list(csv.DictReader(f))
        for host in sorted({r["host"] for r in rows}):
            for key, lang_name in LANGUAGES:
                sub = [r for r in rows if r["host"] == host and language(r) == key]
                if sub:
                    tables.append(table(name, host, lang_name, sub))
        prov.append(provenance(name, rows))
    with open(a.out, "w") as f:
        f.write("% Generated by //tools:report_tables. Do not edit.\n")
        f.write("\n".join(tables))
    with open(a.provenance, "w") as f:
        f.write("% Generated by //tools:report_tables. Do not edit.\n")
        f.write("\\begin{itemize}\n" + "".join(prov) + "\\end{itemize}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
