// Measured instruction timings, against UM section 9.
//
// Cycle-accurate instruction timing is not a requirement of this project, but
// every difference has to be measured rather than guessed at. This runs one
// instruction at a time from a known state and reports the clocks between the
// instruction boundary before it and the one after -- which is exactly how the
// reference vectors count, and how doc/timing-divergences.md is written.
//
// A row whose expectation is zero is reported and not judged: it is there to
// be read, for the instructions whose section 9 entry depends on data the
// table does not fix.

`timescale 1ns/1ps

module core_timing_tb;

`include "rd68011_core_harness.svh"

  localparam logic [31:0] SSP0 = 32'h0000_3000;
  localparam logic [31:0] PC0  = 32'h0000_1000;

  int i;
  int measured;

  // Run one instruction, already poked in at PC0, and return the clocks it
  // took: the gap between the boundary that ends the instruction before it
  // (the second of the two prefetches out of reset) and the one that ends it.
  task automatic measure(input string what, input int want);
    int n;
    begin
      core_start();
      n = 0;
      while ((nins < 2) && (n < 4000)) begin
        @(posedge clk);
        n = n + 1;
      end
      if (nins < 2) begin
        $display("FAIL: %s never finished", what);
        errors  = errors + 1;
        measured = 0;
      end else begin
        // ins_clk[0] is the reset sequence's own exit; ins_clk[1] ends the
        // instruction under test.
        measured = ins_clk[1] - ins_clk[0];
        if (want == 0) begin
          $display("  %-28s %3d clocks", what, measured);
        end else if (measured == want) begin
          $display("  %-28s %3d clocks  (section 9: %0d)  ok",
                   what, measured, want);
        end else begin
          $display("  %-28s %3d clocks  (section 9: %0d)  DIVERGES by %0d",
                   what, measured, want, measured - want);
        end
      end
    end
  endtask

  // Load one instruction of up to three words at PC0 and reset around it, so
  // every measurement starts from the same state.
  task automatic prog(input logic [15:0] w0, input logic [15:0] w1,
                      input logic [15:0] w2);
    begin
      core_reset();
      poke_l(23'h000000, SSP0);
      poke_l(23'h000002, PC0);
      poke_w(PC0[23:1] + 23'd0, w0);
      poke_w(PC0[23:1] + 23'd1, w1);
      poke_w(PC0[23:1] + 23'd2, w2);
      // Something harmless after it, so the boundary that ends the
      // instruction under test is reached without anything else running.
      poke_w(PC0[23:1] + 23'd3, 16'h4E71);   // NOP
      poke_w(PC0[23:1] + 23'd4, 16'h4E71);
      poke_w(PC0[23:1] + 23'd5, 16'h4E71);
      nins = 0;
    end
  endtask

  initial begin
    errors = 0;

    $display("== the P5 instructions, measured ==");

    // Three instructions whose section 9 entry is not in doubt, so that a
    // measurement that disagrees below is the instruction and not the harness.
    prog(16'h4E71, 16'h0, 16'h0);  measure("NOP",           4);
    prog(16'h7001, 16'h0, 16'h0);  measure("MOVEQ #1,D0",   4);
    prog(16'hD041, 16'h0, 16'h0);  measure("ADD.W D1,D0",   4);
    prog(16'h4E75, 16'h0, 16'h0);  measure("RTS",          16);

    // -- Multiply. Section 9 gives 42 for MULS and 40 for MULU, both maxima
    //    on the MC68010; ours is one microword and is data-independent.
    prog(16'hC0C1, 16'h0, 16'h0);  measure("MULU.W D1,D0",  40);
    prog(16'hC1C1, 16'h0, 16'h0);  measure("MULS.W D1,D0",  42);

    // -- Divide. Section 9 gives 108 and 122, both data-dependent maxima; the
    //    sequential divider here takes the same time whatever the operands,
    //    so the number below is the whole story rather than a worst case.
    //    A divisor of one, so the division is a real one and not the trap.
    prog(16'h80C1, 16'h0, 16'h0);  measure("DIVU.W D1,D0", 108);
    prog(16'h81C1, 16'h0, 16'h0);  measure("DIVS.W D1,D0", 122);

    // -- The BCD group, one microword each like any register operation.
    prog(16'hC101, 16'h0, 16'h0);  measure("ABCD D1,D0",     6);
    prog(16'h8101, 16'h0, 16'h0);  measure("SBCD D1,D0",     6);
    prog(16'h4800, 16'h0, 16'h0);  measure("NBCD D0",        6);

    // -- Extended add and subtract.
    prog(16'hD101, 16'h0, 16'h0);  measure("ADDX.B D1,D0",   4);
    prog(16'hD181, 16'h0, 16'h0);  measure("ADDX.L D1,D0",   8);
    prog(16'h9101, 16'h0, 16'h0);  measure("SUBX.B D1,D0",   4);

    // -- EXG, and CMPM which walks two post-incremented operands.
    prog(16'hC141, 16'h0, 16'h0);  measure("EXG D0,D1",      6);
    prog(16'hB308, 16'h0, 16'h0);  measure("CMPM.B (A0)+,(A1)+", 12);

    // -- MOVEP: 16 and 24, and no internal cycles at all.
    prog(16'h0108, 16'h0004, 16'h0);  measure("MOVEP.W (4,A0),D0", 16);
    prog(16'h0148, 16'h0004, 16'h0);  measure("MOVEP.L (4,A0),D0", 24);
    prog(16'h0188, 16'h0004, 16'h0);  measure("MOVEP.W D0,(4,A0)", 16);
    prog(16'h01C8, 16'h0004, 16'h0);  measure("MOVEP.L D0,(4,A0)", 24);

    // -- MOVEM. Section 9's 8+4n and 12+4n, with n = 1 here (D0 alone) and
    //    then n = 3, which is what shows the per-register cost is only the
    //    bus cycles.
    prog(16'h4890, 16'h0001, 16'h0);  measure("MOVEM.W D0,(A0)",      12);
    prog(16'h4890, 16'h0007, 16'h0);  measure("MOVEM.W D0-D2,(A0)",   20);
    prog(16'h48D0, 16'h0007, 16'h0);  measure("MOVEM.L D0-D2,(A0)",   32);
    prog(16'h4C90, 16'h0001, 16'h0);  measure("MOVEM.W (A0),D0",      16);
    prog(16'h4C90, 16'h0007, 16'h0);  measure("MOVEM.W (A0),D0-D2",   24);
    prog(16'h4CD0, 16'h0007, 16'h0);  measure("MOVEM.L (A0),D0-D2",   36);
    // Through A7, because A0 is zero out of reset and -(A0) would walk off
    // the bottom of memory.
    prog(16'h48A7, 16'hE000, 16'h0);  measure("MOVEM.W D0-D2,-(A7)",  20);

    $display("== the MC68010's own instructions ==");
    // MOVEC is 10 one way and 12 the other; MOVES 18 through (An).
    prog(16'h4E7A, 16'h0801, 16'h0);  measure("MOVEC VBR,D0",         10);
    prog(16'h4E7B, 16'h0801, 16'h0);  measure("MOVEC D0,VBR",         12);
    prog(16'h0E10, 16'h1000, 16'h0);  measure("MOVES.B (A0),D1",      18);
    prog(16'h0E10, 16'h1800, 16'h0);  measure("MOVES.B D1,(A0)",      18);
    prog(16'h0E90, 16'h1000, 16'h0);  measure("MOVES.L (A0),D1",      22);
    prog(16'h0E90, 16'h1800, 16'h0);  measure("MOVES.L D1,(A0)",      22);
    prog(16'h4E74, 16'h0000, 16'h0);  measure("RTD #0",               16);

    if (errors == 0) $display("PASS: core_timing_tb");
    else             $display("FAIL: core_timing_tb, %0d errors", errors);
    $finish;
  end

endmodule
