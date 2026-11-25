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

    def test_writes_one_table_per_language_and_provenance(self):
        d = tempfile.mkdtemp()
        src = os.path.join(d, "summary.csv")
        with open(src, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(ROW))
            w.writeheader()
            w.writerow(ROW)
            w.writerow(dict(ROW, design="VeeR-EL2", simulator="verilator"))
        out, prov = os.path.join(d, "t.tex"), os.path.join(d, "p.tex")
        report_tables.main(["--out", out, "--provenance", prov, "2=" + src])
        t = open(out).read()
        self.assertEqual(t.count("\\begin{table}"), 2)
        self.assertIn("SystemVerilog, campaign 2", t)
        self.assertIn("VHDL, campaign 2", t)
        self.assertIn("\\texttt{6d74d4c} (clean)", open(prov).read())


if __name__ == "__main__":
    unittest.main()
