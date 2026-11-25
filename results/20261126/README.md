# Campaign 2: extra runs and GHDL, 2026-11-25

Made with `//bench:timed_runs` on 2026-11-25 between 09:59 and 11:08 UTC,
on the same machine and core as campaign 1 (`../20261125/README.md`).

What differs from campaign 1:

- The machine's CI runners were paused for the whole window:
  `forgejo-runner-eph2` and `forgejo-runner-eph2-vivado` were scaled to 0
  at 09:47:09 UTC, both idle, and resumed after 11:08 UTC. In campaign 1
  their jobs loaded the machine, and the rules dropped too many runs of
  three cells.
- Code: commit 6d74d4c, whose `//bench:timed_runs` keeps Bazel's own
  client and server off the pinned core and its sibling (taskset on the
  other CPUs). The measurement itself is unchanged.
- Simulators: as in campaign 1 (xezim 0.11.7.bcr.1, so that its cells
  match campaign 1's), plus GHDL 6.0.0.bcr.5 for VHDL.

## Files

- `sv-cap.csv`: VeeR-EL2 CoreMark capped at 10,000 cycles, the two cells
  campaign 1 could not report: xezim hiperf and Verilator asic, 3 runs each.
- `sv-full.csv`: VeeR-EL2 asic CoreMark at full length under Verilator, the
  third such cell, 3 runs.
- `vhdl-ghdl.csv`: NEORV32 running CoreMark (`//bench/vhdl:coremark_ghdl_test`)
  under GHDL, 5 runs. A VHDL design, not comparable with the SystemVerilog
  cells.
- `commands/`, `summary.md`, `summary.csv`: as in campaign 1; the summary
  is made from the three CSV files in name order.

The same rules decide which runs count ([../../README.md](../../README.md),
"Which runs count"), and the same names are changed (`../20261125/README.md`,
"Changes from the raw files"). `//results:results_test` checks this
campaign as it does campaign 1.
