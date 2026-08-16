// The four instructions the MC68010 added, and the cases no vector reaches.
//
// RTD, BKPT, MOVEC and MOVES exist only on this part, so the SingleStepTests
// sweep -- which was generated from an MC68000 -- has nothing to compare them
// against. Everything they do is checked here instead, against PRM section 4
// (RTD, BKPT) and section 6 (MOVEC, MOVES).
//
// What each of them has to get right:
//
//   RTD    pops the return address and then adds the displacement to the
//          stack pointer, so the stack moves by 4 + d and not by 4.
//   BKPT   runs a breakpoint acknowledge cycle -- CPU space, function codes
//          all ones, zeros on every address line -- and then takes an illegal
//          instruction exception whatever terminated the cycle.
//   MOVEC  reaches four control registers and only four; any other code is an
//          illegal instruction, and the whole instruction is privileged.
//   MOVES  reads through SFC and writes through DFC, so the function code on
//          the pins is one the program chose rather than the mode the
//          processor is in.
//
// The last section is a different kind of gap: MOVEM with an empty register
// mask exists in the encoding and does not appear anywhere in the reference
// vectors, so the sweep never exercises the one path through MOVEM's microcode
// that skips its loop entirely.

`timescale 1ns/1ps

module core_m68010_tb;

`include "rd68011_core_harness.svh"

  localparam logic [31:0] SSP0 = 32'h0000_3000;
  localparam logic [31:0] USP0 = 32'h0000_5000;
  localparam logic [31:0] PC0  = 32'h0000_1000;

  localparam logic [31:0] H_ILLEGAL = 32'h0000_2000;
  localparam logic [31:0] H_PRIV    = 32'h0000_2100;
  localparam logic [31:0] H_DONE    = 32'h0000_2200;

  task automatic run_until_pc(input logic [31:0] want, input int limit);
    int n;
    begin
      n = 0;
      while ((dut.u_seq.ir_pc !== want) && (n < limit)) begin
        @(posedge clk);
        n = n + 1;
      end
      if (dut.u_seq.ir_pc !== want) begin
        $display("FAIL: never reached %08h; ir_pc is %08h after %0d clocks",
                 want, dut.u_seq.ir_pc, limit);
        errors = errors + 1;
      end
    end
  endtask

  // Every test starts from the same place: reset, the vector table, and a
  // handler at each address the test might land on.
  task automatic setup();
    begin
      core_reset();
      poke_l(23'h000000, SSP0);
      poke_l(23'h000002, PC0);
      poke_l(23'h000008, H_ILLEGAL);   // vector 4
      poke_l(23'h000010, H_PRIV);      // vector 8
      poke_w(H_ILLEGAL[23:1], 16'h60FE);
      poke_w(H_PRIV[23:1],    16'h60FE);
      poke_w(H_DONE[23:1],    16'h60FE);
    end
  endtask

  int i;

  initial begin
    errors = 0;

    // ======================================================================
    // RTD -- (SP) -> PC; SP + 4 + d -> SP
    // ======================================================================
    setup();
    // The return address and the displacement. RTD #$10 leaves the stack
    // pointer twenty bytes above where it started, not four.
    poke_l(23'h001800, H_DONE);        // 3000: the return address
    poke_w(23'h000800, 16'h4E74);      // 1000: RTD #16
    poke_w(23'h000801, 16'h0010);
    core_start();
    run_until_pc(H_DONE, 400);
    expect_u32("RTD: stack pointer moved by 4 + d",
               dut.u_seq.ssp, SSP0 + 32'd20);

    // A negative displacement moves it the other way, which is what makes the
    // sign extension worth checking.
    setup();
    poke_l(23'h001800, H_DONE);
    poke_w(23'h000800, 16'h4E74);      // 1000: RTD #-8
    poke_w(23'h000801, 16'hFFF8);
    core_start();
    run_until_pc(H_DONE, 400);
    expect_u32("RTD: a negative displacement",
               dut.u_seq.ssp, SSP0 + 32'd4 - 32'd8);

    // ======================================================================
    // BKPT -- acknowledge cycle, then an illegal instruction exception
    // ======================================================================
    setup();
    poke_w(23'h000800, 16'h484B);      // 1000: BKPT #3
    core_start();
    run_until_pc(H_ILLEGAL, 600);

    // Find it by its function code: it is the only CPU space cycle here.
    begin
      int nbk;
      nbk = 0;
      for (i = 0; i < ntr; i = i + 1) begin
        if (tr_fc[i] === 3'b111) begin
          nbk = nbk + 1;
          expect_u32("BKPT: zeros on every address line",
                     {9'd0, tr_addr[i]}, 32'd0);
          if (!tr_rw[i]) begin
            $display("FAIL: BKPT: the acknowledge cycle is not a read");
            errors = errors + 1;
          end
        end
      end
      expect_int("BKPT: one acknowledge cycle", nbk, 1);
    end
    expect_u32("BKPT: the frame points at the BKPT itself",
               {mem.peek((SSP0 - 32'd8 + 32'd2) >> 1),
                mem.peek((SSP0 - 32'd8 + 32'd4) >> 1)}, PC0);
    expect_u32("BKPT: vector 4",
               {16'd0, mem.peek((SSP0 - 32'd8 + 32'd6) >> 1)},
               {22'd0, 8'd4, 2'b00});

    // ======================================================================
    // MOVEC -- the four control registers, and nothing else
    // ======================================================================
    setup();
    //  1000: MOVEQ #$5D,D0
    //  1002: MOVEC D0,SFC          SFC takes three bits of it
    //  1006: MOVEC D0,DFC
    //  100A: MOVEC SFC,D1          and reads back zero-extended
    //  100E: MOVEC DFC,D2
    //  1012: BRA to the handler
    poke_w(23'h000800, 16'h705D);
    poke_w(23'h000801, 16'h4E7B);  poke_w(23'h000802, 16'h0000);
    poke_w(23'h000803, 16'h4E7B);  poke_w(23'h000804, 16'h0001);
    poke_w(23'h000805, 16'h4E7A);  poke_w(23'h000806, 16'h1000);
    poke_w(23'h000807, 16'h4E7A);  poke_w(23'h000808, 16'h2001);
    poke_w(23'h000809, 16'h4EF9);  poke_l(23'h00080A, H_DONE);
    core_start();
    run_until_pc(H_DONE, 800);
    expect_u32("MOVEC: SFC keeps three bits", {29'd0, dut.u_seq.sfc}, 32'd5);
    expect_u32("MOVEC: DFC keeps three bits", {29'd0, dut.u_seq.dfc}, 32'd5);
    expect_u32("MOVEC: SFC reads back zero-extended",
               dut.u_seq.regs[1], 32'd5);
    expect_u32("MOVEC: DFC reads back zero-extended",
               dut.u_seq.regs[2], 32'd5);

    // VBR and USP are whole registers, and VBR moving the vector table is
    // what makes it worth writing at all.
    setup();
    //  1000: MOVE.L #$00004000,D0
    //  1006: MOVEC D0,VBR
    //  100A: MOVEC VBR,D3
    //  100E: MOVE.L #$00006000,A0
    //  1014: MOVEC A0,USP
    //  1018: MOVEC USP,D4
    //  101C: BRA to the handler
    poke_w(23'h000800, 16'h203C);  poke_l(23'h000801, 32'h0000_4000);
    poke_w(23'h000803, 16'h4E7B);  poke_w(23'h000804, 16'h0801);
    poke_w(23'h000805, 16'h4E7A);  poke_w(23'h000806, 16'h3801);
    poke_w(23'h000807, 16'h207C);  poke_l(23'h000808, 32'h0000_6000);
    poke_w(23'h00080A, 16'h4E7B);  poke_w(23'h00080B, 16'h8800);
    poke_w(23'h00080C, 16'h4E7A);  poke_w(23'h00080D, 16'h4800);
    poke_w(23'h00080E, 16'h4EF9);  poke_l(23'h00080F, H_DONE);
    core_start();
    run_until_pc(H_DONE, 900);
    expect_u32("MOVEC: VBR written",     dut.u_seq.vbr, 32'h0000_4000);
    expect_u32("MOVEC: VBR read back",   dut.u_seq.regs[3], 32'h0000_4000);
    expect_u32("MOVEC: USP written",     dut.u_seq.usp, 32'h0000_6000);
    expect_u32("MOVEC: USP read back",   dut.u_seq.regs[4], 32'h0000_6000);

    // "Any other code causes an illegal instruction exception", and the frame
    // points at the MOVEC rather than past it.
    setup();
    poke_w(23'h000800, 16'h4E7A);  poke_w(23'h000801, 16'h0002);
    core_start();
    run_until_pc(H_ILLEGAL, 500);
    expect_u32("MOVEC: an unknown control register is illegal",
               {mem.peek((SSP0 - 32'd8 + 32'd2) >> 1),
                mem.peek((SSP0 - 32'd8 + 32'd4) >> 1)}, PC0);

    // And the whole instruction is privileged.
    setup();
    //  1000: MOVE #$0000,SR      leave supervisor mode
    //  1004: MOVEC VBR,D0        privilege violation
    poke_w(23'h000800, 16'h46FC);  poke_w(23'h000801, 16'h0000);
    poke_w(23'h000802, 16'h4E7A);  poke_w(23'h000803, 16'h0801);
    core_start();
    run_until_pc(H_PRIV, 600);
    expect_u32("MOVEC: privileged in user mode",
               {mem.peek((SSP0 - 32'd8 + 32'd2) >> 1),
                mem.peek((SSP0 - 32'd8 + 32'd4) >> 1)}, PC0 + 32'd4);

    // ======================================================================
    // MOVES -- the access goes to the space SFC or DFC names
    // ======================================================================
    setup();
    //  1000: MOVEQ #1,D0
    //  1002: MOVEC D0,SFC             read through space 1: user data
    //  1006: MOVEQ #3,D0
    //  1008: MOVEC D0,DFC             write through space 3, which is unused
    //  100C: MOVE.L #$00004000,A0
    //  1012: MOVE.L #$12345678,D1
    //  1018: MOVES.L D1,(A0)
    //  101C: MOVES.L (A0),D2
    //  1020: BRA to the handler
    poke_w(23'h000800, 16'h7001);
    poke_w(23'h000801, 16'h4E7B);  poke_w(23'h000802, 16'h0000);
    poke_w(23'h000803, 16'h7003);
    poke_w(23'h000804, 16'h4E7B);  poke_w(23'h000805, 16'h0001);
    poke_w(23'h000806, 16'h207C);  poke_l(23'h000807, 32'h0000_4000);
    poke_w(23'h000809, 16'h223C);  poke_l(23'h00080A, 32'h1234_5678);
    poke_w(23'h00080C, 16'h0E90);  poke_w(23'h00080D, 16'h1800);
    poke_w(23'h00080E, 16'h0E90);  poke_w(23'h00080F, 16'h2000);
    poke_w(23'h000810, 16'h4EF9);  poke_l(23'h000811, H_DONE);
    core_start();
    run_until_pc(H_DONE, 1200);
    expect_u32("MOVES: the long reached memory",
               {mem.peek(23'h002000), mem.peek(23'h002001)}, 32'h1234_5678);
    expect_u32("MOVES: and came back into D2",
               dut.u_seq.regs[2], 32'h1234_5678);

    // The function codes on the pins are the ones the program chose. Find the
    // MOVES cycles by address: they are the only accesses to $4000.
    begin
      int nw, nr;
      nw = 0;
      nr = 0;
      for (i = 0; i < ntr; i = i + 1) begin
        if ({tr_addr[i], 1'b0} == 24'h004000) begin
          if (tr_rw[i]) begin
            nr = nr + 1;
            if (tr_fc[i] !== 3'd1) begin
              $display("FAIL: MOVES read used function code %0d, expected 1",
                       tr_fc[i]);
              errors = errors + 1;
            end
          end else begin
            nw = nw + 1;
            if (tr_fc[i] !== 3'd3) begin
              $display("FAIL: MOVES write used function code %0d, expected 3",
                       tr_fc[i]);
              errors = errors + 1;
            end
          end
        end
      end
      expect_int("MOVES: one write at $4000", nw, 1);
      expect_int("MOVES: one read at $4000",  nr, 1);
    end

    // A word into an address register is sign-extended; a word into a data
    // register replaces the low half only.
    setup();
    //  1000: MOVE.L #$00004000,A0
    //  1006: MOVE.W #$8001,D0
    //  100A: MOVE.W D0,(A0)          an ordinary store, to set the memory up
    //  100C: MOVE.L #$AAAABBBB,D1
    //  1012: MOVES.W (A0),D1         low half only
    //  1016: MOVES.W (A0),A1         sign-extended
    //  101A: BRA to the handler
    poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, 32'h0000_4000);
    poke_w(23'h000803, 16'h303C);  poke_w(23'h000804, 16'h8001);
    poke_w(23'h000805, 16'h3080);
    poke_w(23'h000806, 16'h223C);  poke_l(23'h000807, 32'hAAAA_BBBB);
    poke_w(23'h000809, 16'h0E50);  poke_w(23'h00080A, 16'h1000);
    poke_w(23'h00080B, 16'h0E50);  poke_w(23'h00080C, 16'h9000);
    poke_w(23'h00080D, 16'h4EF9);  poke_l(23'h00080E, H_DONE);
    core_start();
    run_until_pc(H_DONE, 1200);
    expect_u32("MOVES.W to a data register keeps the high half",
               dut.u_seq.regs[1], 32'hAAAA_8001);
    expect_u32("MOVES.W to an address register sign-extends",
               dut.u_seq.regs[9], 32'hFFFF_8001);

    // MOVES with the same address register as source and destination. PRM
    // section 6 calls the value stored undefined and says the real parts store
    // the modified one; this stores the unmodified one, because the write data
    // leaves the register file at the start of the cycle and the address
    // unit's update lands at the end of it. Pinned here so it cannot drift
    // without being noticed -- doc/divergences.md has the argument.
    setup();
    //  1000: MOVE.L #$00004000,A0
    //  1006: MOVES.L A0,(A0)+
    //  100A: BRA to the handler
    poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, 32'h0000_4000);
    poke_w(23'h000803, 16'h0E98);  poke_w(23'h000804, 16'h8800);
    poke_w(23'h000805, 16'h4EF9);  poke_l(23'h000806, H_DONE);
    core_start();
    run_until_pc(H_DONE, 900);
    expect_u32("MOVES An,(An)+ stores the unmodified register",
               {mem.peek(23'h002000), mem.peek(23'h002001)}, 32'h0000_4000);
    expect_u32("MOVES An,(An)+ still increments",
               dut.u_seq.regs[8], 32'h0000_4004);

    // And it is privileged too.
    setup();
    poke_w(23'h000800, 16'h46FC);  poke_w(23'h000801, 16'h0000);
    poke_w(23'h000802, 16'h0E90);  poke_w(23'h000803, 16'h1800);
    core_start();
    run_until_pc(H_PRIV, 600);
    expect_u32("MOVES: privileged in user mode",
               {mem.peek((SSP0 - 32'd8 + 32'd2) >> 1),
                mem.peek((SSP0 - 32'd8 + 32'd4) >> 1)}, PC0 + 32'd4);

    // ======================================================================
    // MOVEM with an empty mask -- the path the vectors never take
    // ======================================================================
    setup();
    //  1000: MOVE.L #$00004000,A0
    //  1006: MOVEM.W #0,(A0)         no writes at all
    //  100C: MOVEM.W (A0)+,#0        one read, the overrun, and A0 unmoved
    //  1012: BRA to the handler
    poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, 32'h0000_4000);
    poke_w(23'h000803, 16'h4890);  poke_w(23'h000804, 16'h0000);
    poke_w(23'h000805, 16'h4C98);  poke_w(23'h000806, 16'h0000);
    poke_w(23'h000807, 16'h4EF9);  poke_l(23'h000808, H_DONE);
    // Something recognisable at the address, so a stray write would show.
    poke_w(23'h002000, 16'h5A5A);
    core_start();
    run_until_pc(H_DONE, 900);
    expect_u32("MOVEM with an empty mask writes nothing",
               {16'd0, mem.peek(23'h002000)}, 32'h0000_5A5A);
    expect_u32("MOVEM (An)+ with an empty mask leaves the register alone",
               dut.u_seq.regs[8], 32'h0000_4000);
    begin
      int nacc;
      nacc = 0;
      for (i = 0; i < ntr; i = i + 1)
        if ({tr_addr[i], 1'b0} == 24'h004000) nacc = nacc + 1;
      // Exactly one: the overrun read the memory-to-register form always
      // makes. The register-to-memory one makes no access at all.
      expect_int("MOVEM with an empty mask: one access, the overrun read",
                 nacc, 1);
    end

    if (errors == 0) $display("PASS: core_m68010_tb");
    else             $display("FAIL: core_m68010_tb, %0d errors", errors);
    $finish;
  end

endmodule
