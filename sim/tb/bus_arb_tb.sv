// Bus arbitration: UM 5.2, 5.3 and figures 5-18 through 5-24.
//
// The delays are checked against the arbitration specifications, which the
// redrawn figures 10-7 through 10-11 lay out on a clock grid:
//
//   35   BR asserted    -> BG asserted            1.5 .. 3.5 clocks
//   36   BR negated     -> BG negated             1.5 .. 3.5 clocks
//   37   BGACK asserted -> BG negated             1.5 .. 3.5 clocks
//   57   BGACK negated  -> AS, DS, R/W driven     >= 1.5 clocks
//   57A  BGACK negated  -> FC, VMA driven         >= 1 clock
//
// Both arbitration protocols are covered: three-wire, where an alternate master
// asserts BGACK, and two-wire, where BGACK is tied negated and the handover is
// BR and BG alone.
//
// UM 5.2.1: "The processor [...] relinquishes the bus after it completes the
// current bus cycle" -- a request during a cycle does not cut it short.

`timescale 1ns/1ps

module bus_arb_tb;

  localparam int   SLAVE_WAITS = 0;
  localparam logic SLAVE_M6800 = 1'b0;

`include "rd68011_bus_harness.svh"

  int      t0;
  realtime t_mark, t_ev;
  int      as_falls;
  logic    arb_held;

  initial begin
    as_falls = 0;
    forever begin
      @(negedge as_n_o);
      as_falls = as_falls + 1;
    end
  end

  // Delay between two events, in clock periods.
  function automatic real clocks(input realtime from, input realtime to);
    clocks = (to - from) / CLK_PERIOD;
  endfunction

  task automatic expect_range(input string what, input real got,
                              input real lo, input real hi);
    if ((got < lo) || (got > hi)) begin
      $display("FAIL: %s is %0.2f clocks, expected %0.2f to %0.2f",
               what, got, lo, hi);
      errors = errors + 1;
    end else begin
      $display("  %s: %0.2f clocks  ok", what, got);
    end
  endtask

  task automatic expect_min(input string what, input real got, input real lo);
    if (got < lo) begin
      $display("FAIL: %s is %0.2f clocks, expected at least %0.2f",
               what, got, lo);
      errors = errors + 1;
    end else begin
      $display("  %s: %0.2f clocks  ok", what, got);
    end
  endtask

  initial begin
    harness_reset();
    slv.poke(23'h004000, 16'h2468);

    // ---- Three-wire arbitration with the bus idle (figure 5-20) ------------
    @(posedge clk);
    t_mark = $realtime;
    br_n_i = 1'b0;                       // BR asserted on a rising edge (UM 5.6)

    wait (bg_n_o === 1'b0);
    expect_range("35: BR asserted to BG asserted", clocks(t_mark, $realtime), 1.5, 3.5);

    // Figure 5-18 note 2: with the grant out and AS negated, the buses go to
    // high impedance.
    @(posedge clk);
    expect_val("buses released after BG", {28'd0, a_oe, as_oe, ds_oe, fc_oe}, 32'd0);

    @(posedge clk);
    t_mark    = $realtime;
    bgack_n_i = 1'b0;                    // alternate master takes the bus
    wait (bg_n_o === 1'b1);
    expect_range("37: BGACK asserted to BG negated", clocks(t_mark, $realtime), 1.5, 3.5);

    br_n_i = 1'b1;                       // "negated after BGACK is asserted"
    repeat (4) @(posedge clk);
    expect_val("buses still released while BGACK asserted",
               {28'd0, a_oe, as_oe, ds_oe, fc_oe}, 32'd0);

    // A request made while the bus belongs to someone else must wait.
    as_falls    = 0;
    req_pending = 1'b1;
    req_kind    = rd68011_pkg::CT_READ;
    req_fc      = rd68011_pkg::FC_SUPER_D;
    req_addr    = 23'h004000;
    req_uds     = 1'b1;
    req_lds     = 1'b1;
    repeat (6) @(posedge clk);
    expect_eq("no cycle while the bus is granted away", as_falls, 0);

    @(posedge clk);
    t_mark    = $realtime;
    bgack_n_i = 1'b1;                    // alternate master releases

    wait (fc_oe === 1'b1);
    expect_min("57A: BGACK negated to FC driven", clocks(t_mark, $realtime), 1.0);
    t_ev = $realtime;
    expect_min("57: BGACK negated to AS, DS, R/W driven",
               clocks(t_mark, t_ev), 1.5);
    if (!(as_oe && ds_oe && rw_oe)) begin
      $display("FAIL: control strobes not driven when FC is");
      errors = errors + 1;
    end

    bus_finish();
    expect_eq("the waiting cycle runs once the bus comes back", as_falls, 1);
    expect_val("data read after handover", {16'd0, req_rdata}, {16'd0, 16'h2468});

    repeat (4) @(posedge clk);

    // ---- Two-wire arbitration (figure 5-23): BGACK stays negated -----------
    @(posedge clk);
    t_mark = $realtime;
    br_n_i = 1'b0;
    wait (bg_n_o === 1'b0);
    expect_range("35: BR to BG, two-wire", clocks(t_mark, $realtime), 1.5, 3.5);
    @(posedge clk);
    expect_val("two-wire: buses released", {28'd0, a_oe, as_oe, ds_oe, fc_oe}, 32'd0);

    repeat (3) @(posedge clk);
    t_mark = $realtime;
    br_n_i = 1'b1;
    wait (bg_n_o === 1'b1);
    expect_range("36: BR negated to BG negated", clocks(t_mark, $realtime), 1.5, 3.5);

    // The control group comes straight back. The address bus does not: on an
    // idle bus it is in high impedance whether or not anyone was granted it
    // (UM 5.1.1 state 7, appendix B), so it waits for the next S1. That makes
    // the relinquish column of table 3-4 unobservable on the address bus here
    // -- bus_rw_tb is where a_oe's window is measured.
    wait (fc_oe === 1'b1);
    expect_val("two-wire: control group driven again",
               {29'd0, as_oe, ds_oe, fc_oe}, {29'd0, 3'b111});
    expect_val("two-wire: address bus still idle", {31'd0, a_oe}, 32'd0);

    repeat (4) @(posedge clk);

    // ---- A request during a cycle waits for the cycle to finish ------------
    // UM 5.2.1: the processor relinquishes the bus after it completes the
    // current bus cycle. Assert BR in S2, when AS has just gone out.
    as_falls = 0;
    bus_start(rd68011_pkg::CT_READ, rd68011_pkg::FC_SUPER_D,
              23'h004000, 1'b1, 1'b1, 16'h0000, t0);
    wait_state(t0, 2);
    br_n_i = 1'b0;
    bus_finish();
    expect_val("cycle completed despite BR", {29'd0, req_end},
               {29'd0, rd68011_pkg::CE_DTACK});
    expect_val("cycle data despite BR", {16'd0, req_rdata}, {16'd0, 16'h2468});
    expect_eq("exactly one cycle ran", as_falls, 1);
    // AS was asserted for its full window, not cut short.
    expect_window("AS during arbitration request", t0, OB_ASN, 1'b0, 2, 6);

    // ---- A request during a read-modify-write ------------------------------
    //
    // UM 5.1.3: a read-modify-write is indivisible, and AS stays asserted
    // across the whole of it rather than being negated between the halves.
    // Figure 5-18 note 2 releases the buses once the grant is out *and* AS is
    // negated, so the two rules together are what stops an alternate master
    // getting in between the read and the write of a TAS. That is the whole
    // point of the instruction, so it is worth a test rather than an argument.
    br_n_i    = 1'b1;
    bgack_n_i = 1'b1;
    repeat (4) @(posedge clk);
    slv.poke(23'h002020, 16'h1234);
    as_falls = 0;
    bus_start(rd68011_pkg::CT_RMW, rd68011_pkg::FC_SUPER_D,
              23'h002020, 1'b1, 1'b1, 16'h5678, t0);

    wait (as_n_o === 1'b0);              // the indivisible cycle is under way
    repeat (2) @(posedge clk);
    br_n_i = 1'b0;                       // and somebody wants the bus

    // The grant may go out -- UM 5.2.1 lets the processor answer at once --
    // but nothing may be released until the cycle is over.
    arb_held = 1'b1;
    fork
      begin : hold_watch
        while (as_n_o === 1'b0) begin
          @(posedge clk);
          if (!(a_oe && as_oe && ds_oe && fc_oe)) arb_held = 1'b0;
        end
      end
    join_none
    bus_finish();
    disable hold_watch;

    expect_val("RMW: the buses are held until the cycle ends",
               {31'd0, arb_held}, 32'd1);
    expect_val("RMW: the write half happened", {16'd0, slv.peek(23'h002020)},
               {16'd0, 16'h5678});
    expect_eq("RMW: one cycle, not two", as_falls, 1);
    // AS asserted from S2 to the falling edge entering S19: the read half, the
    // four modify states and the write half, with no gap for anyone else.
    expect_window("RMW AS held across the request", t0, OB_ASN, 1'b0, 2, 18);

    // Once it is over the grant takes effect as usual.
    wait (bg_n_o === 1'b0);
    @(posedge clk);
    expect_val("RMW: buses released after the cycle, not during",
               {28'd0, a_oe, as_oe, ds_oe, fc_oe}, 32'd0);
    br_n_i = 1'b1;
    repeat (6) @(posedge clk);

    br_n_i = 1'b1;
    repeat (6) @(posedge clk);

    harness_done("bus_arb_tb");
  end

endmodule
