# Copyright 2026 hdl-simbench authors.
# SPDX-License-Identifier: Apache-2.0
"""CoreMark images for NEORV32, built with the pinned xPack RISC-V GCC."""

# NEORV32's CoreMark port (sw/example/coremark/Makefile) and
# sw/common/common.mk, flag for flag, except:
#   - -g is left out; it does not change the code.
#   - UART0_SIM_MODE: the UART prints each character on the simulator's
#     output in one cycle, instead of shifting it out at 19200 baud.
#   - ITERATIONS: set per image (see //bench/vhdl:core_portme_h).
_CC_FLAGS = [
    "-march=rv32imc_zicsr_zifencei",
    "-mabi=ilp32",
    "-O3",
    "-Wall",
    "-Wextra",
    "-ffunction-sections",
    "-fdata-sections",
    "-mno-fdiv",
    "-mstrict-align",
    "-mbranch-cost=10",
    "-ffp-contract=off",
]

_LD_FLAGS = [
    "-Wl,--defsym,__neorv32_rom_size=64k",
    "-Wl,--defsym,__neorv32_rom_base=0x00000000",
    "-Wl,--defsym,__neorv32_ram_size=64k",
    "-Wl,--defsym,__neorv32_ram_base=0x80000000",
    "-Wl,--defsym,__neorv32_heap_size=32k",
    "-nostartfiles",
    "-Wl,--gc-sections",
]

_LD_LIBS = ["-lm", "-lc", "-lgcc"]

_DEFINES = [
    "-DMULTITHREAD=1",
    "-DUART0_SIM_MODE",
]

_LINUX_X86_64 = [
    "@platforms//os:linux",
    "@platforms//cpu:x86_64",
]

def coremark_image(name, iterations):
    """CoreMark for NEORV32, as the VHDL package neorv32_imem_image.

    Makes:
      <name>_elf          the linked program
      <name>_bin          its raw memory image
      <name>_imem_image   neorv32_imem_image.vhd, the instruction memory's
                          initial contents

    Args:
      name: the prefix of the targets.
      iterations: CoreMark's iteration count.
    """
    defines = _DEFINES + ["-DITERATIONS=%d" % iterations]

    # CoreMark prints its compiler flags; as in common.mk, they are the
    # CC_FLAGS.
    flags_str = "-DCC_FLAGS_STR='\"%s\"'" % " ".join(_CC_FLAGS)
    native.genrule(
        name = name + "_elf",
        srcs = [
            ":bench_exit.c",
            ":core_portme_c",
            ":core_portme_h",
            "//third_party/coremark:hdrs",
            "//third_party/coremark:srcs",
            "//third_party/neorv32:sw/common/crt0.S",
            "//third_party/neorv32:sw/common/neorv32.ld",
            "//third_party/neorv32:sw_lib_hdrs",
            "//third_party/neorv32:sw_lib_srcs",
        ],
        outs = [name + ".elf"],
        # Only the patched core_portme.h is an input, beside the copy of
        # core_portme.c (//bench/vhdl:core_portme_c), so every include of it
        # finds that one.
        cmd = " ".join([
            "$(execpath @riscv_gcc//:bin/riscv-none-elf-gcc)",
        ] + _CC_FLAGS + defines + [
            flags_str,
            "-I$$(dirname $(execpath :core_portme_h))",
            "-Ithird_party/coremark",
            "-Ithird_party/neorv32/sw/lib/include",
        ] + _LD_FLAGS + [
            "-T $(execpath //third_party/neorv32:sw/common/neorv32.ld)",
            "$(execpath //third_party/neorv32:sw/common/crt0.S)",
            "$(execpaths //third_party/coremark:srcs)",
            "$(execpath :core_portme_c)",
            "$(execpaths //third_party/neorv32:sw_lib_srcs)",
            "$(execpath :bench_exit.c)",
        ] + _LD_LIBS + [
            "-o $@",
        ]),
        tools = [
            "@riscv_gcc//:all",
            "@riscv_gcc//:bin/riscv-none-elf-gcc",
        ],
        # The xPack compiler runs on Linux x86-64; what it makes is RISC-V.
        # The target constraint keeps a wildcard build elsewhere from failing
        # to find an execution platform; the cases only run there anyway.
        exec_compatible_with = _LINUX_X86_64,
        target_compatible_with = _LINUX_X86_64,
    )

    native.genrule(
        name = name + "_bin",
        srcs = [":" + name + "_elf"],
        outs = [name + ".bin"],
        cmd = "$(execpath @riscv_gcc//:bin/riscv-none-elf-objcopy) -O binary $< $@",
        tools = [
            "@riscv_gcc//:all",
            "@riscv_gcc//:bin/riscv-none-elf-objcopy",
        ],
        # The xPack compiler runs on Linux x86-64; what it makes is RISC-V.
        # The target constraint keeps a wildcard build elsewhere from failing
        # to find an execution platform; the cases only run there anyway.
        exec_compatible_with = _LINUX_X86_64,
        target_compatible_with = _LINUX_X86_64,
    )

    native.genrule(
        name = name + "_imem_image",
        srcs = [":" + name + "_bin"],
        outs = [name + "/neorv32_imem_image.vhd"],
        cmd = "$(execpath //third_party/neorv32:image_gen) -t vhd -i $< -o $@",
        tools = ["//third_party/neorv32:image_gen"],
    )
