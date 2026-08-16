// Bus error, retry and halt: UM 5.4 and table 5-1.
//
// Table 5-1 enumerates six ways a cycle can terminate, of which cases 4 and 6
// are MC68010-only -- the late bus error, "asserted within one clock cycle
// after the assertion of data transfer acknowledge" (UM 5.4.1). The MC68000
// treats those as a normal termination; this part must not.
//
//   1  DTACK alone                     normal termination
//   2  DTACK with HALT                 terminate, then halt until HALT negated
//   3  BERR without DTACK              terminate in S9, bus error exception
//   4  BERR one clock after DTACK      bus error exception       (MC68010)
//   5  BERR + HALT without DTACK       terminate and rerun the cycle
//   6  BERR + HALT one clock after     terminate and rerun       (MC68010)
//
// UM 5.4.2 also carves out the read-modify-write: "the processor does not retry
// a read-modify-write cycle. When a bus error occurs during a read-modify-write
// operation, a bus error operation is performed whether or not HALT is
// asserted."

`timescale 1ns/1ps

module bus_error_tb;

  localparam int   SLAVE_WAITS = 0;
  localparam logic SLAVE_M6800 = 1'b0;

`include "rd68011_bus_harness.svh"

  // An address the slave does not answer, so BERR is the only termination.
  localparam logic [23:1] DEAD = 23'h400000;
  localparam logic [23:1] LIVE = 23'h003000;

  int t0, t1;
  int as_falls;

  // Count the AS assertions, so a rerun is visible as a second one.
  initial begin
    as_falls = 0;
    forever begin
      @(negedge as_n_o);
      as_falls = as_falls + 1;
    end
  end

  initial begin
    harness_reset();
    slv.poke(LIVE, 16'h4321);

    // ---- Case 3: BERR in lieu of DTACK -------------------------------------
    // "the current bus cycle is terminated in S9 for a read cycle" (UM 5.4.1),
    // one clock later than a normal termination.
    bus_start(rd68011_pkg::CT_READ, rd68011_pkg::FC_SUPER_D,
              DEAD, 1'b1, 1'b1, 16'h0000, t0);
    wait_state(t0, 4);
    tb_berr_n = 1'b0;
    bus_finish();
    t1 = etick;
    tb_berr_n = 1'b1;
    expect_val("case 3 end code", {29'd0, req_end}, {29'd0, rd68011_pkg::CE_BERR});
    // AS still negates entering S7; the extra clock is S8 and S9.
    expect_window("case 3 AS", t0, OB_ASN, 1'b0, 2, 6);
    expect_eq("case 3 cycle length, in states", t1 - t0 - 1, 10);

    repeat (4) @(posedge clk);

    // ---- Case 1 again, to prove nothing is stuck ---------------------------
    bus_cycle(rd68011_pkg::CT_READ, rd68011_pkg::FC_SUPER_D,
              LIVE, 1'b1, 1'b1, 16'h0000, t0);
    expect_val("after BERR, normal read", {16'd0, req_rdata}, {16'd0, 16'h4321});
    expect_val("after BERR, end code", {29'd0, req_end}, {29'd0, rd68011_pkg::CE_DTACK});

    // ---- Case 4: the MC68010 late bus error --------------------------------
    // DTACK is recognised at the falling edge ending S4; BERR arrives one clock
    // later, which is the falling edge ending S6. An MC68000 would call this a
    // normal termination and continue.
    bus_start(rd68011_pkg::CT_READ, rd68011_pkg::FC_SUPER_D,
              LIVE, 1'b1, 1'b1, 16'h0000, t0);
    wait_state(t0, 6);
    tb_berr_n = 1'b0;
    bus_finish();
    t1 = etick;
    tb_berr_n = 1'b1;
    expect_val("case 4 end code", {29'd0, req_end}, {29'd0, rd68011_pkg::CE_BERR});
    // Figure 5-26 shows the transfer itself completing normally, in eight
    // states, with the stacking beginning after it.
    expect_eq("case 4 cycle length, in states", t1 - t0 - 1, 8);

    repeat (4) @(posedge clk);

    // ---- Case 5: BERR + HALT, retry ----------------------------------------
    // "The processor terminates the bus cycle, then puts the address and data
    // lines in the high-impedance state. The processor remains in this state
    // until HALT is negated. Then the processor retries the preceding cycle
    // using the same function codes, address, and data."
    as_falls = 0;
    slv.poke(LIVE, 16'hFEED);
    bus_start(rd68011_pkg::CT_READ, rd68011_pkg::FC_SUPER_D,
              LIVE, 1'b1, 1'b1, 16'h0000, t0);
    wait_state(t0, 4);
    tb_berr_n = 1'b0;
    tb_halt_n = 1'b0;
    // The retry is invisible to the sequencer: no acknowledge for the attempt
    // that failed. Hold HALT for a while and check nothing is acknowledged.
    repeat (6) @(posedge clk);
    expect_val("case 5 no ack while halted", {31'd0, req_ack}, 32'd0);
    expect_val("case 5 address bus released", {31'd0, a_oe}, 32'd0);
    tb_berr_n = 1'b1;
    @(posedge clk);
    tb_halt_n = 1'b1;          // BERR negated at least one clock before HALT
    bus_finish();
    expect_eq("case 5 AS asserted twice", as_falls, 2);
    expect_val("case 5 rerun data", {16'd0, req_rdata}, {16'd0, 16'hFEED});
    expect_val("case 5 rerun end code", {29'd0, req_end}, {29'd0, rd68011_pkg::CE_DTACK});

    repeat (4) @(posedge clk);

    // ---- Case 6: the MC68010 late retry ------------------------------------
    as_falls = 0;
    bus_start(rd68011_pkg::CT_READ, rd68011_pkg::FC_SUPER_D,
              LIVE, 1'b1, 1'b1, 16'h0000, t0);
    wait_state(t0, 6);
    tb_berr_n = 1'b0;
    tb_halt_n = 1'b0;
    repeat (4) @(posedge clk);
    tb_berr_n = 1'b1;
    @(posedge clk);
    tb_halt_n = 1'b1;
    bus_finish();
    expect_eq("case 6 AS asserted twice", as_falls, 2);
    expect_val("case 6 rerun data", {16'd0, req_rdata}, {16'd0, 16'hFEED});

    repeat (4) @(posedge clk);

    // ---- Case 2: HALT with DTACK -------------------------------------------
    // "Normal cycle terminate and halt. Continue when HALT negated."
    bus_start(rd68011_pkg::CT_READ, rd68011_pkg::FC_SUPER_D,
              LIVE, 1'b1, 1'b1, 16'h0000, t0);
    wait_state(t0, 4);
    tb_halt_n = 1'b0;
    bus_finish();
    expect_val("case 2 end code", {29'd0, req_end}, {29'd0, rd68011_pkg::CE_DTACK});
    expect_val("case 2 data", {16'd0, req_rdata}, {16'd0, 16'hFEED});
    // Halted: the address bus is in high impedance and no new cycle starts.
    repeat (4) @(posedge clk);
    expect_val("case 2 address bus released while halted", {31'd0, a_oe}, 32'd0);
    as_falls = 0;
    req_pending = 1'b1;
    req_addr    = LIVE;
    repeat (6) @(posedge clk);
    expect_eq("case 2 no cycle while halted", as_falls, 0);
    tb_halt_n = 1'b1;
    bus_finish();
    expect_eq("case 2 cycle runs once HALT is negated", as_falls, 1);

    repeat (4) @(posedge clk);

    // ---- A read-modify-write is never retried (UM 5.4.2) -------------------
    as_falls = 0;
    bus_start(rd68011_pkg::CT_RMW, rd68011_pkg::FC_SUPER_D,
              LIVE, 1'b1, 1'b0, 16'h00FF, t0);
    wait_state(t0, 4);
    tb_berr_n = 1'b0;
    tb_halt_n = 1'b0;
    bus_finish();
    tb_berr_n = 1'b1;
    tb_halt_n = 1'b1;
    expect_val("RMW BERR+HALT is a bus error, not a retry",
               {29'd0, req_end}, {29'd0, rd68011_pkg::CE_BERR});
    expect_eq("RMW not rerun", as_falls, 1);

    harness_done("bus_error_tb");
  end

endmodule
