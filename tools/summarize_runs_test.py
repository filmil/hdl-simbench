"""Tests of tools/summarize_runs.py: the README's rule for which runs count."""

import unittest

import summarize_runs as s


def row(sim="verilator", case="kind_hello", status="pass", sib="0", steal="0",
        verilate="1", compile_="10", run="2", cps="500000", cap=""):
    return {
        "simulator": sim, "simulator_version": "1", "design": "Example",
        "case": case, "status": status, "max_cycles": cap, "cycles": "1000000",
        "sibling_busy_pct": sib, "steal_pct": steal,
        "verilate_wall_s": verilate, "compile_wall_s": compile_,
        "run_wall_s": run, "cycles_per_s": cps, "run_maxrss_kib": "100",
        "git_commit": "abcdef0123",
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

    def test_markdown(self):
        md = s.markdown(s.summarize([row(), row(), row()]))
        self.assertIn("| verilator 1 | Example | kind_hello | - |", md)
        self.assertIn("3/3", md)


if __name__ == "__main__":
    unittest.main()
