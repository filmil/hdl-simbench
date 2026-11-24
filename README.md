# hdl-simbench

VHDL and SystemVerilog simulators compared on the same designs, under
comparable conditions, built with Bazel.

Work in progress; see https://github.com/filmil/hdl-simbench/issues/1.

## What is compared

- SystemVerilog: Verilator, Icarus Verilog, xezim.
- VHDL: GHDL, NVC.

Only open-source simulators are reported. Commercial simulator licenses
commonly forbid publishing benchmark results; Vivado's, for one, does
(its EULA, section 4(b)(iii)).

## Designs

- SystemVerilog: the cases of [RTLMeter](https://github.com/verilator/rtlmeter),
  Verilator's benchmark suite, in `third_party/rtlmeter` (Apache-2.0).
- VHDL: NEORV32 running CoreMark (to come).

## How a case is checked

RTLMeter's harness counts cycles of the design's main clock and writes the
count to `_rtlmeter_cycles.txt` when the simulation ends. A simulator passes
a case when that count equals the case's expected cycles and its output has
the expected lines. Only passing runs are timed.

```
bazel test //bench/...
```

## License

Apache-2.0 (`LICENSE`). Third-party code keeps its own license, in its
directory under `third_party/`.
