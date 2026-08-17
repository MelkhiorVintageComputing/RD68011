// AC-timing measurement, Suska WF68K10.
//
// This is sim/tb/timing/rd68011_ac_tb.sv with a different processor in it. The
// clock, the pads, the slave, the log format and the program are identical, so
// that the two logs are measurements of the same thing by the same instrument
// and the numbers in them can be put side by side.
//
// That is the part doc/suska-crosscheck.md could not do. Comparing the two on
// the S0-S7 ruler was impossible, because this core has no such ruler -- its
// bus cycle is two clocks where the manual's is four, and its AS asserts on a
// falling edge. But the AC specifications are stated in nanoseconds against
// clock edges rather than against bus states, so they *can* be applied to both,
// and tools/timing/ applies them without ever mentioning a bus state.
//
// Runs under Vivado xsim only: the design under test is VHDL, and mixed-language
// elaboration is what makes one SystemVerilog testbench able to drive it.
//
// Nothing here was written from reading the Suska sources. The pin mapping is
// in sim/tb/timing/wf68k10_pins.vhd, from its entity declaration and the
// manual; the four polarity hypotheses it makes are settled by observing this
// run, which is what the rule permits.

`timescale 1ns/1ps

module wf68k10_ac_tb #(
    parameter real P_A_VALID    = 0.001,
    parameter real P_A_HIZ      = 0.001,
    parameter real P_FC_VALID   = 0.001,
    parameter real P_AS_ASSERT  = 0.001,
    parameter real P_AS_NEGATE  = 0.001,
    parameter real P_DS_ASSERT  = 0.001,
    parameter real P_DS_NEGATE  = 0.001,
    parameter real P_RW_LOW     = 0.001,
    parameter real P_RW_HIGH    = 0.001,
    parameter real P_DOUT_VALID = 0.001,
    parameter real P_DOUT_HIZ   = 0.001,
    parameter real P_VMA_ASSERT = 0.001,
    parameter real P_VMA_NEGATE = 0.001,
    parameter real P_BG_ASSERT  = 0.001,
    parameter real P_BG_NEGATE  = 0.001,
    parameter real P_E          = 0.001
);

`include "rd68011_timing_harness.svh"

  // Not MC68010 pins; brought out so RMC can mark a read-modify-write, which
  // makes lining the two traces up much easier. Nothing asserts against them.
  wire rmc_n_x, dben_n_x;

  wf68k10_pins dut (
      .clk (clk), .rst_n (rst_n),
      .a_o (a_o), .a_oe (a_oe),
      .d_i (d_i), .d_o (d_o), .d_oe (d_oe),
      .as_n_o (as_n_o), .as_oe (as_oe),
      .rw_o (rw_o), .rw_oe (rw_oe),
      .uds_n_o (uds_n_o), .lds_n_o (lds_n_o), .ds_oe (ds_oe),
      .dtack_n_i (dtack_n_i),
      .br_n_i (br_n_i), .bg_n_o (bg_n_o), .bgack_n_i (bgack_n_i),
      .ipl_n_i (ipl_n_i),
      .berr_n_i (berr_n_i),
      .reset_n_i (reset_n_i),
      .reset_n_o (reset_n_o), .reset_n_oe (reset_n_oe),
      .halt_n_i (halt_n_i),
      .halt_n_o (halt_n_o), .halt_n_oe (halt_n_oe),
      .e_o (e_o), .vpa_n_i (vpa_n_i),
      .vma_n_o (vma_n_o), .vma_oe (vma_oe),
      .fc_o (fc_o), .fc_oe (fc_oe),
      .rmc_n_x (rmc_n_x), .dben_n_x (dben_n_x)
  );

  string image;

  initial begin
    timing_config();
    if (!$value$plusargs("image=%s", image)) image = "bus_probe.hex";

    u_slave.clear();
    $readmemh(image, u_slave.mem);

    // The same answers our own run gets, so that any difference in the logs is
    // a difference between the processors and not between their memories.
    u_slave.dtack_assert_ns = 20.0;
    u_slave.data_valid_ns   = 25.0;
    u_slave.data_invalid_ns =  5.0;
    u_slave.data_hiz_ns     = 10.0;

    timing_reset();
    timing_run("wf68k10", "see -generic_top options");

    $display("PASS: wf68k10_ac_tb");
    $finish;
  end

endmodule
