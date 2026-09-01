// A reproducer for a field report: "An address error on a byte move, in libc's
// strncpy". Reported against a Sun-2/50 replica on a MAX 10 running SunOS
// 4.0.3, where three unrelated programs die with SIGBUS -- which on that kernel
// means T_ADDRERR and nothing else -- at the same instruction in libc's
// strncpy, with both operands odd on the loop's second pass.
//
// The loop is copied from the report's disassembly of libc.so.0.12, opcode for
// opcode, including the detail that matters: it is entered at the DBEQ and not
// at the MOVE, so the first thing executed is the decrement and branch.
//
//     5dfc:  2008           movel  %a0,%d0
//     5dfe:  6002           bras   0x5e02
//     5e00:  10d9           moveb  %a1@+,%a0@+
//     5e02:  57c9 fffc      dbeq   %d1,0x5e00
//
// The displacement is minus four and MOVE.B (Ay)+,(Ax)+ is in table A-1, so
// this is also a loop mode loop: the copy runs with no instruction fetches at
// all, which is the state the fault would have been taken in.
//
// The two controls are the point of the file as much as the sweep is. A null
// result proves nothing about a handler that was never going to fire, so:
//
//   * a *word* read at an odd address must reach vector 3, and
//   * a *byte* read at an odd address must not.
//
// Without both, "no fault" is indistinguishable from "no handler".
//
// What this cannot reproduce, and the report says so itself: anything about
// which *pages* are involved. There is no MMU here and one flat memory, so a
// trigger that depends on translation is out of reach. Address bit 23 is out of
// reach too -- the model does not answer above 8 MB -- so the reported operands
// are run with A23 cleared and every other address bit as reported.

`timescale 1ns/1ps

module core_strncpy_tb;

`include "rd68011_core_harness.svh"

  localparam logic [31:0] SSP0    = 32'h0000_3000;
  localparam logic [31:0] PC0     = 32'h0000_1000;
  localparam logic [31:0] H_BERR  = 32'h0000_2000;   // vector 2
  localparam logic [31:0] H_AERR  = 32'h0000_2100;   // vector 3
  localparam logic [31:0] H_ILL   = 32'h0000_2200;   // vector 4, in case
  localparam logic [31:0] H_IRQ   = 32'h0000_2300;   // any autovector
  localparam logic [31:0] MARK    = 32'h0000_0600;   // which one fired

  // The reported operands, with address bit 23 cleared so the memory model
  // answers: every other bit is as the Sun-2 had it.
  localparam logic [31:0] SUN_SRC = 32'h00dd_8898 & 32'h007F_FFFF;
  localparam logic [31:0] SUN_DST = 32'h0002_0fe6;

  int i, j, n;
  int faults;

  // Loop mode has to be running, or this is not the loop that was reported.
  // The displacement is minus four and MOVE.B (Ay)+,(Ax)+ is in table A-1, so
  // it should be -- but "should be" is what a monitor is for.
  logic saw_loop;
  always @(posedge clk) if (rst_n && dut.u_seq.loop_active) saw_loop <= 1'b1;

  // Non-zero to have an interrupt arrive that many clocks into the run. The
  // Sun-2 has a 100 Hz clock and the report's machine was multi-user, so the
  // copy was being interrupted; loop mode leaving and re-entering around an
  // exception is the interaction most likely to leave the program counter
  // somewhere it should not be, and an odd one is an address error on the very
  // next instruction fetch.
  int irq_at;

  function automatic logic [7:0] peek_b(input logic [31:0] a);
    logic [15:0] w;
    begin
      w = mem.peek(a[23:1]);
      peek_b = a[0] ? w[7:0] : w[15:8];
    end
  endfunction

  function automatic int mark();
    mark = int'(mem.peek(MARK[23:1]));
  endfunction

  // Run until the program says it is done or a handler says it is not.
  task automatic run_prog(input string what, input logic [31:0] done_pc,
                          input int limit);
    int k;
    begin
      k = 0;
      while ((dut.u_seq.ir_pc !== done_pc) && (mark() == 0) && (k < limit)) begin
        @(posedge clk);
        k = k + 1;
      end
      if ((dut.u_seq.ir_pc !== done_pc) && (mark() == 0)) begin
        $display("FAIL: %s: neither finished nor faulted after %0d clocks \
(ir_pc %08h)", what, limit, dut.u_seq.ir_pc);
        errors = errors + 1;
      end
    end
  endtask

  // Everything every case needs: vectors, three distinguishable handlers, and
  // the mark cleared. Each handler records its number and stops.
  task automatic groundwork();
    begin
      core_reset();
      poke_l(23'h000000, SSP0);
      poke_l(23'h000002, PC0);
      poke_l(23'h000004, H_BERR);          // vector 2, bus error
      poke_l(23'h000006, H_AERR);          // vector 3, address error
      poke_l(23'h000008, H_ILL);           // vector 4, illegal instruction
      for (j = 25; j <= 31; j = j + 1) begin
        poke_l(23'(j) * 23'd2, H_IRQ);     // the autovectors, which just return
      end
      poke_w(H_IRQ[23:1], 16'h4E73);       // RTE
      saw_loop = 1'b0;
      poke_w(MARK[23:1], 16'd0);
      // MOVE.W #k,($0600).W ; BRA *
      poke_w(H_BERR[23:1] + 23'd0, 16'h31FC);
      poke_w(H_BERR[23:1] + 23'd1, 16'd2);
      poke_w(H_BERR[23:1] + 23'd2, MARK[15:0]);
      poke_w(H_BERR[23:1] + 23'd3, 16'h60FE);
      poke_w(H_AERR[23:1] + 23'd0, 16'h31FC);
      poke_w(H_AERR[23:1] + 23'd1, 16'd3);
      poke_w(H_AERR[23:1] + 23'd2, MARK[15:0]);
      poke_w(H_AERR[23:1] + 23'd3, 16'h60FE);
      poke_w(H_ILL[23:1]  + 23'd0, 16'h31FC);
      poke_w(H_ILL[23:1]  + 23'd1, 16'd4);
      poke_w(H_ILL[23:1]  + 23'd2, MARK[15:0]);
      poke_w(H_ILL[23:1]  + 23'd3, 16'h60FE);
    end
  endtask

  // If something did fire, say everything the frame knows -- the report asks
  // specifically whether the stacked PC names the instruction that faulted.
  task automatic dump_frame(input string what);
    logic [31:0] sp;
    begin
      sp = dut.u_seq.ssp;
      $display("      %s: vector %0d, frame at %08h: sr=%04h pc=%08h \
fmt/off=%04h ssw=%04h fault addr=%08h", what, mark(), sp,
               mem.peek(sp[23:1]),
               {mem.peek((sp + 32'd2) >> 1), mem.peek((sp + 32'd4) >> 1)},
               mem.peek((sp + 32'd6) >> 1), mem.peek((sp + 32'd8) >> 1),
               {mem.peek((sp + 32'd10) >> 1), mem.peek((sp + 32'd12) >> 1)});
    end
  endtask

  // ---------------------------------------------------------------------------
  // The loop, exactly as libc has it.
  //
  //   1000  MOVEA.L #dst,A0
  //   1006  MOVEA.L #src,A1
  //   100C  MOVE.L  #n,D1
  //   1012  MOVE.L  A0,D0
  //   1014  BRA.S   1018            <- enter at the DBEQ, as libc does
  //   1016  MOVE.B  (A1)+,(A0)+
  //   1018  DBEQ    D1,1016
  //   101C  BRA     *
  // ---------------------------------------------------------------------------
  localparam logic [31:0] DONE = 32'h0000_101C;

  task automatic strncpy_case(input string what, input logic [31:0] dst,
                              input logic [31:0] src, input int nbytes);
    begin
      groundwork();
      // Source bytes, none of them zero, so the count is the counter's and not
      // the terminator's.
      for (j = 0; j < 24; j = j + 1) begin
        poke_w((src + 32'(j) * 32'd2) >> 1, 16'(16'h4152 + 16'(j) * 16'h0101));
      end
      for (j = 0; j < 24; j = j + 1) poke_w((dst >> 1) + 23'(j), 16'hFFFF);

      poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, dst);
      poke_w(23'h000803, 16'h227C);  poke_l(23'h000804, src);
      poke_w(23'h000806, 16'h223C);  poke_l(23'h000807, 32'(nbytes));
      poke_w(23'h000809, 16'h2008);
      poke_w(23'h00080A, 16'h6002);
      poke_w(23'h00080B, 16'h10D9);
      poke_w(23'h00080C, 16'h57C9);  poke_w(23'h00080D, 16'hFFFC);
      poke_w(23'h00080E, 16'h60FE);

      core_start();
      // Sequentially rather than in a fork: iverilog aborts on a join_none
      // inside an automatic task, and there is nothing to run in parallel with
      // anyway -- the wait below is the same wait run_prog would be doing.
      if (irq_at > 0) begin
        repeat (irq_at) @(posedge clk);
        ipl_n_i = ~3'd5;
        repeat (4) @(posedge clk);
        ipl_n_i = 3'b111;
      end
      run_prog(what, DONE, 4000);
      ipl_n_i = 3'b111;

      if (!saw_loop) begin
        $display("FAIL: %s: loop mode never ran, so this is not the loop that was reported", what);
        errors = errors + 1;
      end

      if (mark() != 0) begin
        $display("FAIL: %s: vector %0d was taken", what, mark());
        dump_frame(what);
        errors = errors + 1;
        faults = faults + 1;
      end else begin
        // It ran; check it copied what it should, so a case that silently did
        // nothing cannot pass as a case that did not fault.
        for (j = 0; j < nbytes; j = j + 1) begin
          if (peek_b(dst + 32'(j)) !== peek_b(src + 32'(j))) begin
            $display("FAIL: %s: byte %0d is %02h, expected %02h", what, j,
                     peek_b(dst + 32'(j)), peek_b(src + 32'(j)));
            errors = errors + 1;
          end
        end
        if (peek_b(dst + 32'(nbytes)) !== 8'hFF) begin
          $display("FAIL: %s: it wrote one byte too many", what);
          errors = errors + 1;
        end
      end
    end
  endtask

  initial begin
    errors = 0;
    faults = 0;
    irq_at = 0;

    // ======================================================================
    // Control one: a word read at an odd address MUST take vector 3
    // ======================================================================
    groundwork();
    poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, 32'h0000_4001);
    poke_w(23'h000803, 16'h3010);              // MOVE.W (A0),D0
    poke_w(23'h000804, 16'h60FE);
    core_start();
    run_prog("control: word read at an odd address", 32'h0000_1008, 900);
    expect_int("control: a word read at an odd address is an address error",
               mark(), 3);

    // ======================================================================
    // Control two: a byte read at an odd address MUST NOT
    // ======================================================================
    groundwork();
    poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, 32'h0000_4001);
    poke_w(23'h000803, 16'h1010);              // MOVE.B (A0),D0
    poke_w(23'h000804, 16'h60FE);
    core_start();
    run_prog("control: byte read at an odd address", 32'h0000_1008, 900);
    expect_int("control: a byte read at an odd address is not",
               mark(), 0);

    // ======================================================================
    // The case in the report: strncpy(dest, src, 12), both even on entry,
    // so both operands are odd from the second pass onwards
    // ======================================================================
    strncpy_case("the reported call, even to even, n=12",
                 32'h0000_5000, 32'h0000_4000, 12);

    // ... and with the operands the Sun-2 actually had, every address bit as
    // reported except the one this memory cannot answer.
    strncpy_case("the reported operands", SUN_DST, SUN_SRC, 12);

    // ======================================================================
    // The sweep the report asks for: four entry alignments, n from 1 to 16
    // ======================================================================
    for (i = 0; i < 4; i = i + 1) begin
      for (n = 1; n <= 16; n = n + 1) begin
        strncpy_case($sformatf("sweep dst%s src%s n=%0d",
                               i[1] ? "+1" : "  ", i[0] ? "+1" : "  ", n),
                     32'h0000_5000 + 32'(i[1]), 32'h0000_4000 + 32'(i[0]), n);
      end
    end

    // ======================================================================
    // The same, with the two operands far apart in the address space
    // ======================================================================
    for (i = 0; i < 4; i = i + 1) begin
      strncpy_case($sformatf("far apart dst%s src%s",
                             i[1] ? "+1" : "  ", i[0] ? "+1" : "  "),
                   32'h0000_0700 + 32'(i[1]), 32'h0000_7000 + 32'(i[0]), 12);
    end

    // ======================================================================
    // The same loop, interrupted at every point in it
    //
    // Loop mode has to leave and re-enter around the exception, and the copy
    // has to come out right anyway. This is swept a clock at a time because the
    // interesting instants are one clock wide.
    // ======================================================================
    for (i = 40; i <= 200; i = i + 1) begin
      irq_at = i;
      strncpy_case($sformatf("interrupted at clock %0d", i),
                   32'h0000_5000, 32'h0000_4000, 16);
    end
    irq_at = 0;

    $display("  strncpy reproducer: %0d cases, %0d took an exception",
             2 + 4 * 16 + 4 + 161, faults);
    core_done("core_strncpy_tb");
  end

endmodule
