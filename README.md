# hdl-simbench

VHDL and SystemVerilog simulators compared on the same designs, under
comparable conditions, built with Bazel.

Work in progress; see https://github.com/filmil/hdl-simbench/issues/1.

## What is compared

- SystemVerilog: Verilator (5.046, built from source by its BCR module),
  Icarus Verilog (13.0), xezim (0.11.7.bcr.1, from filmil/bazel-registry).
- VHDL: GHDL, NVC.

All C and C++ is compiled by one hermetic toolchain: clang 23.1.5 with
Chromium's Debian bullseye sysroot (glibc 2.31), registered for the whole
build. That covers the simulators themselves (xezim's C code and link
included), the C++ model Verilator writes for each case, and DPI-C sources.
The bench needs no compiler on the machine it runs on.

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

```
bazel build //bench:timed_runs
bazel-bin/bench/timed_runs --core 2 --repeats 5 --out results.csv \
    //third_party/rtlmeter/designs/Example:kind_hello_verilator_test
```

## License

Apache-2.0 (`LICENSE`). Third-party code keeps its own license, in its
directory under `third_party/`.
