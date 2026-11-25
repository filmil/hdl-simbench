# VHDL cases

NEORV32 v1.13.8, a RISC-V processor in VHDL, runs CoreMark under each VHDL
simulator. `coremark_tb.vhd` boots the program and ends the simulation when
CoreMark returns, so every simulator runs the same instructions and stops
at the same simulated time. A run counts only if it prints CoreMark's known
checksums and the iteration count it was built with. Its final checksum,
which covers every iteration, is checked against the same CoreMark built
for the host with the same count. A run that fails a check writes no
timings.

CoreMark is a trademark of EEMBC. The bench runs CoreMark® as a workload for
the simulators. It does not measure the simulated CPU, and its numbers are
not CoreMark scores.

## Flags

Every flag that changes what is built or how it runs is written here and in
the code that uses it. On each timed run, `vhdl_case.sh --commands <file>`
also records every simulator command line exactly as it ran, next to the
timings. Under `bazel test`, both records go to the test's undeclared
outputs as `timing.txt` and `commands.txt`, as for the SystemVerilog cases. Results without that record do not count.

The rule for every simulator: its documented default code generation, with
no debug, tracing, coverage or waveform options, and with run-time checks
as the design's own upstream scripts set them. Where a simulator has an
optimization level, the level is passed explicitly, so that the record
shows it, even when it is the default.

### The program: RISC-V GCC

The CoreMark image is built once, and every simulator runs the same image.

| | |
|---|---|
| Compiler | xPack riscv-none-elf-gcc 15.2.0-1, pinned by sha256 |
| Flags | `-march=rv32imc_zicsr_zifencei -mabi=ilp32 -O3 -Wall -Wextra -ffunction-sections -fdata-sections -mno-fdiv -mstrict-align -mbranch-cost=10 -ffp-contract=off` |
| Defines | `-DMULTITHREAD=1 -DUART0_SIM_MODE -DITERATIONS=<n>` |
| Link | `-nostartfiles -Wl,--gc-sections -lm -lc -lgcc`, NEORV32's `neorv32.ld` with 64 KiB ROM, 64 KiB RAM, 32 KiB heap |

These are NEORV32's own flags for its CoreMark port (its `Makefile` and
`sw/common/common.mk`), less `-g`. CoreMark prints the flags in its output.
Source: `coremark.bzl`.

### GHDL

| | |
|---|---|
| Build | BCR module `ghdl` 6.0.0.bcr.5, from source, mcode back end, with `ghdl_ada_opt.patch` |
| Ada (GNAT 16.1.0) | `-gnat12 -fPIC -w -gnatp -O -gnatn` |
| C and C++ (clang 23.1.5) | `-O2 -g0 -DNDEBUG -ffunction-sections -fdata-sections -fstack-protector-strong -D_FORTIFY_SOURCE=1 -fno-omit-frame-pointer`, from Bazel `-c opt` (the repository's `.bazelrc`) |
| Analysis | `ghdl -a --std=08 --workdir=lib -Plib --work=<library> <file>` |
| Run | `ghdl -r --std=08 --workdir=lib -Plib coremark_tb --max-stack-alloc=0 --ieee-asserts=disable --assert-level=error` |

The flags above are read from `bazel aquery` of `@ghdl//:ghdl_mcode`.
Without the patch, the module compiles GHDL's Ada with no `-O`, and
rules_ada ignores `-c opt`, so GHDL itself ran at `-O0`. The patch adds
`-O -gnatn`, the flags of GHDL's own release build (`Makefile.in` with
`--disable-checks`). Its `-gnatp` (no run-time checks) is the module's
and matches that build.

mcode has no optimization levels: it generates the design's machine code in
memory when `ghdl -r` starts, so that time counts as "run". The run options
are the ones NEORV32's `sim/ghdl.sh` uses. GHDL's LLVM and GCC back ends,
which compile ahead of time, can run faster than mcode; the BCR module does
not offer them. Its only other back end, llvm-jit, needs llvm-project
built from source, and the bench does not use it.

### NVC

Pending an attested binary (filmil/bazel_toolchains_nvc PR 2). Its flags go
here, with the optimization level of its elaboration step written out, once
it runs.

## Comparing the numbers

"compile" and "run" split the work differently per simulator (see
`vhdl_case.sh`), so the sum of the two is the comparable number. Analysis
runs one simulator command per library, with that library's files in
order, so process start-up is not counted once per file.

Timed runs use `//bench:timed_runs`, as for the SystemVerilog cases, for
example `bazel-bin/bench/timed_runs --core 2 --repeats 5 --out vhdl.csv
//bench/vhdl:coremark_ghdl_test`. Each step's wall, user and system time
and peak memory come from `/usr/bin/time`; the cycles are the clock cycles
the testbench simulated (its "simbench cycles" line), so cycles per second
of "run" can be compared across simulators. With `--readelf`, the
simulator binary may take only glibc 2.31 or older from the host, with no
symbol version tied to a newer or particular glibc, plus the libraries
`--allow-host-lib` names, each recorded with its path and SHA-256. Its
NEEDED list is in the command record. Only the binary's own needs are
checked: not those of an allowed library, and not code NVC generates. Each
timed run also records the machine, the simulator's version and the
command lines.
