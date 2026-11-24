-- Copyright 2026 hdl-simbench authors.
-- SPDX-License-Identifier: Apache-2.0
--
-- NEORV32 running CoreMark, for timing VHDL simulators.
--
-- A single NEORV32 core at a simulated 100 MHz, rv32imc with Zicntr, boots
-- the program in its instruction memory (the package neorv32_imem_image,
-- generated from CoreMark by //bench/vhdl). The program prints through
-- UART0's simulation mode, one line at a time on the simulator's output.
-- When CoreMark returns, a destructor in bench_exit.c sets GPIO output 0,
-- and this testbench ends the simulation with std.env.finish. So every
-- simulator runs the same instructions and stops at the same simulated
-- time.

library ieee;
use ieee.std_logic_1164.all;

library neorv32;

use std.env.all;

entity coremark_tb is
  generic (
    -- Simulated time after which the run fails: far longer than CoreMark
    -- needs, so that a hung CPU stops the test instead of the timer.
    TIMEOUT : time := 2 sec
  );
end entity;

architecture sim of coremark_tb is
  signal clk  : std_ulogic := '0';
  signal rstn : std_ulogic := '0';
  signal gpio : std_ulogic_vector(31 downto 0);
begin
  clk  <= not clk after 5 ns; -- 100 MHz
  rstn <= '1' after 100 ns;

  dut: entity neorv32.neorv32_top
    generic map (
      CLOCK_FREQUENCY   => 100_000_000,
      BOOT_MODE_SELECT  => 2, -- boot from the pre-initialized IMEM
      RISCV_ISA_C       => true,
      RISCV_ISA_M       => true,
      RISCV_ISA_Zicntr  => true,
      CPU_FAST_MUL_EN   => true,
      CPU_FAST_SHIFT_EN => true,
      IMEM_EN           => true,
      IMEM_SIZE         => 64*1024,
      DMEM_EN           => true,
      DMEM_SIZE         => 64*1024,
      IO_GPIO_NUM       => 1,
      IO_CLINT_EN       => true,
      IO_UART0_EN       => true
    )
    port map (
      clk_i  => clk,
      rstn_i => rstn,
      gpio_o => gpio
    );

  done: process
  begin
    wait until gpio(0) = '1';
    report "coremark_tb: program done at " & time'image(now);
    finish;
  end process;

  timeout_check: process
  begin
    wait for TIMEOUT;
    report "coremark_tb: timeout, the program did not finish" severity failure;
    wait;
  end process;
end architecture;
