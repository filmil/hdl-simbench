"""Checks every published campaign under results/ against its sources.

Each campaign directory holds per-run CSV files (every *.csv but
summary.csv), commands/, summary.csv and summary.md.

- summary.csv is what //tools:summarize_runs makes of the per-run files.
- Every row's commands_file exists in commands/, and every file there is
  named by a row.
- No commands record or CSV holds a home path.
"""

import csv
import re
import io
import os
import unittest
from contextlib import redirect_stdout

import summarize_runs

HERE = os.path.dirname(os.path.abspath(__file__))
# A campaign directory is named <yyyymmdd> or <yyyymmdd>-<suffix>.
CAMPAIGN_NAME = re.compile(r"\d{8}(?:-[a-z0-9][a-z0-9-]*)?")


def is_campaign(name):
    return CAMPAIGN_NAME.fullmatch(name) is not None


CAMPAIGNS = sorted(d for d in os.listdir(HERE) if is_campaign(d) and os.path.isdir(os.path.join(HERE, d)))


def _runs(campaign):
    d = os.path.join(HERE, campaign)
    return sorted(n for n in os.listdir(d) if n.endswith(".csv") and n != "summary.csv")


def _rows(campaign):
    rows = []
    for name in _runs(campaign):
        with open(os.path.join(HERE, campaign, name), newline="") as f:
            rows.extend(csv.DictReader(f))
    return rows


class ResultsTest(unittest.TestCase):

    def test_there_are_campaigns(self):
        self.assertIn("20261125", CAMPAIGNS)
        self.assertIn("20261126-nvc", CAMPAIGNS)

    def test_campaign_names(self):
        for good in ["20261125", "20261126-nvc", "20261201-sv-2"]:
            self.assertTrue(is_campaign(good), good)
        for bad in ["2026", "20261126wip", "20261126-", "__pycache__", "x20261126"]:
            self.assertFalse(is_campaign(bad), bad)

    def test_summary_follows_from_runs(self):
        for c in CAMPAIGNS:
            with self.subTest(campaign=c):
                with open(os.path.join(HERE, c, "summary.csv"), newline="") as f:
                    published = list(csv.reader(f))
                out = io.StringIO()
                w = csv.DictWriter(out, fieldnames=summarize_runs.CSV_COLUMNS)
                w.writeheader()
                w.writerows(summarize_runs.summarize(_rows(c)))
                self.assertEqual(list(csv.reader(io.StringIO(out.getvalue()))), published)

    def test_summary_md_follows_from_runs(self):
        for c in CAMPAIGNS:
            with self.subTest(campaign=c):
                with open(os.path.join(HERE, c, "summary.md")) as f:
                    published = f.read().strip()
                with redirect_stdout(io.StringIO()):
                    made = summarize_runs.markdown(summarize_runs.summarize(_rows(c)))
                self.assertEqual(made.strip(), published)

    def test_commands_files(self):
        for c in CAMPAIGNS:
            with self.subTest(campaign=c):
                named = set()
                for r in _rows(c):
                    p = r["commands_file"]
                    self.assertTrue(p.startswith("commands/"), p)
                    self.assertTrue(os.path.isfile(os.path.join(HERE, c, p)), p)
                    named.add(os.path.basename(p))
                self.assertEqual(named, set(os.listdir(os.path.join(HERE, c, "commands"))))

    def test_no_home_paths(self):
        for c in CAMPAIGNS:
            d = os.path.join(HERE, c)
            files = [os.path.join(d, n) for n in os.listdir(d) if os.path.isfile(os.path.join(d, n))]
            files += [os.path.join(d, "commands", n) for n in os.listdir(os.path.join(d, "commands"))]
            for p in files:
                with open(p) as f:
                    self.assertNotIn("/home/", f.read(), p)


if __name__ == "__main__":
    unittest.main()
