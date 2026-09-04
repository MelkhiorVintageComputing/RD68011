// The processor's output enables against a master that comes and goes.
//
// A report from a machine with DMA in it: very occasionally -- of the order of
// one bus cycle in a hundred thousand -- the alternate master reads the wrong
// data. Wrong data on somebody else's read has one cause on this side of the
// pins, which is the processor driving the bus while it does not own it, so
// that is what this asserts and it asserts it continuously.
//
// Reasoning will not find a one-in-a-hundred-thousand event and neither will a
// directed test: the arbitration handshake is already covered edge by edge in
// sim/tb/bus_arb_tb.sv and cycle by cycle in sim/tb/core_arb_tb.sv, and both
// pass. What is left is the alignment nobody thought to write down, so this
// randomises the alignment instead -- when the request arrives, how long the
// grant is held, how long until the next one -- and runs a few hundred episodes
// against a processor doing real work.
//
// The program is a loop mode block move, chosen because it is the densest
// stream of *write* cycles this core can produce: loop mode fetches nothing, so
// almost every cycle is an operand, and `doe_q` -- the flip-flop that puts the
// processor on the data bus -- is set and cleared once per iteration. If there
// is an alignment where it survives into a grant, this is the program most
// likely to find it.
//
// The alternate master drives a recognisable value while it holds the bus, so a
// processor that re-drives early collides with something rather than with high
// impedance.

`timescale 1ns/1ps

module core_dma_stress_tb;

`include "rd68011_core_harness.svh"

  localparam logic [31:0] SSP0 = 32'h0000_3000;
  localparam logic [31:0] PC0  = 32'h0000_1000;
  localparam logic [31:0] DONE = 32'h0000_1016;
  localparam logic [31:0] SRC  = 32'h0000_4000;
  localparam logic [31:0] DST  = 32'h0000_5000;
  localparam int          NW   = 1200;

  localparam logic [15:0] MASTER_D = 16'hA5A5;
  logic master_drive;
  assign dbus = master_drive ? MASTER_D : 16'bz;

  int  j;    // the main process only
  int  jm;   // the alternate master's own, so the two never share one
  int  episodes;
  int  clocks;
  int  rel_max;   // longest handover seen, in half clocks
  int  viol_oe;      // the processor driving anything while the master owns it
  int  viol_d;       // ... the data bus specifically, which is the reported one
  int  cyc_during;   // cycles the processor started while the master owns it
  logic running;
  int   rounds;   // +rounds=N to hunt harder; the default is a regression
  int   r;

  // The assertion window is where the master is actually *driving*, not merely
  // where it holds BGACK. Specification 57 gives the processor a bounded time
  // to get off the bus after BGACK, and figure 5-18 has the master wait for it;
  // asserting from the BGACK edge instead would flag that legitimate handover
  // delay as a violation, which it is not. The delay is measured separately
  // below so that "bounded" is a number rather than an assumption.
  always @(clk) begin
    if (rst_n && master_drive) begin
      if (d_oe === 1'b1) viol_d = viol_d + 1;
      if ((a_oe === 1'b1) || (as_oe === 1'b1) || (ds_oe === 1'b1) ||
          (fc_oe === 1'b1)) viol_oe = viol_oe + 1;
    end
  end

  always @(negedge as_n_o) if (rst_n && master_drive) cyc_during = cyc_during + 1;

  // The alternate master: request, wait for the grant, wait for the buses,
  // acknowledge, hold, release. Every wait a different length.
  initial begin
    br_n_i       = 1'b1;
    bgack_n_i    = 1'b1;
    master_drive = 1'b0;
    episodes     = 0;
    wait (running === 1'b1);
    // `while (running)` rather than `forever` with a break: iverilog does not
    // support break.
    while (running) begin
      repeat ($urandom_range(2, 34)) @(posedge clk);
      br_n_i = 1'b0;
      jm = 0;
      while ((bg_n_o !== 1'b0) && (jm < 400)) begin
        @(posedge clk);
        jm = jm + 1;
      end
      jm = 0;
      while ((a_oe !== 1'b0) && (jm < 400)) begin
        @(posedge clk);
        jm = jm + 1;
      end
      // Half the episodes acknowledge on a falling edge, half on a rising one,
      // so the handover is not always the same phase.
      if ($urandom_range(0, 1)) @(negedge clk);
      bgack_n_i    = 1'b0;
      br_n_i       = 1'b1;
      // A well-behaved master waits for the buses before driving them, and how
      // long that takes is specification 57. Counted, so the longest handover
      // seen is reported rather than assumed.
      jm = 0;
      while (((a_oe === 1'b1) || (as_oe === 1'b1) || (ds_oe === 1'b1) ||
              (fc_oe === 1'b1) || (d_oe === 1'b1)) && (jm < 40)) begin
        @(clk);
        jm = jm + 1;
      end
      if (jm > rel_max) rel_max = jm;
      master_drive = 1'b1;
      repeat ($urandom_range(2, 26)) @(posedge clk);
      if ($urandom_range(0, 1)) @(negedge clk);
      master_drive = 1'b0;
      bgack_n_i    = 1'b1;
      episodes     = episodes + 1;
    end
  end

  task automatic one_round();
    begin
      core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    for (j = 0; j < NW + 4; j = j + 1) begin
      poke_w(SRC[23:1] + 23'(j), 16'(16'h1000 + 16'(j)));
      poke_w(DST[23:1] + 23'(j), 16'hFFFF);
    end
    poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, SRC);
    poke_w(23'h000803, 16'h227C);  poke_l(23'h000804, DST);
    poke_w(23'h000806, 16'h303C);  poke_w(23'h000807, 16'(NW - 1));
    poke_w(23'h000808, 16'h32D8);            // 1010: MOVE.W (A0)+,(A1)+
    poke_w(23'h000809, 16'h51C8);            // 1012: DBRA D0,1010
    poke_w(23'h00080A, 16'hFFFC);
    poke_w(23'h00080B, 16'h60FE);            // 1016: branch to self

      core_start();
      running = 1'b1;
      j = 0;
      while ((dut.u_seq.ir_pc !== DONE) && (j < 400000)) begin
        @(posedge clk);
        j = j + 1;
      end
      running = 1'b0;
      clocks  = clocks + j;
      if (dut.u_seq.ir_pc !== DONE) begin
        $display("FAIL: the block move never finished (%0d clocks)", j);
        errors = errors + 1;
      end

      // And the work is right, which is the other half: a master that comes and
      // goes must cost the processor time and nothing else.
      for (j = 0; j < NW; j = j + 1) begin
        if (mem.peek(DST[23:1] + 23'(j)) !== 16'(16'h1000 + 16'(j))) begin
          $display("FAIL: DMA stress: word %0d is %04h, expected %04h", j,
                   mem.peek(DST[23:1] + 23'(j)), 16'(16'h1000 + 16'(j)));
          errors = errors + 1;
        end
      end
      if (mem.peek(DST[23:1] + 23'(NW)) !== 16'hFFFF) begin
        $display("FAIL: DMA stress: it wrote past the end");
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    errors     = 0;
    viol_oe    = 0;
    viol_d     = 0;
    cyc_during = 0;
    clocks     = 0;
    rel_max    = 0;
    running    = 1'b0;
    if (!$value$plusargs("rounds=%d", rounds)) rounds = 3;

    for (r = 0; r < rounds; r = r + 1) one_round();

    $display("  DMA stress: %0d arbitration episodes over %0d clocks in %0d rounds; \
longest release after BGACK %0d half clocks", episodes, clocks, rounds,
             rel_max);
    if (episodes < 400) begin
      $display("FAIL: only %0d episodes, too few to say anything", episodes);
      errors = errors + 1;
    end
    expect_int("DMA stress: the processor never drove the data bus", viol_d, 0);
    expect_int("DMA stress: nor any other bus", viol_oe, 0);
    expect_int("DMA stress: nor started a cycle", cyc_during, 0);

    core_done("core_dma_stress_tb");
  end

endmodule
