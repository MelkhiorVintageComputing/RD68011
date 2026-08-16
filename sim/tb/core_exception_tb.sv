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

    core_done("core_exception_tb");
  end

endmodule
