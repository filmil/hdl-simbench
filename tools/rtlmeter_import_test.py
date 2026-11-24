# Copyright 2026 hdl-simbench authors.
# SPDX-License-Identifier: Apache-2.0
"""Unit tests of rtlmeter_import's resolution rules, on small descriptors.

The rules are RTLMeter's (src/rtlmeter/descriptors.py there): lists
concatenate in order, maps merge with later entries winning, scalars take
the last value; a test gathers the design's execute.common, the design's
test, the configuration's execute.common and the configuration's test.
"""

import unittest

import rtlmeter_import as ri


def _desc(**over):
    d = {
        "compile": {
            "verilogSourceFiles": ["a.v"],
            "topModule": "top",
            "mainClock": "top.clk",
            "verilogDefines": {"A": 1, "B": 2},
        },
        "execute": {
            "common": {"args": ["+c1"], "postHook": "post.bash"},
            "tests": {"t1": {"args": ["+t1"], "expectedCycles": 10}},
        },
    }
    d.update(over)
    return d


class ResolveTest(unittest.TestCase):
    def test_default_configuration(self):
        out = ri.resolve(_desc())
        self.assertEqual(list(out), ["default"])
        c = out["default"]
        self.assertEqual(c["top"], "top")
        self.assertEqual(c["srcs"], ["a.v"])
        self.assertEqual(c["defines"], {"A": "1", "B": "2", "__RTLMETER_MAIN_CLOCK": "top.clk"})
        self.assertEqual(c["tests"]["t1"]["args"], ["+c1", "+t1"])
        self.assertEqual(c["tests"]["t1"]["expected_cycles"], 10)
        self.assertEqual(c["tests"]["t1"]["post_hook"], "post.bash")

    def test_configuration_extends_compile(self):
        d = _desc(
            configurations={
                "x": {
                    "compile": {
                        "verilogSourceFiles": ["b.v"],
                        "verilogDefines": {"B": 3, "C": 4},
                        "topModule": "other",
                    }
                }
            }
        )
        c = ri.resolve(d)["x"]
        self.assertEqual(c["srcs"], ["a.v", "b.v"])  # lists concatenate
        self.assertEqual(c["defines"]["B"], "3")  # maps: later wins
        self.assertEqual(c["defines"]["C"], "4")
        self.assertEqual(c["top"], "other")  # scalars: last value

    def test_test_gathering_order(self):
        d = _desc(
            configurations={
                "x": {
                    "execute": {
                        "common": {"args": ["+c2"]},
                        "tests": {
                            "t1": {"args": ["+t1x"], "expectedCycles": 20},
                            "t2": {"files": ["f.hex"]},
                        },
                    }
                }
            }
        )
        tests = ri.resolve(d)["x"]["tests"]
        self.assertEqual(tests["t1"]["args"], ["+c1", "+t1", "+c2", "+t1x"])
        self.assertEqual(tests["t1"]["expected_cycles"], 20)
        # A test only in the configuration still gets the design's common.
        self.assertEqual(tests["t2"]["args"], ["+c1", "+c2"])
        self.assertEqual(tests["t2"]["files"], ["f.hex"])
        self.assertIsNone(tests["t2"]["expected_cycles"])
        self.assertEqual(list(tests), ["t1", "t2"])

    def test_verilator_args_split(self):
        d = _desc()
        d["compile"]["verilatorArgs"] = ["-Gwidth=4", "--autoflush", "-Wno-WIDTH", "-Gname=a=b"]
        c = ri.resolve(d)["default"]
        self.assertEqual(c["params"], {"width": "4", "name": "a=b"})
        self.assertEqual(c["verilator_args"], ["--autoflush", "-Wno-WIDTH"])

    def test_missing_top_or_clock(self):
        d = _desc()
        del d["compile"]["mainClock"]
        with self.assertRaises(ValueError):
            ri.resolve(d)

    def test_empty_sections(self):
        d = {"compile": {"topModule": "t", "mainClock": "t.c"}, "execute": None}
        c = ri.resolve(d)["default"]
        self.assertEqual(c["tests"], {})
        self.assertEqual(c["srcs"], [])


class StarlarkTest(unittest.TestCase):
    def test_escapes_and_types(self):
        text = ri._starlark({"a": 'x"y\\z', "n": None, "i": 3, "l": [], "d": {}})
        ns = {}
        exec("V = " + text, ns)  # Starlark and Python agree on these forms
        self.assertEqual(ns["V"], {"a": 'x"y\\z', "n": None, "i": 3, "l": [], "d": {}})


if __name__ == "__main__":
    unittest.main()
