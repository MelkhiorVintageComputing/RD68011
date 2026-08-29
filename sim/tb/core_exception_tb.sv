// Exception processing and the format $0 stack frame.
//
// The reference vectors cannot check this: they come from an MC68000, which
// pushes three words and has no format field. So this is a directed test of
// what UM section 6 figure 6-6 specifies for the MC68010:
//
//   SP+0   status register, as it was when the exception began
//   SP+2   program counter, high
//   SP+4   program counter, low
//   SP+6   0000 and the vector offset -- the vector number times four
//
// and of the things around it: supervisor mode is entered, trace is cleared,
// the vector comes from VBR plus the offset, the user stack pointer is left
// alone while the supervisor one moves, and RTE puts all of it back.
//
// Which program counter is stacked is the point of half of these: an exception
// the instruction asked for stacks the *next* instruction, and one that is the
// instruction's own fault stacks the instruction itself (UM section 6).

`timescale 1ns/1ps

module core_exception_tb;

`include "rd68011_core_harness.svh"

  localparam logic [31:0] SSP0 = 32'h0000_3000;
  localparam logic [31:0] USP0 = 32'h0000_5000;
  localparam logic [31:0] PC0  = 32'h0000_1000;

  // Where each handler lives, so a test can tell which vector was taken.
  localparam logic [31:0] H_ILLEGAL = 32'h0000_2000;
  localparam logic [31:0] H_LINEA   = 32'h0000_2100;
  localparam logic [31:0] H_LINEF   = 32'h0000_2200;
  localparam logic [31:0] H_TRAPV   = 32'h0000_2300;
  localparam logic [31:0] H_TRAP3   = 32'h0000_2400;
  localparam logic [31:0] H_TRACE   = 32'h0000_2500;
  localparam logic [31:0] H_PRIV    = 32'h0000_2600;
  localparam logic [31:0] H_AUTO5   = 32'h0000_2700;

  int i;

  task automatic check_frame(input string what,
                             input logic [31:0] sp,
                             input logic [15:0] want_sr,
                             input logic [31:0] want_pc,
                             input logic  [7:0] want_vec);
    begin
      expect_u32({what, ": frame SR"},
                 {16'd0, mem.peek(sp[23:1])}, {16'd0, want_sr});
      expect_u32({what, ": frame PC"},
                 {mem.peek((sp + 32'd2) >> 1), mem.peek((sp + 32'd4) >> 1)},
                 want_pc);
      // Format zero in the top four bits, and the vector offset -- which is
      // the vector number times four -- in the bottom twelve.
      expect_u32({what, ": frame format and vector offset"},
                 {16'd0, mem.peek((sp + 32'd6) >> 1)},
                 {22'd0, want_vec, 2'b00});
    end
  endtask

  // Run until the core reaches a handler, which every handler announces by
  // being a tight loop of its own; a bounded wait, so a test that never gets
  // there fails rather than hangs.
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

  // A program that gives the two stack pointers different values, drops into
  // user mode, and traps. `handler` is the one instruction the trap handler
  // runs, so the caller chooses between parking there and returning.
  task automatic user_mode_trap(input logic [15:0] handler);
    int k;
    begin
      core_reset();
      poke_l(23'h000000, SSP0);
      poke_l(23'h000002, PC0);
      poke_l(23'h000046, H_TRAP3);       // vector 35, TRAP #3
      poke_w(H_TRAP3[23:1], handler);
      //  1000: MOVEA.L #$00005000,A0
      //  1006: MOVE    A0,USP
      //  1008: MOVE    #$0700,SR        user mode, and the mask left at seven
      //  100C: TRAP    #3
      //  100E: BRA     self             where RTE comes back to
      poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, USP0);
      poke_w(23'h000803, 16'h4E60);
      poke_w(23'h000804, 16'h46FC);  poke_w(23'h000805, 16'h0700);
      poke_w(23'h000806, 16'h4E43);
      poke_w(23'h000807, 16'h60FE);
      // Four sentinel words where a frame on the user stack would go.
      for (k = 0; k < 4; k = k + 1)
        poke_w(23'((USP0 - 32'd8) >> 1) + 23'(k), 16'hA5A5);
      core_start();
    end
  endtask

  initial begin
    errors = 0;
    core_reset();

    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);

    // The vector table entries this test uses.
    poke_l(23'h000008, H_ILLEGAL);   // vector 4 is at byte 16
    poke_l(23'h00000E, H_TRAPV);     // vector 7, TRAPV
    poke_l(23'h000014, H_LINEA);     // vector 10, line A
    poke_l(23'h000016, H_LINEF);     // vector 11, line F
    poke_l(23'h000046, H_TRAP3);     // vector 35 is at byte 140

    // Each handler is a branch to itself, so the core parks there and the
    // test can see which one it reached.
    poke_w(H_ILLEGAL[23:1], 16'h60FE);
    poke_w(H_LINEA[23:1],   16'h60FE);
    poke_w(H_LINEF[23:1],   16'h60FE);
    poke_w(H_TRAPV[23:1],   16'h60FE);
    poke_w(H_TRAP3[23:1],   16'h60FE);

    // ---- An illegal instruction stacks its own address --------------------
    poke_w(23'h000800, 16'h4AFC);    // 1000: ILLEGAL
    core_start();
    run_until_pc(H_ILLEGAL, 400);

    expect_u32("illegal: supervisor mode entered",
               {31'd0, dut.u_seq.sr[13]}, 32'd1);
    expect_u32("illegal: SSP moved by eight", dut.u_seq.ssp, SSP0 - 32'd8);
    expect_u32("illegal: USP untouched", dut.u_seq.usp, 32'd0);
    check_frame("illegal", SSP0 - 32'd8, 16'h2700, PC0, 8'd4);

    // ---- Line A and line F, which are the other two "own address" cases ----
    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h000008, H_ILLEGAL);
    poke_l(23'h000014, H_LINEA);
    poke_l(23'h000016, H_LINEF);
    poke_w(H_LINEA[23:1], 16'h60FE);
    poke_w(H_LINEF[23:1], 16'h60FE);
    poke_w(23'h000800, 16'hA123);    // 1000: an unimplemented line A opcode
    core_start();
    run_until_pc(H_LINEA, 400);
    check_frame("line A", SSP0 - 32'd8, 16'h2700, PC0, 8'd10);

    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h000016, H_LINEF);
    poke_w(H_LINEF[23:1], 16'h60FE);
    poke_w(23'h000800, 16'hF456);    // 1000: an unimplemented line F opcode
    core_start();
    run_until_pc(H_LINEF, 400);
    check_frame("line F", SSP0 - 32'd8, 16'h2700, PC0, 8'd11);

    // ---- TRAP #3 stacks the *following* instruction ------------------------
    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h000046, H_TRAP3);
    poke_w(H_TRAP3[23:1], 16'h60FE);
    poke_w(23'h000800, 16'h4E43);    // 1000: TRAP #3
    poke_w(23'h000801, 16'h4E71);    // 1002: NOP, never executed
    core_start();
    run_until_pc(H_TRAP3, 400);
    check_frame("TRAP #3", SSP0 - 32'd8, 16'h2700, PC0 + 32'd2, 8'd35);

    // ---- TRAPV: nothing when V is clear, an exception when it is set -------
    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h00000E, H_TRAPV);
    poke_w(H_TRAPV[23:1], 16'h60FE);
    // MOVEQ #-1,D0 sets N and clears V, so TRAPV falls through; the ILLEGAL
    // after it is what the test then lands on.
    poke_l(23'h000008, H_ILLEGAL);
    poke_w(H_ILLEGAL[23:1], 16'h60FE);
    poke_w(23'h000800, 16'h70FF);    // 1000: MOVEQ #-1,D0   (V cleared)
    poke_w(23'h000801, 16'h4E76);    // 1002: TRAPV
    poke_w(23'h000802, 16'h4AFC);    // 1004: ILLEGAL
    core_start();
    run_until_pc(H_ILLEGAL, 400);
    expect_u32("TRAPV with V clear falls through to the ILLEGAL after it",
               {mem.peek((SSP0 - 32'd8 + 32'd2) >> 1),
                mem.peek((SSP0 - 32'd8 + 32'd4) >> 1)}, PC0 + 32'd4);

    // Now with V set. ADD.W of two large positives overflows.
    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h00000E, H_TRAPV);
    poke_w(H_TRAPV[23:1], 16'h60FE);
    poke_w(23'h000800, 16'h303C);    // 1000: MOVE.W #$7FFF,D0
    poke_w(23'h000801, 16'h7FFF);
    poke_w(23'h000802, 16'h0640);    // 1004: ADDI.W #1,D0  -> overflow
    poke_w(23'h000803, 16'h0001);
    poke_w(23'h000804, 16'h4E76);    // 1008: TRAPV
    core_start();
    run_until_pc(H_TRAPV, 600);
    check_frame("TRAPV", SSP0 - 32'd8, 16'h270A, PC0 + 32'd10, 8'd7);

    // ---- RTE takes the frame back off and returns -------------------------
    // TRAP, not ILLEGAL: an illegal instruction stacks its *own* address, so
    // returning to it would run it again forever. TRAP stacks the instruction
    // after it, which is where the return should land.
    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h000046, H_TRAP3);
    poke_w(H_TRAP3[23:1], 16'h4E73);     // the handler is just an RTE
    poke_w(23'h000800, 16'h4E43);        // 1000: TRAP #3
    poke_w(23'h000801, 16'h60FE);        // 1002: branch to self, the target
    core_start();
    run_until_pc(PC0 + 32'd2, 800);
    expect_u32("RTE: SSP restored", dut.u_seq.ssp, SSP0);
    expect_u32("RTE: status register restored",
               {16'd0, dut.u_seq.sr}, 32'h0000_2700);

    // ---- Trace: an exception after every instruction ----------------------
    // The handler counts as an instruction too, so tracing is switched off by
    // the exception itself and the handler runs untraced.
    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h000012, H_TRAPV);         // vector 9 is at byte 36
    poke_w(H_TRAPV[23:1], 16'h60FE);
    poke_w(23'h000800, 16'h46FC);        // 1000: MOVE #$A700,SR  (trace on)
    poke_w(23'h000801, 16'hA700);
    poke_w(23'h000802, 16'h4E71);        // 1004: NOP, the traced instruction
    poke_w(23'h000803, 16'h4E71);        // 1006: NOP
    core_start();
    run_until_pc(H_TRAPV, 800);
    // The trace exception stacks the instruction *after* the one traced.
    check_frame("trace", SSP0 - 32'd8, 16'hA700, PC0 + 32'd6, 8'd9);
    expect_u32("trace: the trace bit is cleared for the handler",
               {31'd0, dut.u_seq.sr[15]}, 32'd0);

    // ---- ... and the instructions a trace exception must NOT follow --------
    //
    // UM 6.3.8, in one paragraph, is the whole specification of when the
    // exception above happens: "If the instruction is not executed because an
    // interrupt is taken or because the instruction is illegal or privileged,
    // the trace exception does not occur. The trace exception also does not
    // occur if the instruction is aborted by a reset, bus error, or address
    // error exception. If the instruction is executed and an interrupt is
    // pending on completion, the trace exception is processed before the
    // interrupt exception. During the execution of the instruction, if an
    // exception is forced by that instruction, the exception processing for
    // the instruction exception occurs before that of the trace exception."
    //
    // Every clause of it is below. Three of them were wrong -- an instruction
    // that never ran left the arming behind, so a second frame was pushed for
    // an instruction the processor had refused to execute, and the handler for
    // the *first* exception was traced instead of running. doc/bugs-found.md
    // has what that costs a debugger.
    //
    // The reference vectors cannot arbitrate any of this -- harte_tb skips
    // every test whose reference took an exception -- but they can be counted:
    // of the ILLEGAL_LINEA vectors with T set, 1319 of 1319 push six bytes,
    // which is one frame and not two.

    // An illegal instruction is not executed, so nothing follows its frame.
    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h000008, H_ILLEGAL);       // vector 4
    poke_l(23'h000012, H_TRACE);         // vector 9
    poke_w(H_ILLEGAL[23:1], 16'h60FE);
    poke_w(H_TRACE[23:1],   16'h60FE);
    poke_w(23'h000800, 16'h46FC);        // 1000: MOVE #$A700,SR  (trace on)
    poke_w(23'h000801, 16'hA700);
    poke_w(23'h000802, 16'h4AFC);        // 1004: ILLEGAL
    core_start();
    repeat (400) @(posedge clk);
    expect_u32("traced ILLEGAL: the illegal handler runs, untraced",
               dut.u_seq.ir_pc, H_ILLEGAL);
    expect_u32("traced ILLEGAL: one frame, not two",
               dut.u_seq.ssp, SSP0 - 32'd8);
    check_frame("traced ILLEGAL", SSP0 - 32'd8, 16'hA700, PC0 + 32'd4, 8'd4);

    // Line A and line F are unimplemented instructions, which is the same
    // rule reached through the other two vectors.
    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h000014, H_LINEA);         // vector 10
    poke_l(23'h000012, H_TRACE);
    poke_w(H_LINEA[23:1], 16'h60FE);
    poke_w(23'h000800, 16'h46FC);
    poke_w(23'h000801, 16'hA700);
    poke_w(23'h000802, 16'hA000);        // 1004: line A
    core_start();
    repeat (400) @(posedge clk);
    expect_u32("traced line A: the line A handler runs, untraced",
               dut.u_seq.ir_pc, H_LINEA);
    expect_u32("traced line A: one frame, not two",
               dut.u_seq.ssp, SSP0 - 32'd8);
    check_frame("traced line A", SSP0 - 32'd8, 16'hA700, PC0 + 32'd4, 8'd10);

    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h000016, H_LINEF);         // vector 11
    poke_l(23'h000012, H_TRACE);
    poke_w(H_LINEF[23:1], 16'h60FE);
    poke_w(23'h000800, 16'h46FC);
    poke_w(23'h000801, 16'hA700);
    poke_w(23'h000802, 16'hF000);        // 1004: line F
    core_start();
    repeat (400) @(posedge clk);
    expect_u32("traced line F: the line F handler runs, untraced",
               dut.u_seq.ir_pc, H_LINEF);
    expect_u32("traced line F: one frame, not two",
               dut.u_seq.ssp, SSP0 - 32'd8);
    check_frame("traced line F", SSP0 - 32'd8, 16'hA700, PC0 + 32'd4, 8'd11);

    // A privileged instruction in user mode is refused before it does
    // anything, so it is not executed either. $8700 is trace on, supervisor
    // off -- STOP is what the manual names as the example of a privileged
    // instruction a user program may not run.
    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h000010, H_PRIV);          // vector 8
    poke_l(23'h000012, H_TRACE);
    poke_w(H_PRIV[23:1], 16'h60FE);
    poke_w(23'h000800, 16'h46FC);        // 1000: MOVE #$8700,SR  (user, T on)
    poke_w(23'h000801, 16'h8700);
    poke_w(23'h000802, 16'h4E72);        // 1004: STOP, privileged
    poke_w(23'h000803, 16'h2700);
    core_start();
    repeat (400) @(posedge clk);
    expect_u32("traced privileged: the privilege handler runs, untraced",
               dut.u_seq.ir_pc, H_PRIV);
    expect_u32("traced privileged: one frame, not two",
               dut.u_seq.ssp, SSP0 - 32'd8);
    check_frame("traced privileged", SSP0 - 32'd8, 16'h8700, PC0 + 32'd4, 8'd8);

    // An instruction displaced by an interrupt is not executed either. The
    // mask drops to zero with the line already asserted, so the interrupt is
    // taken at that boundary and the NOP behind it never runs -- and the
    // interrupt handler must run untraced, which is what the arming got wrong.
    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h000032, H_TRAP3);         // autovector 25 = level 1, byte $64
    poke_l(23'h000012, H_TRACE);
    poke_w(H_TRAP3[23:1], 16'h60FE);
    poke_w(23'h000800, 16'h46FC);        // 1000: MOVE #$A000,SR  (T on, mask 0)
    poke_w(23'h000801, 16'hA000);
    poke_w(23'h000802, 16'h4E71);        // 1004: NOP, which never runs
    poke_w(23'h000803, 16'h60FE);
    iack_auto = 1'b1;
    ipl_n_i   = ~3'd1;                   // asserted before the mask ever drops
    core_start();
    repeat (400) @(posedge clk);
    expect_u32("interrupt over a traced instruction: the handler runs untraced",
               dut.u_seq.ir_pc, H_TRAP3);
    expect_u32("interrupt over a traced instruction: one frame, not two",
               dut.u_seq.ssp, SSP0 - 32'd8);
    check_frame("interrupt over a traced instruction",
                SSP0 - 32'd8, 16'hA000, PC0 + 32'd4, 8'd25);
    ipl_n_i = 3'b111;

    // ---- ... and the two orderings it does follow -------------------------
    //
    // An instruction that *is* executed and finds an interrupt waiting is
    // traced first, and the interrupt is taken at the trace handler's own
    // first boundary. The line is raised part way through a DIVU, which is
    // long enough to raise it inside.
    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h000032, H_TRAP3);         // autovector 25
    poke_l(23'h000012, H_TRACE);         // vector 9
    poke_w(H_TRAP3[23:1], 16'h60FE);
    poke_w(H_TRACE[23:1], 16'h60FE);
    poke_w(23'h000800, 16'h46FC);        // 1000: MOVE #$A000,SR  (T on, mask 0)
    poke_w(23'h000801, 16'hA000);
    poke_w(23'h000802, 16'h80FC);        // 1004: DIVU #7,D0
    poke_w(23'h000803, 16'h0007);
    poke_w(23'h000804, 16'h60FE);
    iack_auto = 1'b1;
    core_start();
    run_until_pc(PC0 + 32'd4, 400);      // the DIVU is the instruction in hand
    repeat (20) @(posedge clk);          // well inside it
    ipl_n_i = ~3'd1;
    repeat (400) @(posedge clk);
    expect_u32("traced DIVU with an interrupt waiting: the interrupt handler",
               dut.u_seq.ir_pc, H_TRAP3);
    expect_u32("traced DIVU with an interrupt waiting: two frames",
               dut.u_seq.ssp, SSP0 - 32'd16);
    // D0 is zero, so the quotient is zero and Z is set: $x004.
    check_frame("traced DIVU: the trace frame, pushed first",
                SSP0 - 32'd8, 16'hA004, PC0 + 32'd8, 8'd9);
    check_frame("traced DIVU: the interrupt frame, pushed second",
                SSP0 - 32'd16, 16'h2004, H_TRACE, 8'd25);
    ipl_n_i = 3'b111;

    // An exception the instruction forces is processed before the trace, and
    // not instead of it: TRAP #3 was executed, so both frames are pushed and
    // the trace handler is what ends up running.
    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h000046, H_TRAP3);         // vector 35
    poke_l(23'h000012, H_TRACE);
    poke_w(H_TRAP3[23:1], 16'h60FE);
    poke_w(H_TRACE[23:1], 16'h60FE);
    poke_w(23'h000800, 16'h46FC);
    poke_w(23'h000801, 16'hA700);
    poke_w(23'h000802, 16'h4E43);        // 1004: TRAP #3
    core_start();
    repeat (400) @(posedge clk);
    expect_u32("traced TRAP: the trace handler runs, not the trap handler",
               dut.u_seq.ir_pc, H_TRACE);
    expect_u32("traced TRAP: two frames", dut.u_seq.ssp, SSP0 - 32'd16);
    check_frame("traced TRAP: the trap frame, pushed first",
                SSP0 - 32'd8, 16'hA700, PC0 + 32'd6, 8'd35);
    check_frame("traced TRAP: the trace frame, pushed second",
                SSP0 - 32'd16, 16'h2700, H_TRAP3, 8'd9);

    // ---- A traced STOP does not stop ---------------------------------------
    //
    // PRM section 6, STOP: "A trace exception occurs if instruction tracing is
    // enabled ... when the STOP instruction begins execution." So the status
    // register is loaded, the trace exception is taken, and the processor is
    // not stopped at all -- which is the whole point, since a debugger single
    // stepping through a STOP would otherwise never come back.
    //
    // The MC68000 vectors show no frame here, and are skipped for it; the
    // reason is in doc/divergences.md.
    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h000012, H_TRACE);         // vector 9
    poke_w(H_TRACE[23:1], 16'h60FE);
    poke_w(23'h000800, 16'h46FC);        // 1000: MOVE #$A700,SR
    poke_w(23'h000801, 16'hA700);
    poke_w(23'h000802, 16'h4E72);        // 1004: STOP #$2700
    poke_w(23'h000803, 16'h2700);
    poke_w(23'h000804, 16'h60FE);        // 1008: branch to self
    core_start();
    repeat (400) @(posedge clk);
    expect_u32("traced STOP: the trace handler, not the stopped state",
               dut.u_seq.ir_pc, H_TRACE);
    // The status register STOP loaded, and the instruction after it -- the
    // one the processor would have gone on to, exactly as when an interrupt
    // wakes a STOP.
    check_frame("traced STOP", SSP0 - 32'd8, 16'h2700, PC0 + 32'd8, 8'd9);

    // ---- An autovectored interrupt ----------------------------------------
    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h00003A, H_TRAP3);         // autovector 29 is at byte 116
    poke_w(H_TRAP3[23:1], 16'h60FE);
    // Reset leaves the interrupt mask at seven, so the program has to lower
    // it before anything below level seven can get in (UM 5.5, section 6).
    poke_w(23'h000800, 16'h46FC);        // 1000: MOVE #$2000,SR
    poke_w(23'h000801, 16'h2000);
    poke_w(23'h000802, 16'h60FE);        // 1004: branch to self
    iack_auto = 1'b1;
    core_start();
    repeat (40) @(posedge clk);
    ipl_n_i = ~3'd5;                     // level 5
    run_until_pc(H_TRAP3, 800);
    expect_u32("autovector: the mask is raised to the level",
               {29'd0, dut.u_seq.sr[10:8]}, 32'd5);
    check_frame("autovector", SSP0 - 32'd8, 16'h2000, PC0 + 32'd4, 8'd29);
    ipl_n_i = 3'b111;

    // ---- The same, at level seven and with the memory slow -----------------
    //
    // Both halves of this are here because a real machine found the first one
    // and asked about the second. The level matters because seven is the
    // non-maskable one, which is what a monitor's clock uses and so the first
    // interrupt a machine takes; the latency matters because a bus shared with
    // DMA can hold a cycle off for a dozen clocks or more, which nothing else
    // here exercises.
    //
    // Nothing about an autovector should depend on either. doc/bugs-found.md
    // has the acknowledge-termination bug this area hid.
    core_reset();
    mem_waits = 8'd13;
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h00003E, H_TRAP3);         // autovector 31 is at byte 124 = $7C
    poke_w(H_TRAP3[23:1], 16'h60FE);
    poke_w(23'h000800, 16'h60FE);        // 1000: branch to self, mask stays 7
    iack_auto = 1'b1;
    core_start();
    repeat (40) @(posedge clk);
    ipl_n_i = ~3'd7;                     // level 7: taken whatever the mask
    run_until_pc(H_TRAP3, 20000);
    expect_u32("autovector at 13 waits: the mask is raised to seven",
               {29'd0, dut.u_seq.sr[10:8]}, 32'd7);
    check_frame("autovector at 13 waits", SSP0 - 32'd8, 16'h2700, PC0, 8'd31);
    ipl_n_i   = 3'b111;
    mem_waits = 8'd0;

    // ---- A level seven request that stays asserted -------------------------
    //
    // The case a real machine found. A periodic source holds its request at
    // seven until the handler writes to a clear register, which is what UM 3.5
    // tells it to do: "these signals must remain asserted until the processor
    // signals interrupt acknowledge". Recognise that as a level and the
    // acknowledge never ends -- taking it sets the mask to seven, the line is
    // still seven, and the next instruction boundary acknowledges it again,
    // for ever. The handler's first instruction never retires, so the source is
    // never cleared, and the stack walks down through memory until it reaches
    // the vector table and eats it.
    //
    // So: hold the line at seven and check the handler actually runs.
    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h00003E, H_TRAP3);         // autovector 31 at byte $7C
    poke_w(H_TRAP3[23:1],        16'h31FC);  // MOVE.W #$1234,($0900).W
    poke_w(H_TRAP3[23:1] + 23'd1, 16'h1234);
    poke_w(H_TRAP3[23:1] + 23'd2, 16'h0900);
    poke_w(H_TRAP3[23:1] + 23'd3, 16'h60FE);  // then branch to self
    poke_w(23'h000480, 16'h0000);        // $0900 starts clear
    // A sentinel eight bytes below the one frame this should push. A second
    // acknowledge would write its format word straight over it.
    poke_w((SSP0 - 32'd16) >> 1, 16'hA5A5);
    poke_w(23'h000800, 16'h60FE);        // 1000: branch to self
    iack_auto = 1'b1;
    core_start();
    repeat (40) @(posedge clk);
    ipl_n_i = ~3'd7;                     // and it never goes away
    repeat (4000) @(posedge clk);
    expect_u32("level seven held: the handler's first instruction runs",
               {16'd0, mem.peek(23'h000480)}, 32'h0000_1234);
    // One frame, not hundreds. Eight bytes below it must be untouched.
    expect_u32("level seven held: it is acknowledged once, not repeatedly",
               {16'd0, mem.peek((SSP0 - 32'd16) >> 1)}, 32'h0000_A5A5);
    ipl_n_i = 3'b111;

    // ---- A level seven request withdrawn before it can be taken ------------
    //
    // The third bug this area has produced, and again a real machine saw it
    // first: one unexplained vector 24 on a system whose only always-unmasked
    // source is at level seven.
    //
    // `irq7_edge` is cleared in the clocked block but read combinationally, so
    // for one clock it describes a request that has already gone -- and the
    // level latched alongside it is the new one, which is zero. STOP makes that
    // one clock a certainty rather than a race: with no bus cycle in flight
    // every clock retires, and STOP is an interrupt point, so the window cannot
    // be missed.
    //
    // Nothing should happen at all. UM 3.5 requires a device to hold its
    // request until the acknowledge, so a request withdrawn before then is one
    // the processor may forget -- what it may not do is acknowledge a level the
    // request never carried.
    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h000030, H_LINEA);         // autovector 0 would be vector 24, $60
    poke_l(23'h00003E, H_TRAP3);         // autovector 31 at byte $7C
    poke_w(H_LINEA[23:1], 16'h60FE);
    poke_w(H_TRAP3[23:1], 16'h60FE);
    poke_w(23'h000800, 16'h4E72);        // 1000: STOP #$2700, mask stays seven
    poke_w(23'h000801, 16'h2700);
    poke_w(23'h000802, 16'h4AFC);        // 1004: ILLEGAL, never reached
    iack_auto = 1'b1;
    core_start();
    repeat (60) @(posedge clk);
    expect_u32("level seven withdrawn: stopped before the pulse",
               dut.u_seq.ir_pc, PC0);
    // Forget the cycles that got here; from now on any cycle at all is one too
    // many, because a stopped core that ignores a request runs none.
    ntr = 0;
    @(negedge clk); ipl_n_i = ~3'd7;     // exactly one clock at seven
    @(negedge clk); ipl_n_i = 3'b111;
    repeat (200) @(posedge clk);
    expect_int("level seven withdrawn: no acknowledge cycle", ntr, 0);
    expect_u32("level seven withdrawn: still stopped", dut.u_seq.ir_pc, PC0);
    expect_u32("level seven withdrawn: the mask is untouched",
               {29'd0, dut.u_seq.sr[10:8]}, 32'd7);

    // ---- ... and the same, at every phase of an instruction stream ---------
    //
    // The same withdrawal against a running core rather than a stopped one, so
    // the case is not a STOP artefact. The window is one clock and an
    // instruction boundary has to land in it, so the pulse is swept across the
    // loop instead of being placed. The mask is what tells: a level zero taken
    // here sets it to zero.
    for (i = 0; i < 12; i = i + 1) begin
      core_reset();
      poke_l(23'h000000, SSP0);
      poke_l(23'h000002, PC0);
      poke_l(23'h000030, H_LINEA);
      poke_l(23'h00003E, H_TRAP3);
      poke_w(H_LINEA[23:1], 16'h60FE);
      poke_w(H_TRAP3[23:1], 16'h60FE);
      poke_w(23'h000800, 16'h4E71);      // 1000: NOP
      poke_w(23'h000801, 16'h4E71);      // 1002: NOP
      poke_w(23'h000802, 16'h4E71);      // 1004: NOP
      poke_w(23'h000803, 16'h4E71);      // 1006: NOP
      poke_w(23'h000804, 16'h60F6);      // 1008: BRA 1000
      iack_auto = 1'b1;
      core_start();
      repeat (60) @(posedge clk);
      repeat (i)  @(posedge clk);
      @(negedge clk); ipl_n_i = ~3'd7;
      @(negedge clk); ipl_n_i = 3'b111;
      repeat (120) @(posedge clk);
      expect_u32("level seven withdrawn while running: the mask is untouched",
                 {29'd0, dut.u_seq.sr[10:8]}, 32'd7);
    end

    // ---- A level seven request that arrives while the mask is below it -----
    //
    // The companion to the held-at-seven case above, entered the other way. A
    // mask below seven means the *level* term takes the interrupt in the very
    // clock the line first reads seven -- and the edge is set in that same
    // clock, by a priority chain that sets before it clears. The edge then
    // survives into the handler, whose first instruction boundary takes a
    // second interrupt for the same request: two frames, two acknowledges.
    //
    // Checked the way the held-at-seven case is: the handler's store has to
    // happen, and the sentinel eight bytes below the one frame has to survive.
    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h00003E, H_TRAP3);         // autovector 31 at byte $7C
    poke_w(H_TRAP3[23:1],         16'h31FC); // MOVE.W #$1234,($0900).W
    poke_w(H_TRAP3[23:1] + 23'd1, 16'h1234);
    poke_w(H_TRAP3[23:1] + 23'd2, 16'h0900);
    poke_w(H_TRAP3[23:1] + 23'd3, 16'h60FE); // then branch to self
    poke_w(23'h000480, 16'h0000);        // $0900 starts clear
    poke_w((SSP0 - 32'd16) >> 1, 16'hA5A5);
    poke_w(23'h000800, 16'h4E72);        // 1000: STOP #$2000, mask zero
    poke_w(23'h000801, 16'h2000);
    poke_w(23'h000802, 16'h4AFC);        // 1004: ILLEGAL, never reached
    iack_auto = 1'b1;
    core_start();
    repeat (60) @(posedge clk);
    ipl_n_i = ~3'd7;                     // and held, as UM 3.5 requires
    repeat (600) @(posedge clk);
    expect_u32("level seven under a low mask: the handler's first instruction runs",
               {16'd0, mem.peek(23'h000480)}, 32'h0000_1234);
    expect_u32("level seven under a low mask: it is acknowledged once",
               {16'd0, mem.peek((SSP0 - 32'd16) >> 1)}, 32'h0000_A5A5);
    expect_u32("level seven under a low mask: the mask is raised to seven",
               {29'd0, dut.u_seq.sr[10:8]}, 32'd7);
    ipl_n_i = 3'b111;

    // ---- A vectored interrupt ---------------------------------------------
    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h000080, H_LINEA);         // vector 64 is at byte 256
    poke_w(H_LINEA[23:1], 16'h60FE);
    poke_w(23'h000800, 16'h46FC);        // 1000: MOVE #$2000,SR
    poke_w(23'h000801, 16'h2000);
    poke_w(23'h000802, 16'h60FE);        // 1004: branch to self
    iack_auto   = 1'b0;
    iack_vector = 8'd64;
    core_start();
    repeat (40) @(posedge clk);
    ipl_n_i = ~3'd4;
    run_until_pc(H_LINEA, 800);
    check_frame("vectored interrupt", SSP0 - 32'd8, 16'h2000, PC0 + 32'd4,
                8'd64);
    ipl_n_i = 3'b111;

    // ---- STOP waits, and an interrupt is what wakes it --------------------
    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h00003A, H_TRAP3);         // autovector 29
    poke_w(H_TRAP3[23:1], 16'h60FE);
    poke_w(23'h000800, 16'h4E72);        // 1000: STOP #$2000
    poke_w(23'h000801, 16'h2000);
    poke_w(23'h000802, 16'h4AFC);        // 1004: ILLEGAL, never reached
    iack_auto = 1'b1;
    core_start();
    repeat (60) @(posedge clk);
    expect_u32("STOP: the status register was loaded",
               {16'd0, dut.u_seq.sr}, 32'h0000_2000);
    expect_u32("STOP: nothing after it has run", dut.u_seq.ir_pc, PC0);
    ipl_n_i = ~3'd5;
    run_until_pc(H_TRAP3, 800);
    // The stacked program counter is the instruction after STOP, which is
    // where execution would have gone had it not stopped.
    check_frame("STOP woken", SSP0 - 32'd8, 16'h2000, PC0 + 32'd4, 8'd29);
    ipl_n_i = 3'b111;

    // ---- The stack a user-mode exception uses ------------------------------
    //
    // UM 6.2.5 puts the two halves of this in different steps. In the first,
    // "an internal copy is made of the status register. After the copy is made,
    // the S bit of the status register is set"; in the third, "the current
    // program counter value and the saved copy of the status register are
    // stacked using the SSP". So an exception taken in user mode moves the
    // supervisor stack pointer and leaves the user one exactly where it was,
    // and the status register in the frame is the one from before the S bit
    // went up.
    //
    // Every other test in this file starts in supervisor mode, where the two
    // pointers are the same pointer and the rule says nothing. This one gives
    // them different values and checks which one moved.
    user_mode_trap(16'h60FE);            // the handler parks, so the frame sits
    run_until_pc(H_TRAP3, 800);
    expect_u32("user-mode TRAP: supervisor mode entered",
               {31'd0, dut.u_seq.sr[13]}, 32'd1);
    expect_u32("user-mode TRAP: the supervisor stack moved",
               dut.u_seq.ssp, SSP0 - 32'd8);
    expect_u32("user-mode TRAP: the user stack pointer did not",
               dut.u_seq.usp, USP0);
    check_frame("user-mode TRAP", SSP0 - 32'd8, 16'h0700, PC0 + 32'd14, 8'd35);
    // A frame written to the wrong stack would have landed on these.
    for (i = 0; i < 4; i = i + 1)
      expect_u32("user-mode TRAP: nothing written under the user stack",
                 {16'd0, mem.peek(23'((USP0 - 32'd8) >> 1) + 23'(i))},
                 32'h0000_A5A5);

    // ---- ... and RTE hands it back ----------------------------------------
    // UM 6.1.3 names RTE as one of the four ways back to user mode. The S bit
    // comes out of the frame, so A7 becomes the user stack pointer again --
    // which is still where the program left it.
    user_mode_trap(16'h4E73);            // the handler is an RTE
    run_until_pc(PC0 + 32'd14, 1200);
    expect_u32("user-mode TRAP: RTE returns to user mode",
               {31'd0, dut.u_seq.sr[13]}, 32'd0);
    expect_u32("user-mode TRAP: the supervisor stack is back",
               dut.u_seq.ssp, SSP0);
    expect_u32("user-mode TRAP: and the user stack never moved",
               dut.u_seq.usp, USP0);

    // ---- ... and so does an interrupt --------------------------------------
    // The report that prompted these checks said every exception taken from
    // user mode was affected. An interrupt reaches the shared frame tail by a
    // different door -- the mask goes up alongside the S bit, from a different
    // microword -- so it gets its own case rather than being argued from the
    // TRAP one.
    core_reset();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_l(23'h00003A, H_AUTO5);         // vector 29, the level five autovector
    poke_w(H_AUTO5[23:1], 16'h60FE);
    //  1000: MOVEA.L #$00005000,A0
    //  1006: MOVE    A0,USP
    //  1008: MOVE    #$0000,SR          user mode, and the mask down to zero
    //  100C: BRA     self               where the interrupt finds it
    poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, USP0);
    poke_w(23'h000803, 16'h4E60);
    poke_w(23'h000804, 16'h46FC);  poke_w(23'h000805, 16'h0000);
    poke_w(23'h000806, 16'h60FE);
    for (i = 0; i < 4; i = i + 1)
      poke_w(23'((USP0 - 32'd8) >> 1) + 23'(i), 16'hA5A5);
    iack_auto = 1'b1;
    core_start();
    run_until_pc(PC0 + 32'd12, 400);     // in user mode, and spinning
    ipl_n_i = ~3'd5;
    run_until_pc(H_AUTO5, 800);
    ipl_n_i = 3'b111;
    expect_u32("user-mode interrupt: the supervisor stack moved",
               dut.u_seq.ssp, SSP0 - 32'd8);
    expect_u32("user-mode interrupt: the user stack pointer did not",
               dut.u_seq.usp, USP0);
    check_frame("user-mode interrupt", SSP0 - 32'd8, 16'h0000,
                PC0 + 32'd12, 8'd29);
    for (i = 0; i < 4; i = i + 1)
      expect_u32("user-mode interrupt: nothing written under the user stack",
                 {16'd0, mem.peek(23'((USP0 - 32'd8) >> 1) + 23'(i))},
                 32'h0000_A5A5);

    core_done("core_exception_tb");
  end

endmodule
