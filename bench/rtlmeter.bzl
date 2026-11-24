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

_SIMULATORS = {
    "verilator": struct(
        args = ["--tool", "$(rootpath @verilator_prebuilt//:verilator)"],
        data = [
            "@verilator_prebuilt//:includes",
            "@verilator_prebuilt//:verilator",
        ],
        harness = "//third_party/rtlmeter:harness",
        # The prebuilt Verilator is a Linux x86-64 binary.
        compatible = [
            "@platforms//cpu:x86_64",
            "@platforms//os:linux",
        ],
        cpp = True,
    ),
    "iverilog": struct(
        args = [
            "--tool",
            "$(rootpath @iverilog//:iverilog)",
            "--tool2",
            "$(rootpath @iverilog//:vvp)",
            "--ivl-base",
            "$(rootpath @iverilog//:ivl_base)",
        ],
        data = [
            "@iverilog",
            "@iverilog//:ivl_base",
            "@iverilog//:vvp",
        ],
        # Icarus has no $root (see //bench:harness_noroot).
        harness = "//bench:harness_noroot",
        compatible = [],
        # No DPI-C: cases with C++ sources are not made for Icarus.
        cpp = False,
    ),
}

def _quote(s):
    # Bazel splits test args as a Bourne shell would.
    return "'" + s.replace("'", "'\\''") + "'"

def rtlmeter_design(name, cases, simulators = None, ci_max_cycles = CI_MAX_CYCLES):
    """One sh_test per configuration, test and simulator.

    Args:
      name: the design's name, for documentation only.
      cases: the design's CASES dict.
      simulators: which simulators to make tests for; all by default.
      ci_max_cycles: cases longer than this are "manual" and "long"; a tiny
        design can afford more cycles in CI.
    """
    sims = simulators or _SIMULATORS.keys()
    for config, c in cases.items():
        for test, t in c["tests"].items():
            for sim in sims:
                s = _SIMULATORS[sim]
                if c["cpp_srcs"] and not s.cpp:
                    continue
                args = ["--sim", sim] + s.args + ["--top", c["top"]]
                if t["expected_cycles"] != None:
                    args += ["--cycles", str(t["expected_cycles"])]
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
                sh_test(
                    name = "%s_%s_%s_test" % (config, test, sim),
                    size = "enormous" if long else "medium",
                    srcs = ["//bench:rtlmeter_case.sh"],
                    args = args,
                    data = depset(data).to_list(),
                    tags = ["rtlmeter", sim] + (["manual", "long"] if long else []),
                    target_compatible_with = s.compatible,
                )
