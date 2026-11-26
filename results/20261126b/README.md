# Campaign 3: NVC, 2026-11-26

Made with `//bench:timed_runs` on 2026-11-26 between 06:07 and 06:14 UTC,
on the same machine and core as campaigns 1 and 2
(`../20261125/README.md`).

- The machine's CI runners were paused for the whole window, as in
  campaign 2: scaled to 0 at 05:59:57 UTC, before the first run.
- Code: commit f53c92a.
- Simulator: NVC 1.22.0 (commit 324ed157), from the release
  `nvc-1.22.0-324ed157-r2` (`../../bench/vhdl/README.md`, "NVC").
- All 5 runs were kept; the sibling thread was 3.7-5.9% busy.

## Files

- `vhdl-nvc.csv`: NEORV32 running CoreMark (`//bench/vhdl:coremark_nvc_test`)
  under NVC, 5 runs. The same case as campaign 2's `vhdl-ghdl.csv`.
- `nvc-stats.log`: one further, untimed run of NVC's elaboration
  (`-e -V --stats`) and run (`-r --stats`) with run 1's arguments, for how
  NVC splits its work. It is not in the summary.
- `commands/`, `summary.md`, `summary.csv`: as in campaign 1.

## Changes from the raw files

As in campaign 1 (`../20261125/README.md`, "Changes from the raw files"),
for the CSV file, the commands records and `nvc-stats.log`. In addition, the
raw `simulator_version` column is empty: `//bench:timed_runs` read versions
only from `bazel_dep` lines, and NVC is an `http_archive`. It is filled in
with the pinned release, `1.22.0-324ed157-r2`; `//bench:timed_runs` now
reads it from the pin.
