# hdl-simbench

VHDL and SystemVerilog simulators compared on the same designs, under
comparable conditions, built with Bazel.

Work in progress; see https://github.com/filmil/hdl-simbench/issues/1.

## What is compared

- SystemVerilog: Verilator (5.046, built from source by its BCR module),
  Icarus Verilog (13.0), xezim (0.11.7.bcr.1, from filmil/bazel-registry).
- VHDL: GHDL, NVC.

All C and C++ is compiled by one hermetic compiler: clang 23.1.5 with
Chromium's Debian bullseye sysroot (glibc 2.31), registered for the whole
build. It builds Verilator and Icarus, and compiles the C++ model Verilator
writes for each case and DPI-C sources. xezim's module builds xezim's C code
and link with its own copy of the same LLVM release and sysroot. The bench
needs no compiler on the machine it runs on.

The C++ library is LLVM's libc++, with libc++abi, libunwind and
compiler-rt, all linked statically. So the SystemVerilog simulators'
binaries and the Verilator models need nothing from the host but glibc
2.31 or older, with one exception: xezim needs `libgcc_s.so.1` (see
"Flags", xezim). Each SystemVerilog case checks the binaries it runs
(`check_elf` in `bench/rtlmeter_case.sh`): every library they need must be
one of glibc's, or named as an exception. It records their NEEDED lists,
the newest glibc version they need, and the host's `ldd` output with the
case's command lines. Not checked: the DPI-C library xezim compiles while
a case runs, and the VHDL simulators, whose cases `bench/vhdl/` runs.

Only open-source simulators are reported. Commercial simulator licenses
commonly forbid publishing benchmark results; Vivado's, for one, does
(its EULA, section 4(b)(iii)).

## Designs

- SystemVerilog: the cases of [RTLMeter](https://github.com/verilator/rtlmeter),
  Verilator's benchmark suite, in `third_party/rtlmeter` (Apache-2.0). So far:
  Example, Servant (SERV, a bit-serial RISC-V core) and VeeR-EL2.
- Each design's `descriptor.yaml` is turned into `cases.bzl` by
  `bazel run //tools:rtlmeter_import -- third_party/rtlmeter/designs/<design>`,
  resolved exactly as RTLMeter resolves it; one test per configuration, test
  and simulator follows. Cases over 100000 cycles are tagged `manual` and
  `long`: they are for the timed runs, not for CI.
- VHDL: NEORV32 running CoreMark (to come).

## How a case is checked

RTLMeter's harness counts cycles of the design's main clock and writes the
count to `_rtlmeter_cycles.txt` when the simulation ends. A simulator passes
a case when that count equals the case's expected cycles and its output has
the expected lines. Only passing runs are timed.

```
bazel test //...
```

## Timed runs

`//bench:timed_runs` runs chosen case tests one at a time, pinned to one
core, and appends a CSV row per run: wall, user and system time and peak
memory of each step (Verilator's translation, the compile, the run), the
cycles simulated and cycles per second, and the machine's state around the
run (load average before, during and after; how busy the pinned core, its
hyperthread sibling and the other cores were; CPU steal).

The host needs `taskset` (util-linux) and GNU time as `/usr/bin/time`;
without GNU time the user, system and peak memory columns are empty.

```
bazel build //bench:timed_runs
bazel-bin/bench/timed_runs --core 2 --repeats 5 --out results.csv \
    //third_party/rtlmeter/designs/Example:kind_hello_verilator_test
```

## Which runs count

Fixed on 2026-11-25, before any VeeR-EL2 result was seen, and applied
unchanged to all data:

- A run is dropped if its CSV row has `sibling_busy_pct` over 25 (the
  pinned core's hyperthread sibling was busy) or `steal_pct` over 1.
- Each cell (simulator, design, case, step) reports the median of its kept
  runs, with their minimum and maximum.
- Next to "compile" and "run", each cell reports "total": compile plus run
  (plus "verilate" for Verilator) of the same run. For short simulations
  the total decides which simulator is faster.
- If more than a third of a cell's runs are dropped, the cell gets more
  runs instead of a median of what is left.
- Runs that fail are not timed results; a cell with a failing run is
  reported as failing.

## Flags

Every flag that changes what is built or how it runs is written here and in
the code that uses it (`bench/rtlmeter_case.sh`, `bench/rtlmeter.bzl`). On
every run, `rtlmeter_case.sh` also records each command line exactly as it
ran, one line per command, `<step> <argv, shell-quoted>` (the format of
`bench/vhdl/vhdl_case.sh`): with `--commands <file>`, or as `commands.txt`
in the test's outputs, which `//bench:timed_runs` keeps beside its CSV, one
file per row. Results without that record do not count.

The policy, the same for both languages:

- Each simulator's documented default code generation, with no debug,
  tracing, coverage or waveform options (RTLMeter's `+trace` is never
  passed).
- Optimization levels written out on every compiler, even when they are the
  default. Where a simulator has no flag for its default level, that is
  said below.
- One simulation thread, as each run has one pinned core.
- For throughput, every simulator stops at the same cycle count: RTLMeter's
  `+max_cycles`, set by `timed_runs --max-cycles`.
- The simulators themselves are built optimized: `--compilation_mode=opt`
  in `.bazelrc` (C/C++ at `-O2`, no debug info; Rust's release profile).

### The C/C++ compiler

clang 23.1.5 (toolchains_llvm 1.13.0) with Chromium's Debian bullseye
sysroot (glibc 2.31), for the whole build. For each case it also compiles
Verilator's model and DPI-C sources, through wrappers recorded as steps
`cxx` and `cc`:

| | |
|---|---|
| C++ | `clang++ --sysroot=<sysroot> -stdlib=libc++ -fuse-ld=lld -Wno-unused-command-line-argument <args> -nostdlib++ -rtlib=compiler-rt --unwindlib=none -L<llvm>/lib/x86_64-unknown-linux-gnu -l:libc++.a -l:libc++abi.a -l:libunwind.a` |
| C | `clang --sysroot=<sysroot> -fuse-ld=lld -rtlib=compiler-rt --unwindlib=none -Wno-unused-command-line-argument` |

The simulators themselves are built by the same toolchain. Some of the
modules they need rely on headers that libstdc++ includes by the way and
libc++ does not, so `.bazelrc` adds `-include` of `cstdlib`, `cstring`,
`iterator` and `algorithm` to every C++ compile of the build. That does not
reach the Verilator models, which the wrapper above compiles.

### Verilator

| | |
|---|---|
| Build | BCR module `verilator` 5.046.bcr.6, from source, `-c opt` |
| verilate | `verilator --cc --main --timing --threads 1 -Wno-fatal --top-module <top> +incdir+<dir> --Mdir obj -o sim`, the case's `+define+`, `-G` and extra options (RTLMeter's, less `--quiet-stats`) |
| compile | `clang++ … -std=c++20 -O2 -DVM_TRACE=0` over the model and Verilator's runtime (`verilated*.cpp`), `-pthread` |
| run | `obj/sim <plusargs>` |

Caveat: Verilator's own optimization level is its default, as in RTLMeter.
It has flags only for less (`-O0`) or more (`-O3`, slower to verilate), not
one that names the default. `-O2` for the model's C++ is the level
Verilator's own build uses by default (`OPT_FAST`).

### Icarus Verilog

| | |
|---|---|
| Build | BCR module `iverilog` 13.0.bcr.1, from source, `-c opt` |
| compile | `iverilog -B <base> -g2012 -s <top> -I <dir> -o sim.vvp`, the case's `-D` and `-P<top>.<name>=<value>` |
| run | `vvp -M <base> -n sim.vvp <plusargs>` |

Icarus has no optimization levels or threads to set. It has no DPI-C, so
cases with C++ sources are not run on it.

### xezim

| | |
|---|---|
| Build | filmil/bazel-registry module `xezim` 0.11.7.bcr.1, from source, optimized (its module builds it so) |
| compile | `xezim --no-cache --compile -o design.xzc -s <top> +incdir+<dir>`, the case's `+define+` and `-g/<top>/<name>=<value>` |
| run | `xezim --no-cache design.xzc <DPI-C sources> <plusargs>` |

Caveat: xezim needs `libgcc_s.so.1` from the host. Rust's standard library
on linux-gnu links it for stack unwinding, and that cannot be changed from
outside xezim's build. It is the one host library besides glibc that any
timed binary needs; each run records which file it was (its path and
SHA-256, step `host-lib` in the commands record).

`--no-cache`: xezim otherwise caches elaborated designs in `~/.cache`, and
a cached compile would not be timed. Strict IEEE 1800 (no `--relax-*`
option). Caveat: xezim has no optimization levels; it simulates on one
thread. It compiles DPI-C sources when the design runs, so their compile
is timed in its "run" step.

## Comparing the numbers

"compile" and "run" split the work differently per simulator (Verilator
also has "verilate"), so their sum is the comparable whole-run number;
cycles per second of "run" is the throughput.

## License

Apache-2.0 (`LICENSE`). Third-party code keeps its own license, in its
directory under `third_party/`.
