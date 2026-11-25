# Campaign 1: SystemVerilog, 2026-11-25

The first timed runs of the SystemVerilog simulators, made with
`//bench:timed_runs` on 2026-11-25 between 06:04 and 09:25 UTC.

- Machine: one Intel Core i7-7700 (4 cores, 8 threads, 62 GB RAM), Linux.
  Every run was pinned to core 2; its hyperthread sibling (cpu6) was meant
  to be idle. Runs where it was more than 25% busy, or with more than 1%
  CPU steal, are dropped ([../../README.md](../../README.md), "Which runs
  count").
- Code: every run was made at commit ed4af78 of this repository; each row
  says so (`git_commit`, `git_dirty`, `lock_sha256`).
- Simulators: Verilator 5.046.bcr.6, Icarus Verilog 13.0.bcr.1, xezim
  0.11.7.bcr.1, all built from source with clang 23.1.5 and a glibc 2.31
  sysroot ([../../README.md](../../README.md), "Flags"). Verilator's and
  Icarus's binaries need nothing from the host but glibc. xezim
  0.11.7.bcr.1 also needs the host's `libgcc_s.so.1` (Rust's unwinder);
  each xezim run records the file it used (`host-lib` in its commands
  record). xezim 0.11.7.bcr.2 removes that need; it was not used here.
- Which runs count: [../../README.md](../../README.md), "Which runs
  count", fixed before any VeeR-EL2 result was seen and applied unchanged
  by `//tools:summarize_runs`.

## Files

- `slot1.csv`: whole runs: Example (all three simulators), VeeR-EL2 hello
  (Verilator, xezim), Servant hello (Verilator).
- `slot2.csv`, `slot2b.csv`: VeeR-EL2 CoreMark (Verilator, xezim; Icarus
  cannot parse VeeR-EL2), both capped at 10,000 cycles; `slot2b` is three more runs of the two cells that lost
  runs in `slot2`.
- `slot3.csv`, `slot3b.csv`: full-length CoreMark under Verilator
  (VeeR-EL2, Servant); `slot3b` is three more runs of VeeR-EL2 asic.
- `commands/`: each run's command lines and binary checks; the
  `commands_file` column of each row names its file (`commands/<name>`).
- `summary.md`, `summary.csv`: all five files summarized:

```
bazel run //tools:summarize_runs -- --csv results/20261125/summary.csv \
    results/20261125/slot1.csv results/20261125/slot2.csv \
    results/20261125/slot2b.csv results/20261125/slot3.csv \
    results/20261125/slot3b.csv > results/20261125/summary.md
```

Three cells are "more runs needed": the machine's CI runners loaded it
during their runs, and the rules dropped too many of them.

## Changes from the raw files

Only names, not numbers: the `host` column says `i7-7700`; `commands_file`
points into `commands/`; in the commands records the home directory reads
`~`, Bazel's output base `<output_base>` and its execution root
`<execroot>`, and the load addresses `ldd` prints (random on every run)
are removed.

`//results/20261125:results_test` checks that the summary still follows
from the per-run files, that every `commands_file` exists, and that the
records hold no home paths.
