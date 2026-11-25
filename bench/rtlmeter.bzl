"""Bazel tests for the cases of one RTLMeter design.

rtlmeter_design() reads a design's CASES (cases.bzl, written by
//tools:rtlmeter_import) and makes one sh_test per configuration, test and
simulator, each running bench/rtlmeter_case.sh. Paths in CASES are relative
to the design's directory, which is the package that calls the macro.
"""

load("@rules_shell//shell:sh_test.bzl", "sh_test")

# Cases longer than this many cycles are for the timed runs, not for CI:
# they are tagged "manual" (so "bazel test //..." skips them) and "long".
CI_MAX_CYCLES = 100000

# Each long case also gets a smoke test that CI runs: the same compile and
# files, stopped by RTLMeter's own +max_cycles after the simulator's
# smoke_cycles (_SIMULATORS below). As in RTLMeter, a run stopped that way
# skips the cycle check and the post hook; it must print the harness's
# "+max_cycles reached" line instead.

# The hermetic C++ compiler (MODULE.bazel: LLVM with a Debian sysroot), for
# what the simulators compile while a case runs: Verilator's model, and
# DPI-C sources. The same compiler on every machine, eph2 included, which
# has none of its own.
_CXX_ARGS = [
    "--clangxx",
    "$(rootpath @llvm_toolchain_llvm//:bin/clang++)",
    "--sysroot-file",
    "$(rootpath @sysroot_linux_x86_64//:usr/include/stdio.h)",
    "--readelf",
    "$(rootpath @llvm_toolchain_llvm//:bin/llvm-readelf)",
]

_CXX_DATA = [
    "@llvm_toolchain_llvm//:bin/clang++",
    "@llvm_toolchain_llvm//:clang",
    "@llvm_toolchain_llvm//:include",
    "@llvm_toolchain_llvm//:ld",
    "@llvm_toolchain_llvm//:lib",
    "@sysroot_linux_x86_64//:sysroot",
    "@sysroot_linux_x86_64//:usr/include/stdio.h",
    "@llvm_toolchain_llvm//:bin/llvm-readelf",
]

_SIMULATORS = {
    "verilator": struct(
        args = [
            "--tool",
            "$(rootpath @verilator//:verilator)",
            "--verilator-root-file",
            "$(rootpath @verilator//:include/verilated_std.sv)",
        ] + _CXX_ARGS,
        data = [
            "@verilator//:include/verilated_std.sv",
            "@verilator//:verilator",
            "@verilator//:verilator_includes",
        ] + _CXX_DATA,
        harness = "//third_party/rtlmeter:harness",
        # The hermetic toolchain's sysroot is Linux x86-64.
        compatible = [
            "@platforms//cpu:x86_64",
            "@platforms//os:linux",
        ],
        cpp = True,
        test_size = "medium",
        smoke_cycles = 20000,
    ),
    "xezim": struct(
        # xezim 0.11.7.bcr.2 links LLVM's libunwind statically, so, like the
        # other simulators, it needs nothing from the host but glibc.
        args = ["--tool", "$(rootpath @xezim//:xezim)"] + _CXX_ARGS,
        data = ["@xezim//:xezim"] + _CXX_DATA,
        # The original harness: xezim follows IEEE 1800, $root included.
        harness = "//third_party/rtlmeter:harness",
        compatible = [
            "@platforms//cpu:x86_64",
            "@platforms//os:linux",
        ],
        # Compiles DPI-C sources itself when the design runs, with $CXX/$CC
        # (the hermetic clang that rtlmeter_case.sh sets up).
        cpp = True,
        # xezim runs VeeR-EL2 at a few hundred cycles a second in CI: its
        # hiperf hello took 171 s with the compile, and 5000 cycles over
        # 5 minutes. Its tests get the next size (15 minutes), and its smoke
        # tests fewer cycles.
        test_size = "large",
        smoke_cycles = 5000,
    ),
    "iverilog": struct(
        args = [
            "--tool",
            "$(rootpath @iverilog//:iverilog)",
            "--tool2",
            "$(rootpath @iverilog//:vvp)",
            "--ivl-base",
            "$(rootpath @iverilog//:ivl_base)",
            "--readelf",
            "$(rootpath @llvm_toolchain_llvm//:bin/llvm-readelf)",
        ],
        data = [
            "@iverilog",
            "@iverilog//:ivl_base",
            "@iverilog//:vvp",
            "@llvm_toolchain_llvm//:bin/llvm-readelf",
        ],
        # Icarus has no $root (see //bench:harness_noroot).
        harness = "//bench:harness_noroot",
        compatible = [],
        # No DPI-C: cases with C++ sources are not made for Icarus.
        cpp = False,
        test_size = "medium",
        smoke_cycles = 20000,
    ),
}

def _quote(s):
    # Bazel splits test args as a Bourne shell would.
    return "'" + s.replace("'", "'\\''") + "'"

def rtlmeter_design(name, cases, simulators = None, ci_max_cycles = CI_MAX_CYCLES, unsupported = {}, cycle_tolerance = 0):
    """One sh_test per configuration, test and simulator.

    Args:
      name: the design's name, for documentation only.
      cases: the design's CASES dict.
      simulators: which simulators to make tests for; all by default.
      ci_max_cycles: cases longer than this are "manual" and "long"; a tiny
        design can afford more cycles in CI.
      cycle_tolerance: 1 to also accept one cycle fewer than expected, for a
        design that calls $finish on the main clock's edge (see
        rtlmeter_case.sh); 0, an exact check, otherwise.
      unsupported: {simulator: (error text, reason)} for simulators that
        cannot run the design. No cases are made for them; instead one test,
        <simulator>_unsupported_test, checks that the first case still fails
        with that error text, so that a simulator gaining support is noticed.
    """
    sims = simulators or _SIMULATORS.keys()
    first = None
    for config, c in cases.items():
        for test, t in c["tests"].items():
            for sim in sims:
                s = _SIMULATORS[sim]
                if c["cpp_srcs"] and not s.cpp:
                    continue
                skip = sim in unsupported
                args = ["--sim", sim] + s.args + ["--top", c["top"]]
                if t["expected_cycles"] != None:
                    args += ["--cycles", str(t["expected_cycles"])]
                    if cycle_tolerance:
                        args += ["--cycle-tolerance", str(cycle_tolerance)]
                for k, v in c["defines"].items():
                    args += ["--define", _quote("%s=%s" % (k, v))]
                for k, v in c["params"].items():
                    args += ["--param", _quote("%s=%s" % (k, v))]
                if sim == "verilator":
                    for a in c["verilator_args"]:
                        args += ["--verilator-arg", _quote(a)]
                for a in t["args"]:
                    args += ["--plusarg", _quote(a)]
                args += ["--include", "$(rootpath //third_party/rtlmeter:harness_include)"]
                for f in c["includes"]:
                    args += ["--include", "$(rootpath %s)" % f]
                for f in t["files"]:
                    args += ["--file", "$(rootpath %s)" % f]
                for f in c["cpp_srcs"]:
                    args += ["--cpp-src", "$(rootpath %s)" % f]
                data = (
                    s.data +
                    [s.harness, "//third_party/rtlmeter:harness_include"] +
                    c["srcs"] + c["includes"] + t["files"] + c["cpp_srcs"]
                )
                if t["post_hook"]:
                    args += ["--post-hook", "$(rootpath %s)" % t["post_hook"]]
                    data.append(t["post_hook"])
                args += ["--"] + ["$(rootpath %s)" % f for f in c["srcs"]]
                args.append("$(rootpath %s)" % s.harness)
                long = t["expected_cycles"] == None or t["expected_cycles"] > ci_max_cycles
                data = depset(data).to_list()
                if skip:
                    if first == None or sim not in first:
                        first = (first or {})
                        first[sim] = struct(args = args, data = data)
                    continue
                sh_test(
                    name = "%s_%s_%s_test" % (config, test, sim),
                    size = "enormous" if long else s.test_size,
                    srcs = ["//bench:rtlmeter_case.sh"],
                    args = args,
                    data = data,
                    tags = ["rtlmeter", sim] + (["manual", "long"] if long else []),
                    target_compatible_with = s.compatible,
                )
                if long:
                    sh_test(
                        name = "%s_%s_%s_smoke_test" % (config, test, sim),
                        size = s.test_size,
                        srcs = ["//bench:rtlmeter_case.sh"],
                        args = [
                            "--smoke",
                            "--plusarg",
                            "+max_cycles=%d" % s.smoke_cycles,
                            "--expect",
                            _quote("RTLMeter: +max_cycles reached, exiting"),
                        ] + args,
                        data = data,
                        tags = ["rtlmeter", sim, "smoke"],
                        target_compatible_with = s.compatible,
                    )

    for sim, (text, reason) in unsupported.items():
        if sim not in (first or {}):
            continue
        sh_test(
            name = "%s_unsupported_test" % sim,
            size = "medium",
            srcs = ["//bench:expect_unsupported.sh"],
            args = [_quote(text), "$(rootpath //bench:rtlmeter_case.sh)"] + first[sim].args,
            data = first[sim].data + ["//bench:rtlmeter_case.sh"],
            tags = ["rtlmeter", sim, "unsupported"],
            target_compatible_with = _SIMULATORS[sim].compatible,
        )
