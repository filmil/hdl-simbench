"""Tests for report_tables: escaping, cell rows and the files it writes."""

import csv
import os
import tempfile
import unittest

import report_tables

ROW = {
    "host": "i7-7700", "simulator": "ghdl", "simulator_version": "6.0.0.bcr.5",
    "design": "vhdl", "case": "core_mark", "max_cycles": "", "state": "ok",
    "runs": "5", "kept": "5", "cycles": "1252946", "resolution_limited": "False",
    "compile_s": "0.07", "compile_s_min": "0.07", "compile_s_max": "0.1",
    "run_s": "268.88", "run_s_min": "252.61", "run_s_max": "281.81",
    "total_s": "268.95", "total_s_min": "252.68", "total_s_max": "281.89",
    "cycles_per_s": "4659.9", "cycles_per_s_min": "4446.1", "cycles_per_s_max": "4960.0",
    "run_maxrss_kib": "212032.0", "run_maxrss_kib_min": "211908.0",
    "run_maxrss_kib_max": "212096.0",
    "git_commit": "6d74d4c", "git_dirty": "clean", "lock_sha256": "495d331e97a3",
}


class ReportTablesTest(unittest.TestCase):

    def test_tex_escapes_specials(self):
        self.assertEqual(report_tables.tex("a_b&c%d#e"), "a\\_b\\&c\\%d\\#e")
        self.assertEqual(report_tables.tex("{x}"), "\\{x\\}")
        self.assertEqual(report_tables.tex("~^\\"),
                         "\\textasciitilde{}\\textasciicircum{}\\textbackslash{}")

    def test_missing_min_or_max_is_a_dash(self):
        cells = report_tables.cell_row(dict(ROW, run_s_max=""))
        self.assertEqual(cells[7], "268.88 [252.61----]")

    def test_cap_is_shown(self):
        self.assertEqual(report_tables.cell_row(dict(ROW, max_cycles="10000"))[3], "10000")

    def test_ok_row_has_ranges_from_the_summary(self):
        cells = report_tables.cell_row(ROW)
        self.assertEqual(len(cells), 11)
        self.assertEqual(cells[2], "core\\_mark")
        self.assertEqual(cells[7], "268.88 [252.61--281.81]")
        self.assertEqual(cells[9], "4660 [4446--4960]")
        self.assertEqual(cells[10], "207 [207--207]")

    def test_resolution_limited_gets_a_dagger(self):
        cells = report_tables.cell_row(dict(ROW, resolution_limited="True"))
        self.assertTrue(cells[9].endswith("$^\\dagger$"))

    def test_unreported_cell_has_no_numbers(self):
        cells = report_tables.cell_row(dict(ROW, state="more runs needed", kept="1"))
        self.assertEqual(len(cells), 5)
        self.assertIn("more runs needed (1 of 5 runs kept)", cells[4])
        self.assertNotIn("268", cells[4])

    def test_missing_rate_is_na(self):
        cells = report_tables.cell_row(dict(ROW, cycles_per_s="", resolution_limited="True"))
        self.assertEqual(cells[9], "n/a$^\\dagger$")

    def test_vhdl_design_is_named(self):
        self.assertEqual(report_tables.cell_row(ROW)[1], "NEORV32")

    def test_large_numbers_use_exponents(self):
        self.assertEqual(report_tables.num("6666666.7", 0), "6.67e+06")
        # Rounded first: 99999.6 rounds to 100000, so it takes the exponent.
        self.assertEqual(report_tables.num("99999.6", 0), "1.00e+05")
        self.assertEqual(report_tables.num("99999.4", 0), "99999")

    def test_language_follows_the_simulator(self):
        self.assertEqual(report_tables.language(dict(ROW, design="other")), "vhdl")
        self.assertEqual(report_tables.language(dict(ROW, simulator="xezim")), "sv")

    def _summary(self, d, campaign, rows):
        os.makedirs(os.path.join(d, campaign))
        path = os.path.join(d, campaign, "summary.csv")
        with open(path, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(ROW))
            w.writeheader()
            for row in rows:
                w.writerow(row)
        return path

    def test_tables_per_campaign_host_and_language_with_provenance(self):
        d = tempfile.mkdtemp()
        later = self._summary(d, "20261126", [
            ROW,
            dict(ROW, design="VeeR-EL2", simulator="verilator"),
            dict(ROW, host="other", git_commit="abc1234"),
        ])
        earlier = self._summary(d, "20261125", [dict(ROW, git_commit="0000001")])
        out, prov = os.path.join(d, "t.tex"), os.path.join(d, "p.tex")
        # Given out of order: campaigns come out in date order.
        report_tables.main(["--out", out, "--provenance", prov, later, earlier])
        with open(out) as f:
            t = f.read()
        with open(prov) as f:
            p = f.read()
        self.assertEqual(t.count("\\begin{table}"), 4)
        self.assertLess(t.index("campaign 20261125"), t.index("campaign 20261126"))
        self.assertIn("SystemVerilog, campaign 20261126, host i7-7700", t)
        self.assertIn("VHDL, campaign 20261126, host other", t)
        self.assertIn("Campaign 20261126, host other: commit \\texttt{abc1234}", p)
        self.assertIn("Campaign 20261125, host i7-7700: commit \\texttt{0000001}", p)
        self.assertEqual(p.count("\\item"), 3)

if __name__ == "__main__":
    unittest.main()
