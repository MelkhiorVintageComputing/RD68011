// The fetch/decode/execute loop: reset, NOP and BRA.
//
// This is P2's exit criterion. What is being checked is not that NOP does
// nothing -- it is that the prefetch pipe behaves exactly as the reference
// vectors say it does, because every instruction after this one is built on
// that behaviour.
//
// The model, verified against thousands of vectors per opcode by
// tools/harte/model_check.py:
//
//   at an instruction boundary at address A:  ir = [A], irc = [A+2], pc = A+4
//   PF   irc <- [pc]; irc_pc <- pc; pc <- pc + 2
//   ADV  ir <- irc; ir_pc <- irc_pc
//
// so an instruction with no extension words does exactly one read, and a taken
// branch does two.
//
// Reset, UM 5.5: SSP from $000000, PC from $000004, then the two prefetches
// that fill the pipe. Four reads and two prefetches, six cycles in all.
//
// The program is a two-instruction loop that exercises both branch forms:
//
//   1000  NOP
//   1002  BRA.B +4      -> 1008
//   1008  NOP
//   100A  BRA.W -12     -> 1000
//
// A branch displacement is measured from the word after the opcode, which is
// the word irc holds, so irc_pc is the base in both forms.

`timescale 1ns/1ps

module core_fetch_tb;

`include "rd68011_core_harness.svh"

  localparam logic [31:0] SSP0 = 32'h0000_2000;
  localparam logic [31:0] PC0  = 32'h0000_1000;

  localparam logic  [2:0] SP = 3'b110;   // supervisor program (UM table 3-3)

  int i, base;
  int nop_clocks, brab_clocks, braw_clocks;

  initial begin
    errors = 0;
    core_reset();

    // Reset vector table.
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);

    // The loop.
    poke_w(23'h000800, 16'h4E71);   // 1000: NOP
    poke_w(23'h000801, 16'h6004);   // 1002: BRA.B +4
    poke_w(23'h000802, 16'hDEAD);   // 1004: skipped
    poke_w(23'h000803, 16'hDEAD);   // 1006: skipped
    poke_w(23'h000804, 16'h4E71);   // 1008: NOP
    poke_w(23'h000805, 16'h6000);   // 100A: BRA.W
    poke_w(23'h000806, 16'hFFF4);   // 100C: displacement, -12
    poke_w(23'h000807, 16'hDEAD);   // 100E: never reached

    core_start();

    // Let it run two full turns of the loop.
    repeat (200) @(posedge clk);

    // ---- Reset: four vector reads, then two prefetches ---------------------
    expect_tr(0, 32'h000000, SP, 1'b1, "reset SSP high");
    expect_tr(1, 32'h000002, SP, 1'b1, "reset SSP low");
    expect_tr(2, 32'h000004, SP, 1'b1, "reset PC high");
    expect_tr(3, 32'h000006, SP, 1'b1, "reset PC low");
    expect_tr(4, 32'h001000, SP, 1'b1, "reset prefetch, irc");
    expect_tr(5, 32'h001002, SP, 1'b1, "reset prefetch, ir and irc");

    // The reset sequence loaded A7 and PC from the vector table.
    expect_u32("SSP after reset", dut.u_seq.ssp, SSP0);
    // Two prefetches past the entry point.
    expect_u32("pc after reset", dut.u_seq.pc, PC0 + 32'd4);
    expect_u32("ir after reset",  {16'd0, dut.u_seq.ir},  32'h4E71);
    expect_u32("irc after reset", {16'd0, dut.u_seq.irc}, 32'h6004);
    expect_u32("ir_pc after reset",  dut.u_seq.ir_pc,  PC0);
    expect_u32("irc_pc after reset", dut.u_seq.irc_pc, PC0 + 32'd2);
    // UM 5.5: interrupt level seven, supervisor mode, VBR cleared.
    expect_u32("SR after reset",  {16'd0, dut.u_seq.sr}, 32'h2700);
    expect_u32("VBR after reset", dut.u_seq.vbr, 32'd0);

    // ---- Two turns of the loop ---------------------------------------------
    // Six bus cycles per turn: one prefetch for each NOP, two for each branch.
    for (i = 0; i < 2; i = i + 1) begin
      base = 6 + i * 6;
      expect_tr(base + 0, 32'h001004, SP, 1'b1, "NOP at 1000 prefetches");
      expect_tr(base + 1, 32'h001008, SP, 1'b1, "BRA.B refills irc");
      expect_tr(base + 2, 32'h00100A, SP, 1'b1, "BRA.B refills ir and irc");
      expect_tr(base + 3, 32'h00100C, SP, 1'b1, "NOP at 1008 prefetches");
      expect_tr(base + 4, 32'h001000, SP, 1'b1, "BRA.W refills irc");
      expect_tr(base + 5, 32'h001002, SP, 1'b1, "BRA.W refills ir and irc");
    end

    // The word at 1004 *is* fetched, even though it is never executed: the NOP
    // at 1000 prefetches it before the branch at 1002 has run. That is the
    // prefetch pipe being visible on the bus, and it is why a program cannot
    // put memory-mapped registers with read side effects immediately after a
    // branch. 1006 and 100E, two and four words past, are never touched.
    for (i = 0; i < ntr; i = i + 1) begin
      if ((tr_addr[i] == 23'h000803) || (tr_addr[i] == 23'h000807)) begin
        $display("FAIL: cycle %0d read %06h, which is past the prefetch",
                 i, {tr_addr[i], 1'b0});
        errors = errors + 1;
      end
    end
    if (ntr > 6) begin
      base = 0;
      for (i = 0; i < ntr; i = i + 1) begin
        if (tr_addr[i] == 23'h000802) base = 1;
      end
      if (base == 0) begin
        $display("FAIL: 001004 was never prefetched, but it should be");
        errors = errors + 1;
      end
    end

    // Every cycle was a supervisor program read: no data space, no writes.
    for (i = 0; i < ntr; i = i + 1) begin
      if (tr_fc[i] !== SP || tr_rw[i] !== 1'b1) begin
        $display("FAIL: cycle %0d is fc=%0d %s, not a supervisor program read",
                 i, tr_fc[i], tr_rw[i] ? "read" : "write");
        errors = errors + 1;
      end
    end

    // ---- Cycle counts -------------------------------------------------------
    // Between instruction boundaries. The reference vectors give NOP four
    // cycles and a taken Bcc ten, and this microcode is structured to produce
    // those numbers rather than to approximate them: NOP is one prefetch, and
    // a taken branch is two internal microwords plus two prefetches.
    //
    // ins_clk[0] is the boundary that ends the reset sequence, so the first
    // instruction of the loop is the gap from [0] to [1].
    if (nins < 6) begin
      $display("FAIL: only %0d instruction boundaries seen", nins);
      errors = errors + 1;
    end else begin
      expect_u32("first instruction is NOP", {16'd0, ins_op[1]}, 32'h4E71);
      expect_u32("second is BRA.B", {16'd0, ins_op[2]}, 32'h6004);
      expect_u32("third is NOP",    {16'd0, ins_op[3]}, 32'h4E71);
      expect_u32("fourth is BRA.W", {16'd0, ins_op[4]}, 32'h6000);

      nop_clocks  = ins_clk[1] - ins_clk[0];
      brab_clocks = ins_clk[2] - ins_clk[1];
      braw_clocks = ins_clk[4] - ins_clk[3];

      $display("  NOP    %0d clocks (reference: 4)",  nop_clocks);
      $display("  BRA.B  %0d clocks (reference: 10)", brab_clocks);
      $display("  BRA.W  %0d clocks (reference: 10)", braw_clocks);
      expect_int("NOP cycle count",   nop_clocks,  4);
      expect_int("BRA.B cycle count", brab_clocks, 10);
      expect_int("BRA.W cycle count", braw_clocks, 10);

      // And the loop as a whole: 4 + 10 + 4 + 10.
      expect_int("loop cycle count", ins_clk[5] - ins_clk[1], 28);
    end

    core_done("core_fetch_tb");
  end

endmodule
