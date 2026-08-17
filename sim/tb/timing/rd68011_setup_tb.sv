// Where does the processor actually sample its inputs?
//
// The class-3 specifications -- 27 data setup, 28 DTACK hold, 29 data hold, 47
// asynchronous input setup, 48* the MC68010's late bus error -- are demands on
// the memory system. `make timing` measures them and does not judge them,
// because what the slave happened to do says nothing about what the processor
// requires.
//
// This finds out what it requires, by moving one input a little later on each
// run and asking when the behaviour changes. The observable is deliberately
// black-box: the same program, run from reset each time, and the transaction
// list it produces. An input latched too late gives a wrong value and the
// addresses diverge; an acknowledge that misses its edge costs a wait state and
// the cycle count rises. Either way the trial differs from the golden one.
//
// Nothing here looks inside the processor, which is the point -- the identical
// measurement runs against the Suska core in sim/tb/timing/wf68k10_setup_tb.sv,
// and gives its sampling instants in the same nanoseconds as ours.
//
// WHAT IS ASSERTED, AND WHAT IS ONLY REPORTED
//
// The tempting test is "present DTACK a hair inside specification 47's limit
// and check it is refused". That is not what the specification says. It obliges
// the *system* to present the input early enough; it does not oblige the
// processor to reject one that arrives late, and a real part very likely
// accepts it. A test written that way would encode this implementation's flop
// into the suite and fail the day somebody added a synchroniser -- a false
// alarm on a correct change.
//
// So what is measured is the threshold, and what is asserted is one-directional:
// this design's real requirement is no worse than the specification allows. The
// threshold itself is reported, because it is the interesting number and the
// one that is comparable between two processors.
//
// Limits live in tools/timing/, as everywhere else here. This prints MEASURE
// lines; tools/timing/setup_report.py judges them against the CSV.

`timescale 1ns/1ps

module rd68011_setup_tb #(
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

`include "rd68011_setup_body.svh"

  initial begin
    setup_main("rd68011");
  end

endmodule
