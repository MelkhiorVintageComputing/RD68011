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
// A second report followed, with a bus-level capture: the same instruction
// takes vector 3 with *no cycle issued for it at all*, and the discriminator is
// that the loop must be **re-entered by RTE** after an exception. Two resume
// paths can do that and they share almost nothing in this design, so both are
// here:
//
//   * a short frame, from an interrupt taken at an instruction boundary, which
//     comes back through DECODE. The loop must be running in *user* mode for
//     this to be the reported case, because the RTE then changes the supervisor
//     bit on the way out;
//   * a long frame, from a bus error on the copy's own access -- a page the
//     memory subsystem has not allocated -- which comes back through RESUME and
//     `upc_save` and re-executes the faulted microword. This is the one the
//     machine actually takes: the handler allocates the page, updates the MMU
//     and returns, the rerun flag clear, so the access is retried.
//
// The second is the harder path and the one every instruction-restart defect
// this project has found has been on, so its handler behaves like a real one --
// it saves every register and writes and reads back through -(An) before the
// RTE, rather than being an RTE with a counter in front of it.
//
// What this cannot reproduce: anything about which *pages* are involved. There
// is no MMU here and one flat memory, so a trigger that depends on translation
// is out of reach. Address bit 23 is out of reach too -- the model does not
// answer above 8 MB -- so the reported operands are run with A23 cleared and
// every other address bit as reported. Nothing in the address-error decision
// reads a bit above A0 (`n_addr_err` in rtl/rd68011_seq.sv), so that gap is
// narrower than it looks.

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
  localparam logic [31:0] IRQN    = 32'h0000_0602;   // how many interrupts ran
  localparam logic [31:0] USP0    = 32'h0000_6000;
  localparam logic [31:0] BERRN   = 32'h0000_0604;   // page faults handled

  // The reported operands, with address bit 23 cleared so the memory model
  // answers: every other bit is as the Sun-2 had it.
  localparam logic [31:0] SUN_SRC = 32'h00dd_8898 & 32'h007F_FFFF;
  localparam logic [31:0] SUN_DST = 32'h0002_0fe6;

  int i, j, n, kk;
  int faults;

  // Loop mode has to be running, or this is not the loop that was reported.
  // The displacement is minus four and MOVE.B (Ay)+,(Ax)+ is in table A-1, so
  // it should be -- but "should be" is what a monitor is for.
  logic saw_loop;
  always @(posedge clk) if (rst_n && dut.u_seq.loop_active) saw_loop <= 1'b1;

  // Whether a page fault was taken *while loop mode was running*, which is the
  // state the report's machine was in: the format $8 frame then carries the
  // looped instruction and the two loop-state bits at SP+56, and RTE has to put
  // them back. A sweep whose faults all landed outside loop mode would be
  // testing a simpler path than the reported one.
  logic saw_loop_fault;
  always @(posedge clk) begin
    if (rst_n && dut.u_seq.fault && dut.u_seq.loop_active) saw_loop_fault <= 1'b1;
  end

  // Non-zero to have an interrupt arrive that many clocks into the run. The
  // Sun-2 has a 100 Hz clock and the report's machine was multi-user, so the
  // copy was being interrupted; loop mode leaving and re-entering around an
  // exception is the interaction most likely to leave the program counter
  // somewhere it should not be, and an odd one is an address error on the very
  // next instruction fetch.
  int irq_at;

  // Where the interrupt actually landed, and what the operands were when it
  // did. A sweep that always interrupted before the loop started, or after it
  // finished, would pass while testing nothing, so this is counted and the run
  // fails if the count is zero.
  logic [31:0] irq_pc, irq_a0, irq_a1;
  logic        irq_seen;
  always @(posedge clk) begin
    if (rst_n && dut.u_seq.commit && dut.u_seq.take_irq) begin
      irq_pc   <= dut.u_seq.ir_pc;
      irq_a0   <= dut.u_seq.regs[8];
      irq_a1   <= dut.u_seq.regs[9];
      irq_seen <= 1'b1;
    end
  end

  int resumed_in_loop, resumed_both_odd, resumed_after_berr;
  int resumed_in_loop_mode;

  // Memory latency. The machine in the report runs at 16.667 MHz against real
  // memory on a shared VME bus, and an earlier report from it is the reason
  // `make programs WAITS=13` exists at all -- a saturated bus can hold a cycle
  // off for a dozen clocks. A resume bug that needs the exception to land
  // inside a stretched cycle would be invisible at zero waits.
  int wait_states;

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
      mem_waits = 8'(wait_states);
      poke_l(23'h000000, SSP0);
      poke_l(23'h000002, PC0);
      poke_l(23'h000004, H_BERR);          // vector 2, bus error
      poke_l(23'h000006, H_AERR);          // vector 3, address error
      poke_l(23'h000008, H_ILL);           // vector 4, illegal instruction
      for (j = 25; j <= 31; j = j + 1) begin
        poke_l(23'(j) * 23'd2, H_IRQ);     // the autovectors, which just return
      end
      // Count the interrupts and return. The count is what proves a case that
      // was supposed to be interrupted actually was.
      poke_w(H_IRQ[23:1] + 23'd0, 16'h5278);          // ADDQ.W #1,($0602).W
      poke_w(H_IRQ[23:1] + 23'd1, IRQN[15:0]);
      poke_w(H_IRQ[23:1] + 23'd2, 16'h4E73);          // RTE
      poke_w(IRQN[23:1], 16'd0);
      poke_w(BERRN[23:1], 16'd0);
      saw_loop = 1'b0;
      saw_loop_fault = 1'b0;
      irq_seen = 1'b0;
      irq_pc   = 32'd0;
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

  // ---------------------------------------------------------------------------
  // The same loop, in user mode, interrupted and resumed by RTE
  //
  // This is the shape the second report names, and the one the first sweep did
  // not have: the loop runs in *user* mode, so the exception that lands in it
  // changes the supervisor bit going in and the RTE changes it back coming out.
  // The captured trace shows exactly that -- a short frame popped by the
  // kernel's `rei`, one iteration executed correctly at even addresses, and
  // then vector 3 with no bus cycle for the odd pair.
  //
  //   1000  MOVEA.L #USP0,A0
  //   1006  MOVE.L  A0,USP
  //   1008  MOVE    #$0000,SR      <- user mode, interrupts unmasked
  //   100C  MOVEA.L #dst,A0
  //   1012  MOVEA.L #src,A1
  //   1018  MOVE.L  #n,D1
  //   101E  MOVE.L  A0,D0
  //   1020  BRA.S   1024
  //   1022  MOVE.B  (A1)+,(A0)+
  //   1024  DBEQ    D1,1022
  //   1028  BRA     *
  // ---------------------------------------------------------------------------
  localparam logic [31:0] UDONE = 32'h0000_1028;

  task automatic strncpy_user_case(input string what, input logic [31:0] dst,
                                   input logic [31:0] src, input int nbytes);
    begin
      groundwork();
      for (j = 0; j < 24; j = j + 1) begin
        poke_w((src + 32'(j) * 32'd2) >> 1, 16'(16'h4152 + 16'(j) * 16'h0101));
      end
      for (j = 0; j < 24; j = j + 1) poke_w((dst >> 1) + 23'(j), 16'hFFFF);

      poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, USP0);
      poke_w(23'h000803, 16'h4E60);              // MOVE.L A0,USP
      poke_w(23'h000804, 16'h46FC);  poke_w(23'h000805, 16'h0000);
      poke_w(23'h000806, 16'h207C);  poke_l(23'h000807, dst);
      poke_w(23'h000809, 16'h227C);  poke_l(23'h00080A, src);
      poke_w(23'h00080C, 16'h223C);  poke_l(23'h00080D, 32'(nbytes));
      poke_w(23'h00080F, 16'h2008);
      poke_w(23'h000810, 16'h6002);
      poke_w(23'h000811, 16'h10D9);
      poke_w(23'h000812, 16'h57C9);  poke_w(23'h000813, 16'hFFFC);
      poke_w(23'h000814, 16'h60FE);

      core_start();
      // Held until it is acknowledged, which is what UM 3.5 requires of a
      // device and what makes the arrival point sweepable: a pulse a few clocks
      // wide is missed unless it happens to straddle a point where the core
      // will look, and in loop mode it only looks at one phase of the loop.
      if (irq_at > 0) begin
        repeat (irq_at) @(posedge clk);
        ipl_n_i = ~3'd5;
        kk = 0;
        while ((mem.peek(IRQN[23:1]) == 16'd0) && (kk < 600)) begin
          @(posedge clk);
          kk = kk + 1;
        end
        ipl_n_i = 3'b111;
      end
      run_prog(what, UDONE, 6000);
      ipl_n_i = 3'b111;

      if (mark() != 0) begin
        $display("FAIL: %s: vector %0d was taken", what, mark());
        dump_frame(what);
        errors = errors + 1;
        faults = faults + 1;
      end else begin
        if ((irq_at > 0) && (mem.peek(IRQN[23:1]) == 16'd0)) begin
          $display("FAIL: %s: no interrupt was taken, so nothing was resumed",
                   what);
          errors = errors + 1;
        end
        if (!saw_loop) begin
          $display("FAIL: %s: loop mode never ran", what);
          errors = errors + 1;
        end
        // 1022 is the MOVE.B and 1024 the DBEQ, so either means the RTE
        // resumed the loop rather than something before or after it.
        if (irq_seen && ((irq_pc == 32'h0000_1022) ||
                         (irq_pc == 32'h0000_1024))) begin
          resumed_in_loop = resumed_in_loop + 1;
          if (irq_a0[0] && irq_a1[0]) resumed_both_odd = resumed_both_odd + 1;
        end
        for (j = 0; j < nbytes; j = j + 1) begin
          if (peek_b(dst + 32'(j)) !== peek_b(src + 32'(j))) begin
            $display("FAIL: %s: byte %0d is %02h, expected %02h", what, j,
                     peek_b(dst + 32'(j)), peek_b(src + 32'(j)));
            errors = errors + 1;
          end
        end
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // The loop resumed by RTE out of a *format $8* frame, after a page fault
  //
  // This is the real shape, and it is not the one above. The exception that
  // lands in the loop on the reported machine is a bus error on the destination
  // write -- a page the external memory subsystem has not allocated. The kernel
  // allocates it, updates the MMU, and returns with RTE; the rerun flag is
  // clear, so the *access is retried* and the faulted microword re-executes.
  // That is instruction continuation, not a return to an instruction boundary,
  // and the two share almost nothing in this design: the short frame comes back
  // through DECODE, the long one through RESUME and `upc_save`.
  //
  // The trace in the report fits that exactly once it is read this way -- after
  // the RTE both halves of the *retried* iteration appear on the bus, the read
  // at the even source and the write at the even destination, and only then the
  // odd pair goes missing.
  //
  // Here the page fault is a bus error on one destination word, cleared from
  // outside once it has been taken, which is what the handler allocating a page
  // amounts to as far as the core can tell.
  // ---------------------------------------------------------------------------
  task automatic strncpy_berr_case(input string what, input logic [31:0] dst,
                                   input logic [31:0] src, input int nbytes,
                                   input logic [31:0] fault_at);
    begin
      groundwork();
      // A page-fault handler that behaves like one. Two instructions and an
      // RTE would restore almost nothing, and every instruction-restart defect
      // this project has found was found by a handler doing real work -- the
      // address output buffer destroyed by the handler's own accesses, the
      // predecrement write that did not restart. So this one saves every
      // register, writes a long, a word and two bytes through -(An), reads a
      // long back the same way, and restores.
      //
      //   ADDQ.W  #1,($0604).W
      //   MOVEM.L D0-D7/A0-A6,-(A7)
      //   MOVEA.L #scratch+32,A0
      //   MOVE.L  #$12345678,D1
      //   MOVE.L  D1,-(A0)
      //   MOVE.W  D1,-(A0)
      //   MOVE.B  D1,-(A0)
      //   MOVE.B  D1,-(A0)
      //   MOVE.L  -(A0),D0
      //   MOVEM.L (A7)+,D0-D7/A0-A6
      //   RTE
      poke_w(H_BERR[23:1] + 23'd0,  16'h5278);
      poke_w(H_BERR[23:1] + 23'd1,  BERRN[15:0]);
      poke_w(H_BERR[23:1] + 23'd2,  16'h48E7);
      poke_w(H_BERR[23:1] + 23'd3,  16'hFFFE);
      poke_w(H_BERR[23:1] + 23'd4,  16'h207C);
      poke_l(H_BERR[23:1] + 23'd5,  32'h0000_6820);
      poke_w(H_BERR[23:1] + 23'd7,  16'h223C);
      poke_l(H_BERR[23:1] + 23'd8,  32'h1234_5678);
      poke_w(H_BERR[23:1] + 23'd10, 16'h2101);
      poke_w(H_BERR[23:1] + 23'd11, 16'h3101);
      poke_w(H_BERR[23:1] + 23'd12, 16'h1101);
      poke_w(H_BERR[23:1] + 23'd13, 16'h1101);
      poke_w(H_BERR[23:1] + 23'd14, 16'h2020);
      poke_w(H_BERR[23:1] + 23'd15, 16'h4CDF);
      poke_w(H_BERR[23:1] + 23'd16, 16'h7FFF);
      poke_w(H_BERR[23:1] + 23'd17, 16'h4E73);
      for (j = 0; j < 24; j = j + 1) begin
        poke_w((src + 32'(j) * 32'd2) >> 1, 16'(16'h4152 + 16'(j) * 16'h0101));
      end
      for (j = 0; j < 24; j = j + 1) poke_w((dst >> 1) + 23'(j), 16'hFFFF);

      poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, USP0);
      poke_w(23'h000803, 16'h4E60);
      poke_w(23'h000804, 16'h46FC);  poke_w(23'h000805, 16'h0000);
      poke_w(23'h000806, 16'h207C);  poke_l(23'h000807, dst);
      poke_w(23'h000809, 16'h227C);  poke_l(23'h00080A, src);
      poke_w(23'h00080C, 16'h223C);  poke_l(23'h00080D, 32'(nbytes));
      poke_w(23'h00080F, 16'h2008);
      poke_w(23'h000810, 16'h6002);
      poke_w(23'h000811, 16'h10D9);
      poke_w(23'h000812, 16'h57C9);  poke_w(23'h000813, 16'hFFFC);
      poke_w(23'h000814, 16'h60FE);

      berr_addr = fault_at[23:1];
      berr_en   = 1'b1;
      core_start();
      // The page is "allocated" as soon as the fault has been taken once, so
      // the retried access succeeds -- exactly what the handler does.
      kk = 0;
      while ((berr_count == 0) && (kk < 900)) begin
        @(posedge clk);
        kk = kk + 1;
      end
      berr_en = 1'b0;
      run_prog(what, UDONE, 6000);

      if (mark() != 0) begin
        $display("FAIL: %s: vector %0d was taken", what, mark());
        dump_frame(what);
        errors = errors + 1;
        faults = faults + 1;
      end else begin
        if (mem.peek(BERRN[23:1]) == 16'd0) begin
          $display("FAIL: %s: no page fault was taken, so nothing was resumed",
                   what);
          errors = errors + 1;
        end else begin
          resumed_after_berr = resumed_after_berr + 1;
          if (saw_loop_fault) resumed_in_loop_mode = resumed_in_loop_mode + 1;
        end
        for (j = 0; j < nbytes; j = j + 1) begin
          if (peek_b(dst + 32'(j)) !== peek_b(src + 32'(j))) begin
            $display("FAIL: %s: byte %0d is %02h, expected %02h", what, j,
                     peek_b(dst + 32'(j)), peek_b(src + 32'(j)));
            errors = errors + 1;
          end
        end
      end
      berr_en = 1'b0;
    end
  endtask

  initial begin
    errors = 0;
    faults = 0;
    irq_at = 0;
    wait_states = 0;
    resumed_in_loop  = 0;
    resumed_both_odd = 0;
    resumed_after_berr = 0;
    resumed_in_loop_mode = 0;

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

    // ======================================================================
    // In user mode, interrupted and resumed by RTE -- the second report
    //
    // Every clock across the loop, so the exception lands before the MOVE,
    // between it and the DBEQ, and inside the DBEQ, at all four alignments and
    // with the operands the Sun-2 had.
    // ======================================================================
    for (i = 60; i <= 300; i = i + 1) begin
      irq_at = i;
      strncpy_user_case($sformatf("user, interrupted at clock %0d", i),
                        32'h0000_5000, 32'h0000_4000, 12);
    end
    for (i = 60; i <= 300; i = i + 1) begin
      irq_at = i;
      strncpy_user_case($sformatf("user, reported operands, interrupted at %0d",
                                  i), SUN_DST, SUN_SRC, 12);
    end
    for (j = 0; j < 4; j = j + 1) begin
      for (i = 60; i <= 220; i = i + 1) begin
        irq_at = i;
        strncpy_user_case($sformatf("user dst%s src%s interrupted at %0d",
                                    j[1] ? "+1" : "  ", j[0] ? "+1" : "  ", i),
                          32'h0000_5000 + 32'(j[1]), 32'h0000_4000 + 32'(j[0]),
                          12);
      end
    end
    irq_at = 0;

    // ======================================================================
    // The same, against slower memory
    //
    // Every cycle stretched, so the exception lands at points in the transfer
    // that zero waits cannot produce at all.
    // ======================================================================
    for (n = 1; n <= 4; n = n + 1) begin
      wait_states = n;
      for (i = 60; i <= 340; i = i + 2) begin
        irq_at = i;
        strncpy_user_case($sformatf("user, %0d waits, interrupted at %0d", n, i),
                          SUN_DST, SUN_SRC, 12);
      end
    end
    wait_states = 0;
    irq_at = 0;

    // ======================================================================
    // A page fault on every destination word in turn, at every alignment
    // ======================================================================
    for (j = 0; j < 4; j = j + 1) begin
      for (i = 0; i < 6; i = i + 1) begin
        strncpy_berr_case($sformatf("page fault at dst word %0d, dst%s src%s",
                                    i, j[1] ? "+1" : "  ", j[0] ? "+1" : "  "),
                          32'h0000_5000 + 32'(j[1]), 32'h0000_4000 + 32'(j[0]),
                          12, 32'h0000_5000 + 32'(i) * 32'd2);
      end
    end
    // ... and with the operands the Sun-2 had.
    for (i = 0; i < 6; i = i + 1) begin
      strncpy_berr_case($sformatf("page fault, reported operands, dst word %0d",
                                  i), SUN_DST, SUN_SRC, 12,
                        SUN_DST + 32'(i) * 32'd2);
    end
    // ... on the source read rather than the destination write, since the
    // report says "on the destination probably" and probably is not measured.
    for (j = 0; j < 4; j = j + 1) begin
      for (i = 0; i < 6; i = i + 1) begin
        strncpy_berr_case($sformatf("page fault on the source, word %0d, dst%s src%s",
                                    i, j[1] ? "+1" : "  ", j[0] ? "+1" : "  "),
                          32'h0000_5000 + 32'(j[1]), 32'h0000_4000 + 32'(j[0]),
                          12, 32'h0000_4000 + 32'(i) * 32'd2);
      end
    end
    // ... and against slow memory, where the fault lands mid-cycle.
    for (n = 1; n <= 4; n = n + 1) begin
      wait_states = n;
      for (i = 0; i < 6; i = i + 1) begin
        strncpy_berr_case($sformatf("page fault, %0d waits, dst word %0d", n, i),
                          SUN_DST, SUN_SRC, 12, SUN_DST + 32'(i) * 32'd2);
      end
    end
    wait_states = 0;

    $display("  strncpy reproducer: %0d cases, %0d took an exception",
             2 + 4 * 16 + 4 + 161 + 241 + 241 + 4 * 161 + 4 * 141 +
             4 * 6 + 6 + 4 * 6 + 4 * 6, faults);
    $display("  of the user-mode cases, %0d were resumed by RTE inside the loop, %0d of them with both operands odd", resumed_in_loop, resumed_both_odd);
    $display("  and %0d were resumed out of a format $8 frame after a page fault, %0d of those with loop mode running when it hit", resumed_after_berr, resumed_in_loop_mode);
    if (resumed_after_berr == 0) begin
      $display("FAIL: no case was resumed after a page fault, which is the mechanism the second report describes");
      errors = errors + 1;
    end
    if (resumed_in_loop_mode == 0) begin
      $display("FAIL: no page fault landed while loop mode was running, which is the state the report describes");
      errors = errors + 1;
    end
    if (resumed_in_loop == 0) begin
      $display("FAIL: no case was resumed inside the loop, so the sweep tested nothing the report describes");
      errors = errors + 1;
    end
    if (resumed_both_odd == 0) begin
      $display("FAIL: no case resumed with both operands odd, which is the reported condition");
      errors = errors + 1;
    end
    core_done("core_strncpy_tb");
  end

endmodule
