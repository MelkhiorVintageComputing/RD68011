// AC-timing measurement, RD68011.
//
// Runs the probe program and writes the event log tools/timing/ analyses. The
// Suska half is sim/tb/timing/wf68k10_ac_tb.sv, which is this file with a
// different processor in it and nothing else changed -- which is the point.
//
//   iverilog -g2012 -I sim/tb -I sim/tb/timing -o build/timing/ac.vvp \
//            -s rd68011_ac_tb $(RTL) sim/models/*.sv sim/tb/timing/rd68011_ac_tb.sv
//   vvp build/timing/ac.vvp +image=bus_probe.hex +period=100 +cycles=40
//
// The sixteen pad delays are parameters rather than plusargs because a delay in
// a continuous assignment has to be a constant. tools/timing/corners.py turns a
// named corner into the -P options that set them.

`timescale 1ns/1ps

module rd68011_ac_tb #(
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

  rd68011_top dut (
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
      .fc_o (fc_o), .fc_oe (fc_oe)
  );

  string image;

  initial begin
    timing_config();
    if (!$value$plusargs("image=%s", image)) image = "bus_probe.hex";

    u_slave.clear();
    $readmemh(image, u_slave.mem);

    // The answers a well-behaved slave gives, in nanoseconds from the strobes.
    // These are the *defaults* for a measurement run: comfortably inside every
    // limit, so that what the log shows is the processor's own edge assignment
    // and not the slave's. Walking them to the limits is what
    // sim/tb/timing/rd68011_setup_tb.sv does.
    u_slave.dtack_assert_ns = 20.0;
    u_slave.data_valid_ns   = 25.0;
    u_slave.data_invalid_ns =  5.0;
    u_slave.data_hiz_ns     = 10.0;

    timing_reset();
    timing_run("rd68011", "see -P options");

    $display("PASS: rd68011_ac_tb");
    $finish;
  end

endmodule
