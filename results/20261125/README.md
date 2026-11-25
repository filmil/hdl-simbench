# Campaign 1: SystemVerilog, 2026-11-25

The first timed runs of the SystemVerilog simulators, made with
`//bench:timed_runs` on 2026-11-25 between 06:06 and 09:24 UTC.

- Machine: one Intel Core i7-7700 (4 cores, 8 threads, 62 GB RAM), Linux.
  Every run was pinned to core 2; its hyperthread sibling (cpu6) was meant
  to be idle, and runs where it was not are dropped by the rules below.
- Code: every run was made at commit ed4af78 of this repository; each row
  says so (`git_commit`, `git_dirty`, `lock_sha256`).
- Simulators: Verilator 5.046.bcr.6, Icarus Verilog 13.0.bcr.1, xezim
  0.11.7.bcr.1, all built from source with clang 23.1.5 (README.md,
  "Flags").
- Which runs count: README.md, "Which runs count", fixed before any
  VeeR-EL2 result was seen and applied unchanged by `//tools:summarize_runs`.

## Files

- `slot1.csv`: whole runs: Example (all three simulators), VeeR-EL2 hello
  (Verilator, xezim), Servant hello (Verilator).
- `slot2.csv`, `slot2b.csv`: VeeR-EL2 CoreMark, every simulator capped at
  10,000 cycles; `slot2b` is three more runs of the two cells that lost
  runs in `slot2`.
- `slot3.csv`, `slot3b.csv`: full-length CoreMark under Verilator
  (VeeR-EL2, Servant); `slot3b` is three more runs of VeeR-EL2 asic.
- `commands/`: each run's command lines and binary checks, named by the
  `commands_file` column.
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

Only names, not numbers: the `host` column says `i7-7700` instead of the
machine's host name; in `commands_file` and in the commands records, the
home directory reads `~`, Bazel's output base `<output_base>` and its
execution root `<execroot>`.
