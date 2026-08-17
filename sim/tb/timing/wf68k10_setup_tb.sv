// Where does the Suska core sample its inputs?
//
// sim/tb/timing/rd68011_setup_tb.sv with a different processor in it, which is
// the whole point: the measurement is black-box, so it applies unchanged to a
// core whose bus cycle is two clocks rather than four and whose AS asserts on a
// falling edge. What comes out is that core's sampling instants in the same
// nanoseconds as ours, which is a comparison doc/suska-crosscheck.md had
// concluded was impossible.
//
// Runs under Vivado xsim only, the design under test being VHDL.

`timescale 1ns/1ps

module wf68k10_setup_tb #(
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

`include "rd68011_setup_body.svh"

  initial begin
    setup_main("wf68k10");
  end

endmodule
