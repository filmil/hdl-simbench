"""Checks the published results of campaign 1 against their sources.

- summary.csv is what //tools:summarize_runs makes of the per-run files.
- Every row's commands_file exists in commands/, and every file there is
  named by a row.
- No commands record or CSV holds a home path.
"""

import csv
import io
import os
import unittest
from contextlib import redirect_stdout

import summarize_runs

HERE = os.path.dirname(os.path.abspath(__file__))
RUNS = ["slot1.csv", "slot2.csv", "slot2b.csv", "slot3.csv", "slot3b.csv"]


def _path(name):
    return os.path.join(HERE, name)


def _rows():
    rows = []
    for name in RUNS:
        with open(_path(name), newline="") as f:
            rows.extend(csv.DictReader(f))
    return rows


class ResultsTest(unittest.TestCase):

    def test_summary_follows_from_runs(self):
        with open(_path("summary.csv"), newline="") as f:
            published = list(csv.reader(f))
        out = io.StringIO()
        w = csv.DictWriter(out, fieldnames=summarize_runs.CSV_COLUMNS)
        w.writeheader()
        w.writerows(summarize_runs.summarize(_rows()))
        made = list(csv.reader(io.StringIO(out.getvalue())))
        self.assertEqual(made, published)

    def test_summary_md_follows_from_runs(self):
        with open(_path("summary.md")) as f:
            published = f.read().strip()
        with redirect_stdout(io.StringIO()):
            made = summarize_runs.markdown(summarize_runs.summarize(_rows()))
        self.assertEqual(made.strip(), published)

    def test_commands_files(self):
        named = set()
        for r in _rows():
            p = r["commands_file"]
            self.assertTrue(p.startswith("commands/"), p)
            self.assertTrue(os.path.isfile(_path(p)), p)
            named.add(os.path.basename(p))
        self.assertEqual(named, set(os.listdir(_path("commands"))))

    def test_no_home_paths(self):
        files = [_path(n) for n in RUNS + ["summary.csv", "summary.md"]]
        files += [_path(os.path.join("commands", n)) for n in os.listdir(_path("commands"))]
        for p in files:
            with open(p) as f:
                text = f.read()
            self.assertNotIn("/home/", text, p)


if __name__ == "__main__":
    unittest.main()
