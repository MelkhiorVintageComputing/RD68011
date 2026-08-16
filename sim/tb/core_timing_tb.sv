// Measured instruction timings, against UM section 9.
//
// Cycle-accurate instruction timing is not a requirement of this project, but
// every difference has to be measured rather than guessed at. This runs one
// instruction at a time from a known state and reports the clocks between the
// instruction boundary before it and the one after, which is how the reference
// counts.
//
// Every row carries two numbers: what this design takes, and what section 9
// gives the original. **The test fails if the first one moves.** That is the
// point of it -- doc/timing-divergences.md is written from these numbers, so a
// change in any of them is either a documentation update or a bug, and either
// way it should not pass silently. Reporting a divergence and passing anyway is
// what let four rows quietly start measuring an exception instead of the
// instruction.
//
// A row whose section 9 number is zero has no entry in the manual to compare
// against, and is measured only so that it cannot drift.

`timescale 1ns/1ps

module core_timing_tb;

`include "rd68011_core_harness.svh"

  localparam logic [31:0] SSP0 = 32'h0000_3000;
  localparam logic [31:0] PC0  = 32'h0000_1000;

  int i;
  int measured;
  int nins_want;

  // Run until `nins_want` instruction boundaries have gone by, and report the
  // clocks between the last two.
  task automatic measure(input string what, input int ours, input int sec9);
    int n;
    begin
      core_start();
      n = 0;
      while ((nins < nins_want) && (n < 4000)) begin
        @(posedge clk);
        n = n + 1;
      end
      if (nins < nins_want) begin
        $display("FAIL: %s never finished", what);
        errors  = errors + 1;
      end else begin
        measured = ins_clk[nins_want - 1] - ins_clk[nins_want - 2];
        if (measured != ours) begin
          $display("FAIL: %-24s %3d clocks; this design took %0d before",
                   what, measured, ours);
          errors = errors + 1;
        end else if (sec9 == 0) begin
          $display("  %-26s %3d clocks  (no section 9 entry)", what, measured);
        end else if (measured == sec9) begin
          $display("  %-26s %3d clocks  (section 9: %0d)  ok",
                   what, measured, sec9);
        end else begin
          $display("  %-26s %3d clocks  (section 9: %0d)  diverges by %0d",
                   what, measured, sec9, measured - sec9);
        end
      end
    end
  endtask

  // Load one instruction of up to three words at PC0 and reset around it, so
  // every measurement starts from the same state. `pre` is a one-word
  // instruction run first, for the cases that need a register set up; the
  // measurement then covers the second instruction.
  //
  // The stack gets a return address pointing at the NOPs after the
  // instruction, so anything that pops one lands somewhere defined. Measuring
  // an instruction that runs off into undefined memory measures the exception
  // it eventually takes, which is not what any of these rows mean.
  task automatic prog(input logic [15:0] pre,
                      input logic [15:0] w0, input logic [15:0] w1,
                      input logic [15:0] w2);
    logic [22:0] at;
    begin
      core_reset();
      poke_l(23'h000000, SSP0);
      poke_l(23'h000002, PC0);
      at        = PC0[23:1];
      nins_want = 2;
      if (pre !== 16'h0000) begin
        poke_w(at, pre);
        at        = at + 23'd1;
        nins_want = 3;
      end
      poke_w(at + 23'd0, w0);
      poke_w(at + 23'd1, w1);
      poke_w(at + 23'd2, w2);
      poke_w(at + 23'd3, 16'h4E71);   // NOP
      poke_w(at + 23'd4, 16'h4E71);
      poke_w(at + 23'd5, 16'h4E71);
      poke_l(SSP0[23:1], {8'd0, at + 23'd3, 1'b0});
      nins = 0;
    end
  endtask

  // A loop mode iteration: set up the manual's figure A-1 loop with `body` as
  // the instruction being looped, let it get going, and measure one whole pass
  // -- the looped instruction and the DBcc together, which is what section 9's
  // "loop continued" tables count.
  task automatic measure_loop(input string what, input logic [15:0] body,
                              input int sec9);
    int n, t0, t1;
    begin
      core_reset();
      poke_l(23'h000000, SSP0);
      poke_l(23'h000002, PC0);
      poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, 32'h0000_4000);
      poke_w(23'h000803, 16'h227C);  poke_l(23'h000804, 32'h0000_5000);
      poke_w(23'h000806, 16'h303C);  poke_w(23'h000807, 16'd40);
      poke_w(23'h000808, body);
      poke_w(23'h000809, 16'h51C8);        // DBF D0, so only the count ends it
      poke_w(23'h00080A, 16'hFFFC);
      poke_w(23'h00080B, 16'h4E71);
      for (n = 0; n < 24; n = n + 1)
        poke_w(23'h002000 + 23'(n), 16'(16'h1100 + 16'(n)));
      nins = 0;
      core_start();
      n = 0;
      while (!dut.u_seq.loop_active && (n < 4000)) begin
        @(posedge clk);
        n = n + 1;
      end
      if (!dut.u_seq.loop_active) begin
        $display("FAIL: %s never entered loop mode", what);
        errors = errors + 1;
      end else begin
        // Two boundaries is one pass: the looped instruction and the DBcc.
        n = nins;  while (nins < n + 2) @(posedge clk);  t0 = clkcount;
        n = nins;  while (nins < n + 2) @(posedge clk);  t1 = clkcount;
        if ((t1 - t0) != sec9) begin
          $display("FAIL: %-24s %3d clocks, section 9 says %0d",
                   what, t1 - t0, sec9);
          errors = errors + 1;
        end else begin
          $display("  %-26s %3d clocks  (section 9: %0d)  ok",
                   what, t1 - t0, sec9);
        end
      end
    end
  endtask

  initial begin
    errors = 0;

    $display("== the P5 instructions, measured ==");

    // Four instructions whose section 9 entry is not in doubt, so that a
    // measurement that disagrees below is the instruction and not the harness.
    prog(16'h0, 16'h4E71, 16'h0, 16'h0);  measure("NOP",          4,  4);
    prog(16'h0, 16'h7001, 16'h0, 16'h0);  measure("MOVEQ #1,D0",  4,  4);
    prog(16'h0, 16'hD041, 16'h0, 16'h0);  measure("ADD.W D1,D0",  4,  4);
    prog(16'h0, 16'h4E75, 16'h0, 16'h0);  measure("RTS",         17, 16);

    // -- Multiply. Section 9 gives 42 for MULS and 40 for MULU, both maxima
    //    on the MC68010; ours is two microwords and is data-independent.
    prog(16'h0, 16'hC0C1, 16'h0, 16'h0);  measure("MULU.W D1,D0", 5, 40);
    prog(16'h0, 16'hC1C1, 16'h0, 16'h0);  measure("MULS.W D1,D0", 5, 42);

    // -- Divide. Section 9 gives 108 and 122, both data-dependent maxima; the
    //    sequential divider here takes the same time whatever the operands,
    //    so the number below is the whole story rather than a worst case.
    //    MOVEQ #1,D1 first, or the divisor is zero and this measures the trap.
    prog(16'h7201, 16'h80C1, 16'h0, 16'h0);  measure("DIVU.W D1,D0", 45, 108);
    prog(16'h7201, 16'h81C1, 16'h0, 16'h0);  measure("DIVS.W D1,D0", 45, 122);

    // -- The BCD group, one microword each like any register operation.
    prog(16'h0, 16'hC101, 16'h0, 16'h0);  measure("ABCD D1,D0", 4, 6);
    prog(16'h0, 16'h8101, 16'h0, 16'h0);  measure("SBCD D1,D0", 4, 6);
    prog(16'h0, 16'h4800, 16'h0, 16'h0);  measure("NBCD D0",    4, 6);

    // -- Extended add and subtract.
    prog(16'h0, 16'hD101, 16'h0, 16'h0);  measure("ADDX.B D1,D0", 4, 4);
    prog(16'h0, 16'hD181, 16'h0, 16'h0);  measure("ADDX.L D1,D0", 4, 8);
    prog(16'h0, 16'h9101, 16'h0, 16'h0);  measure("SUBX.B D1,D0", 4, 4);

    // -- EXG, and CMPM which walks two post-incremented operands.
    prog(16'h0, 16'hC141, 16'h0, 16'h0);  measure("EXG D0,D1", 6, 6);
    prog(16'h0, 16'hB308, 16'h0, 16'h0);
    measure("CMPM.B (A0)+,(A1)+", 12, 12);

    // -- MOVEP: 16 and 24, and no internal cycles at all.
    prog(16'h0, 16'h0108, 16'h0004, 16'h0);
    measure("MOVEP.W (4,A0),D0", 16, 16);
    prog(16'h0, 16'h0148, 16'h0004, 16'h0);
    measure("MOVEP.L (4,A0),D0", 24, 24);
    prog(16'h0, 16'h0188, 16'h0004, 16'h0);
    measure("MOVEP.W D0,(4,A0)", 16, 16);
    prog(16'h0, 16'h01C8, 16'h0004, 16'h0);
    measure("MOVEP.L D0,(4,A0)", 24, 24);

    // -- MOVEM. Section 9's 8+4n and 12+4n, with n = 1 here (D0 alone) and
    //    then n = 3, which is what shows the per-register cost is only the
    //    bus cycles.
    prog(16'h0, 16'h4890, 16'h0001, 16'h0);
    measure("MOVEM.W D0,(A0)", 12, 12);
    prog(16'h0, 16'h4890, 16'h0007, 16'h0);
    measure("MOVEM.W D0-D2,(A0)", 20, 20);
    prog(16'h0, 16'h48D0, 16'h0007, 16'h0);
    measure("MOVEM.L D0-D2,(A0)", 32, 32);
    prog(16'h0, 16'h4C90, 16'h0001, 16'h0);
    measure("MOVEM.W (A0),D0", 16, 16);
    prog(16'h0, 16'h4C90, 16'h0007, 16'h0);
    measure("MOVEM.W (A0),D0-D2", 24, 24);
    prog(16'h0, 16'h4CD0, 16'h0007, 16'h0);
    measure("MOVEM.L (A0),D0-D2", 36, 36);
    // Through A7, because A0 is zero out of reset and -(A0) would walk off
    // the bottom of memory.
    prog(16'h0, 16'h48A7, 16'hE000, 16'h0);
    measure("MOVEM.W D0-D2,-(A7)", 20, 20);

    $display("== the MC68010's own instructions ==");
    // MOVEC is 10 one way and 12 the other; MOVES 18 through (An).
    prog(16'h0, 16'h4E7A, 16'h0801, 16'h0);  measure("MOVEC VBR,D0",    12, 10);
    prog(16'h0, 16'h4E7B, 16'h0801, 16'h0);  measure("MOVEC D0,VBR",    12, 12);
    prog(16'h0, 16'h0E10, 16'h1000, 16'h0);  measure("MOVES.B (A0),D1", 15, 18);
    prog(16'h0, 16'h0E10, 16'h1800, 16'h0);  measure("MOVES.B D1,(A0)", 15, 18);
    prog(16'h0, 16'h0E90, 16'h1000, 16'h0);  measure("MOVES.L (A0),D1", 19, 22);
    prog(16'h0, 16'h0E90, 16'h1800, 16'h0);  measure("MOVES.L D1,(A0)", 19, 22);
    prog(16'h0, 16'h4E74, 16'h0000, 16'h0);  measure("RTD #0",          18, 16);

    $display("== loop mode ==");
    measure_loop("MOVE.W (An)+,(An)+ looped", 16'h32D8, 14);
    measure_loop("CMPM.W (An)+,(An)+ looped", 16'hB349, 14);
    measure_loop("TST.W (An)+ looped",        16'h4A58, 10);
    measure_loop("CLR.W (An)+ looped",        16'h4258, 10);

    if (errors == 0) $display("PASS: core_timing_tb");
    else             $display("FAIL: core_timing_tb, %0d errors", errors);
    $finish;
  end

endmodule
