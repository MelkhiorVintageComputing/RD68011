// Does Vivado's simulator bind SystemVerilog to VHDL for these two designs?
//
// This is the gate the AC-timing work is built on. Everything else assumes one
// SystemVerilog testbench can drive our core and the Suska core through the
// same pin bundle, which needs three things to be true at once: xvlog accepts
// our RTL, xvhdl accepts the Suska sources at VHDL-2008, and xelab binds an
// SV parent to a VHDL child. This checks all three and nothing else -- it
// asserts no timing and no behaviour, only that both DUTs elaborate, come out
// of reset and put an address on the bus.
//
// It is deliberately cheap. If it fails, the plan changes shape before any
// effort is spent on a testbench that could not have run.

`timescale 1ns/1ps

module xsim_smoke_tb;

  localparam real CLK_PERIOD = 125.0;

  logic clk = 1'b0;
  logic rst_n;
  logic reset_n_i, halt_n_i;

  always #(CLK_PERIOD / 2.0) clk = ~clk;

  // -- our core ---------------------------------------------------------------
  logic [23:1] o_a_o;      logic o_a_oe;
  logic [15:0] o_d_o;      logic o_d_oe;
  logic        o_as_n_o, o_as_oe, o_rw_o, o_rw_oe;
  logic        o_uds_n_o, o_lds_n_o, o_ds_oe;
  logic        o_bg_n_o, o_reset_n_o, o_reset_n_oe;
  logic        o_halt_n_o, o_halt_n_oe, o_e_o, o_vma_n_o, o_vma_oe;
  logic  [2:0] o_fc_o;     logic o_fc_oe;

  rd68011_top u_ours (
      .clk (clk), .rst_n (rst_n),
      .a_o (o_a_o), .a_oe (o_a_oe),
      .d_i (16'h4e71), .d_o (o_d_o), .d_oe (o_d_oe),
      .as_n_o (o_as_n_o), .as_oe (o_as_oe),
      .rw_o (o_rw_o), .rw_oe (o_rw_oe),
      .uds_n_o (o_uds_n_o), .lds_n_o (o_lds_n_o), .ds_oe (o_ds_oe),
      .dtack_n_i (1'b0),
      .br_n_i (1'b1), .bg_n_o (o_bg_n_o), .bgack_n_i (1'b1),
      .ipl_n_i (3'b111),
      .berr_n_i (1'b1),
      .reset_n_i (reset_n_i),
      .reset_n_o (o_reset_n_o), .reset_n_oe (o_reset_n_oe),
      .halt_n_i (halt_n_i),
      .halt_n_o (o_halt_n_o), .halt_n_oe (o_halt_n_oe),
      .loop_inv_n_i (1'b1),
      .e_o (o_e_o), .vpa_n_i (1'b1),
      .vma_n_o (o_vma_n_o), .vma_oe (o_vma_oe),
      .fc_o (o_fc_o), .fc_oe (o_fc_oe)
  );

  // -- the Suska core, behind the same bundle ---------------------------------
  logic [23:1] s_a_o;      logic s_a_oe;
  logic [15:0] s_d_o;      logic s_d_oe;
  logic        s_as_n_o, s_as_oe, s_rw_o, s_rw_oe;
  logic        s_uds_n_o, s_lds_n_o, s_ds_oe;
  logic        s_bg_n_o, s_reset_n_o, s_reset_n_oe;
  logic        s_halt_n_o, s_halt_n_oe, s_e_o, s_vma_n_o, s_vma_oe;
  logic  [2:0] s_fc_o;     logic s_fc_oe;
  logic        s_rmc_n_x, s_dben_n_x;

  wf68k10_pins u_suska (
      .clk (clk), .rst_n (rst_n),
      .a_o (s_a_o), .a_oe (s_a_oe),
      .d_i (16'h4e71), .d_o (s_d_o), .d_oe (s_d_oe),
      .as_n_o (s_as_n_o), .as_oe (s_as_oe),
      .rw_o (s_rw_o), .rw_oe (s_rw_oe),
      .uds_n_o (s_uds_n_o), .lds_n_o (s_lds_n_o), .ds_oe (s_ds_oe),
      .dtack_n_i (1'b0),
      .br_n_i (1'b1), .bg_n_o (s_bg_n_o), .bgack_n_i (1'b1),
      .ipl_n_i (3'b111),
      .berr_n_i (1'b1),
      .reset_n_i (reset_n_i),
      .reset_n_o (s_reset_n_o), .reset_n_oe (s_reset_n_oe),
      .halt_n_i (halt_n_i),
      .halt_n_o (s_halt_n_o), .halt_n_oe (s_halt_n_oe),
      .e_o (s_e_o), .vpa_n_i (1'b1),
      .vma_n_o (s_vma_n_o), .vma_oe (s_vma_oe),
      .fc_o (s_fc_o), .fc_oe (s_fc_oe),
      .rmc_n_x (s_rmc_n_x), .dben_n_x (s_dben_n_x)
  );

  int ours_cycles, suska_cycles;

  always @(negedge o_as_n_o) ours_cycles  = ours_cycles + 1;
  always @(negedge s_as_n_o) suska_cycles = suska_cycles + 1;

  initial begin
    ours_cycles  = 0;
    suska_cycles = 0;

    // Both held in reset the way UM 5.5 asks. Suska needs twenty clocks rather
    // than the manual's ten -- measured, and recorded in doc/suska-crosscheck.md
    // -- so both get twenty and neither is disadvantaged.
    rst_n     = 1'b0;
    reset_n_i = 1'b0;
    halt_n_i  = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (20) @(posedge clk);
    reset_n_i = 1'b1;
    halt_n_i  = 1'b1;

    repeat (200) @(posedge clk);

    $display("SMOKE ours=%0d cycles, suska=%0d cycles", ours_cycles, suska_cycles);
    if (ours_cycles == 0)  $display("FAIL: our core started no bus cycle");
    if (suska_cycles == 0) $display("FAIL: the Suska core started no bus cycle");
    if (ours_cycles > 0 && suska_cycles > 0)
      $display("PASS: xsim_smoke_tb");
    $finish;
  end

endmodule
