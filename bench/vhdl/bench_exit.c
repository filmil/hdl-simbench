// Copyright 2026 hdl-simbench authors.
// SPDX-License-Identifier: Apache-2.0
//
// Tells the testbench that the program is done. NEORV32's crt0 runs the
// destructors after main returns, so this runs once CoreMark has printed
// its results. coremark_tb.vhd waits for GPIO output 0 and ends the
// simulation.

#include <neorv32.h>

__attribute__((destructor)) static void bench_exit(void) {
  neorv32_gpio_pin_set(0, 1);
}
