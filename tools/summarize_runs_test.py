"""Tests of tools/summarize_runs.py: the README's rule for which runs count."""

import csv
import io
import os
import tempfile
import unittest
from contextlib import redirect_stdout

import summarize_runs as s


def row(sim="verilator", case="kind_hello", status="pass", sib="0", steal="0",
        verilate="1", compile_="10", run="2", cps="500000", cap="", cycles="1000000",
        version="1", commit="abcdef0123", dirty="clean"):
    return {
        "host": "eph2", "simulator": sim, "simulator_version": version, "design": "Example",
        "case": case, "status": status, "max_cycles": cap, "cycles": cycles,
        "sibling_busy_pct": sib, "steal_pct": steal,
        "verilate_wall_s": verilate, "compile_wall_s": compile_,
        "run_wall_s": run, "cycles_per_s": cps, "run_maxrss_kib": "100",
        "git_commit": commit, "git_dirty": dirty, "lock_sha256": "f00d" * 16,
    }


class SummarizeTest(unittest.TestCase):

    def test_drop_rule(self):
        self.assertFalse(s.dropped(row(sib="25", steal="1")))
        self.assertTrue(s.dropped(row(sib="25.1")))
        self.assertTrue(s.dropped(row(steal="1.1")))
        self.assertFalse(s.dropped(row(sib="", steal="")))

    def test_median_and_total(self):
        cells = s.summarize([row(run="2"), row(run="3"), row(run="10")])
        c = cells[0]
        self.assertEqual(c["state"], "ok")
        self.assertEqual(c["kept"], 3)
        self.assertEqual(c["run_s"], 3)
        self.assertEqual(c["run_s_min"], 2)
        self.assertEqual(c["run_s_max"], 10)
        # compile includes verilate; total is compile + run of the same run.
        self.assertEqual(c["compile_s"], 11)
        self.assertEqual(c["total_s"], 14)

    def test_total_is_per_run(self):
        # Medians of compile and run come from different runs here; the
        # total is the median of each run's own compile + run.
        cells = s.summarize([
            row(verilate="0", compile_="1", run="100"),
            row(verilate="0", compile_="50", run="1"),
            row(verilate="0", compile_="100", run="50"),
        ])
        c = cells[0]
        self.assertEqual(c["compile_s"], 50)
        self.assertEqual(c["run_s"], 50)
        self.assertEqual(c["total_s"], 101)

    def test_missing_rate_is_not_zero(self):
        c = s.summarize([row(cps=""), row(), row()])[0]
        self.assertIsNone(c["cycles_per_s"])
        self.assertNotIn("0 [0", s.markdown([c]))

    def test_zero_run_with_long_median_is_resolution_limited(self):
        c = s.summarize([row(run="0.00"), row(run="5"), row(run="6")])[0]
        self.assertTrue(c["resolution_limited"])
        self.assertIsNone(c["cycles_per_s"])

    def test_cycles_differ(self):
        c = s.summarize([row(), row(cycles="999999"), row()])[0]
        self.assertEqual(c["state"], "cycles differ")

    def test_versions_and_hosts_are_separate_cells(self):
        cells = s.summarize([row(), row(version="2")])
        self.assertEqual(len(cells), 2)

    def test_provenance(self):
        c = s.summarize([row(), row(commit="1234567abc", dirty="dirty"), row()])[0]
        self.assertEqual(c["git_commit"], "1234567 abcdef0")
        self.assertIn("(dirty)", s.markdown([c]))

    def test_main_csv_has_fixed_columns(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "in.csv")
            with open(src, "w", newline="") as f:
                w = csv.DictWriter(f, fieldnames=list(row().keys()))
                w.writeheader()
                w.writerows([row(status="fail")] * 3)
            out = os.path.join(d, "out.csv")
            with redirect_stdout(io.StringIO()):
                s.main([src, "--csv", out])
            with open(out, newline="") as f:
                r = csv.reader(f)
                self.assertEqual(next(r), s.CSV_COLUMNS)
                self.assertEqual(len(list(r)), 1)

    def test_one_dropped_of_three_is_kept(self):
        c = s.summarize([row(), row(), row(sib="50")])[0]
        self.assertEqual(c["state"], "ok")
        self.assertEqual(c["kept"], 2)

    def test_more_than_a_third_dropped_needs_more_runs(self):
        c = s.summarize([row(), row(sib="50"), row(steal="5")])[0]
        self.assertEqual(c["state"], "more runs needed")

    def test_failing_cell(self):
        c = s.summarize([row(), row(status="fail"), row()])[0]
        self.assertEqual(c["state"], "failing")

    def test_cells_by_simulator_case_and_cap(self):
        cells = s.summarize([
            row(sim="verilator"), row(sim="xezim"),
            row(sim="xezim", cap="100000"), row(sim="xezim", case="kind_user"),
        ])
        self.assertEqual(len(cells), 4)

    def test_resolution_limited(self):
        self.assertTrue(s.summarize([row(run="0.14")] * 3)[0]["resolution_limited"])
        self.assertFalse(s.summarize([row(run="1.0")] * 3)[0]["resolution_limited"])
        self.assertIn("resolution-limited", s.markdown(s.summarize([row(run="0.1")] * 3)))

    def test_zero_duration_run_has_no_rate(self):
        # Servant qerv hello on eph2: 16,560 cycles in "0.00" s.
        cells = s.summarize([row(run="0.00", cps="")] * 2 + [row(run="0.01", cps="1656000")])
        self.assertIsNone(cells[0]["cycles_per_s"])
        md = s.markdown(cells)
        self.assertIn("n/a (resolution-limited)", md)
        self.assertNotIn("| 0 [0-0]", md)

    def test_markdown(self):
        md = s.markdown(s.summarize([row(), row(), row()]))
        self.assertIn("| verilator 1 | Example | kind_hello | - |", md)
        self.assertIn("3/3", md)


if __name__ == "__main__":
    unittest.main()
