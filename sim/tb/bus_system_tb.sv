// System control: the RESET instruction's output pulse, the double bus fault
// HALT output, the RESET input's effect on the buses, and input synchronisation.
//
// UM 5.5: "The RESET instruction causes the processor to assert RESET for 124
// clock periods to reset the external devices of the system. The internal state
// of the processor is not affected."
//
// UM 5.4.4: "If another bus error occurs during exception processing [...] the
// processor halts and asserts HALT. This is called a double bus fault. Only an
// external reset operation can restart a processor halted due to a double bus
// fault."
//
// UM table 3-4: RESET and HALT are open drain, and the address and data buses --
// alone among the outputs -- go to high impedance while RESET is asserted.
//
// UM 5.3, figure 5-17: an asynchronous input "is sampled on the falling edge of
// the clock and is valid internally after the next falling edge."

`timescale 1ns/1ps

module bus_system_tb;

  localparam int   SLAVE_WAITS = 0;
  localparam logic SLAVE_M6800 = 1'b0;

`include "rd68011_bus_harness.svh"

  realtime t_rise, t_fall;
  real     pulse_clocks;
  int      i;

  initial begin
    harness_reset();

    // ---- The RESET instruction: 124 clock periods --------------------------
    expect_val("RESET not driven at rest", {31'd0, reset_n_oe}, 32'd0);

    @(negedge clk);
    reset_req = 1'b1;
    // reset_busy is set by this rising edge. Take the timestamp here rather
    // than waiting on the level afterwards, which would land half a clock late.
    @(posedge clk);
    t_rise = $realtime;
    @(negedge clk);
    reset_req = 1'b0;
    expect_val("RESET driven", {31'd0, reset_n_oe}, {31'd0, 1'b1});
    expect_val("RESET output level is low", {31'd0, reset_n_o}, 32'd0);
    expect_val("reset_busy while driving", {31'd0, reset_busy}, {31'd0, 1'b1});

    wait (reset_n_oe === 1'b0);
    t_fall = $realtime;
    pulse_clocks = (t_fall - t_rise) / CLK_PERIOD;
    if (pulse_clocks != 124.0) begin
      $display("FAIL: RESET pulse is %0.2f clocks, expected 124", pulse_clocks);
      errors = errors + 1;
    end else begin
      $display("  RESET instruction pulse: %0.0f clocks  ok", pulse_clocks);
    end
    expect_val("reset_busy clears", {31'd0, reset_busy}, 32'd0);

    // The pin is open drain: the core only ever pulls it low, so the output
    // value is a constant and the enable does the work.
    expect_val("RESET output stays 0", {31'd0, reset_n_o}, 32'd0);

    repeat (4) @(posedge clk);

    // ---- Double bus fault drives HALT out ----------------------------------
    expect_val("HALT not driven at rest", {31'd0, halt_n_oe}, 32'd0);
    dbf = 1'b1;
    @(posedge clk);
    expect_val("HALT driven on double bus fault", {31'd0, halt_n_oe}, {31'd0, 1'b1});
    expect_val("HALT output level is low", {31'd0, halt_n_o}, 32'd0);
    dbf = 1'b0;
    repeat (2) @(posedge clk);

    // ---- The RESET input releases the address and data buses ---------------
    // An idle address bus is in high impedance anyway (UM 5.1.1 state 7,
    // appendix B), so "released" has to be measured where the address would
    // otherwise be driven: S1 of a bus cycle.
    slv.poke(23'h006100, 16'h1234);
    bus_cycle(rd68011_pkg::CT_READ, rd68011_pkg::FC_SUPER_D,
              23'h006100, 1'b1, 1'b1, 16'h0000, i);
    expect_bit("address driven in S1 before RESET", i, 1, OB_AOE, 1'b1);

    reset_n_i = 1'b0;
    // Two falling edges of synchronisation, then the enable follows.
    repeat (4) @(posedge clk);
    expect_val("RESET seen internally", {31'd0, reset_sync_n}, 32'd0);
    bus_cycle(rd68011_pkg::CT_READ, rd68011_pkg::FC_SUPER_D,
              23'h006100, 1'b1, 1'b1, 16'h0000, i);
    expect_bit("address bus released while RESET asserted", i, 1, OB_AOE, 1'b0);
    // The control strobes are not released: table 3-4's Hi-Z-on-RESET column is
    // "Yes" for the address and data buses only.
    expect_val("AS still driven while RESET asserted", {31'd0, as_oe}, {31'd0, 1'b1});

    reset_n_i = 1'b1;
    repeat (4) @(posedge clk);
    bus_cycle(rd68011_pkg::CT_READ, rd68011_pkg::FC_SUPER_D,
              23'h006100, 1'b1, 1'b1, 16'h0000, i);
    expect_bit("address driven again", i, 1, OB_AOE, 1'b1);

    // ---- Input synchronisation ---------------------------------------------
    // IPL is presented to the sequencer synchronised, still active low.
    expect_val("IPL idle", {29'd0, ipl_sync_n}, {29'd0, 3'b111});
    @(posedge clk);
    ipl_n_i = 3'b010;                        // level 5 requested
    wait (ipl_sync_n === 3'b010);
    expect_val("IPL synchronised", {29'd0, ipl_sync_n}, {29'd0, 3'b010});
    ipl_n_i = 3'b111;
    wait (ipl_sync_n === 3'b111);

    // HALT reaches the sequencer the same way.
    tb_halt_n = 1'b0;
    wait (halt_sync_n === 1'b0);
    tb_halt_n = 1'b1;
    wait (halt_sync_n === 1'b1);

    // ---- The bus still works afterwards ------------------------------------
    slv.poke(23'h006000, 16'h0F0F);
    bus_cycle(rd68011_pkg::CT_READ, rd68011_pkg::FC_SUPER_D,
              23'h006000, 1'b1, 1'b1, 16'h0000, i);
    expect_val("read after system events", {16'd0, req_rdata}, {16'd0, 16'h0F0F});

    harness_done("bus_system_tb");
  end

endmodule
