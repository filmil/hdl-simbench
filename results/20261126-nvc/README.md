# Campaign 3: NVC, 2026-11-26

NVC running NEORV32 CoreMark (`//bench/vhdl:coremark_nvc_test`), made with
`//bench:timed_runs` on 2026-11-26 between 06:07:34 and about 06:12:40
UTC (the five runs; the untimed diagnostic below followed), on the
same machine and core as campaigns 1 and 2 (`../20261125/README.md`). It
is the VHDL counterpart of GHDL's runs in `../20261126/vhdl-ghdl.csv`:
the same design, program and cycle count (1,252,946).

- Code: commit f53c92a; Bazel kept off the pinned core and its sibling.
- The machine's CI runners were paused: `forgejo-runner-eph2` and
  `forgejo-runner-eph2-vivado` scaled to 0 at 05:59:57 UTC (both pods gone
  at 06:00:03, no job running) and back to 1 at 06:14:41 UTC. Buildbarn's
  worker on the machine (`bb-worker-eph2`) kept running.
- Simulator: NVC 1.22.0 at commit 324ed157 ("1.22-devel, using LLVM
  18.1.8" in `nvc --version`): the archive
  `nvc-1.22.0-324ed157-r2-linux-x86_64.tar.gz` from
  https://github.com/filmil/bazel_toolchains_nvc/releases/tag/nvc-1.22.0-324ed157-r2,
  SHA-256 046191b1d06e23cd3fea57df050ac5b99936d18516434d900ffb4aa61520cbdd,
  fetched by `http_archive` in MODULE.bazel at f53c92a. The
  CSV's `simulator_version` column is empty for it: `//bench:timed_runs`
  reads versions from `bazel_dep` lines in MODULE.bazel, and NVC is not
  one.
- CoreMark prints "ERROR! Must execute for at least 10 secs" and "Errors
  detected": CoreMark's own rule for a valid score, which one simulated
  iteration (12.5 ms of simulated time) cannot meet. Its CRCs match
  (`crcfinal 0xe714`); this bench times the simulator, not CoreMark's
  score.

## Files

- `vhdl-nvc.csv`: 5 runs; `commands/`; `summary.md`, `summary.csv`, as in
  the other campaigns.
- `nvc-stats.log`: an untimed diagnostic after the timed runs, not in the
  CSV. Run 1's commands again in a fresh directory: its two analysis
  commands (`-a`) as they were, not logged; then elaboration with
  `-e -V --stats` and the run with `-r --stats` (NVC 1.22 takes `--stats`
  only as an option of `-e` and `-r`), each under `/usr/bin/time` and
  pinned to core 2. Elaboration took 0.28 s ("elaborating design
  [269ms +70264kB]"); the run reported "setup:91ms run:59538ms".

Names are changed as in campaign 1 (`../20261125/README.md`, "Changes from
the raw files").
