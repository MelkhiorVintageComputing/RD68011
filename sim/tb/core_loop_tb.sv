// Loop mode -- UM appendix A.
//
// "In the loop mode of the MC68010, a single instruction is executed repeatedly
// under control of the test condition, decrement, and branch (DBcc) instruction
// without any instruction fetch bus cycles. The execution of a single-
// instruction loop without fetching an instruction provides a highly efficient
// means of repeating an instruction because the only bus cycles required are
// those that read and write the operands."
//
// So the thing to check is the bus, and the check that matters is a negative
// one: after the loop is running, no cycle in program space happens at all.
// The reference vectors cannot say anything here -- an MC68000 has no loop
// mode, and every vector is one instruction long, which is one short of what it
// takes to enter.
//
// The program under test is the manual's own example from figure A-1, with the
// addresses filled in:
//
//   1000  MOVE.L #SOURCE,A0
//   1006  MOVE.L #DEST,A1
//   100C  MOVE.W #COUNT,D0
//   1010  MOVE.W (A0)+,(A1)+     <- the looped instruction
//   1012  DBEQ   D0,1010         <- displacement -4
//   1016  JMP    done

`timescale 1ns/1ps

module core_loop_tb;

`include "rd68011_core_harness.svh"

  localparam logic [31:0] SSP0   = 32'h0000_3000;
  localparam logic [31:0] PC0    = 32'h0000_1000;
  localparam logic [31:0] SOURCE = 32'h0000_4000;
  localparam logic [31:0] DEST   = 32'h0000_5000;
  localparam logic [31:0] H_DONE = 32'h0000_2000;
  localparam logic [31:0] H_IRQ  = 32'h0000_2100;
  localparam logic [31:0] H_BERR = 32'h0000_2200;
  localparam logic [31:0] H_TRACE = 32'h0000_2300;

  localparam logic [31:0] LOOP = 32'h0000_1010;

  int i;

  // Program-space cycles inside the loop, which is the whole question: once
  // loop mode is running there must be none.
  function automatic int prog_reads(input logic [23:0] lo, input logic [23:0] hi);
    int n;
    begin
      n = 0;
      for (int k = 0; k < ntr; k = k + 1) begin
        if (tr_rw[k] && ((tr_fc[k] == 3'd2) || (tr_fc[k] == 3'd6)) &&
            ({tr_addr[k], 1'b0} >= lo) && ({tr_addr[k], 1'b0} <= hi)) begin
          n = n + 1;
        end
      end
      prog_reads = n;
    end
  endfunction

  // The index of the RTE's last read of the frame, and of the first write to a
  // given address after it. Between those two the processor is *continuing* the
  // faulted instruction, and nothing it does there may be an instruction fetch.
  //
  // Anchored on the frame's own addresses rather than on the function code:
  // this program runs in supervisor mode throughout, so the loop's operand
  // cycles carry FC 5 as well and would swamp the search.
  function automatic int last_frame_read();
    int n;
    begin
      n = -1;
      for (int k = 0; k < ntr; k = k + 1)
        if (tr_rw[k] && ({tr_addr[k], 1'b0} < SSP0) &&
            ({tr_addr[k], 1'b0} >= (SSP0 - 32'd64))) n = k;
      last_frame_read = n;
    end
  endfunction

  function automatic int first_write_after(input int from, input logic [23:0] a);
    int n;
    begin
      n = -1;
      for (int k = ntr - 1; k > from; k = k - 1)
        if (!tr_rw[k] && ({tr_addr[k], 1'b0} == a)) n = k;
      first_write_after = n;
    end
  endfunction

  function automatic int prog_reads_between(input int lo_i, input int hi_i,
                                            input logic [23:0] lo,
                                            input logic [23:0] hi);
    int n;
    begin
      n = 0;
      for (int k = lo_i + 1; k < hi_i; k = k + 1)
        if (tr_rw[k] && ((tr_fc[k] == 3'd2) || (tr_fc[k] == 3'd6)) &&
            ({tr_addr[k], 1'b0} >= lo) && ({tr_addr[k], 1'b0} <= hi)) n = n + 1;
      prog_reads_between = n;
    end
  endfunction

  function automatic int data_cycles();
    int n;
    begin
      n = 0;
      for (int k = 0; k < ntr; k = k + 1) begin
        if ((tr_fc[k] == 3'd1) || (tr_fc[k] == 3'd5)) n = n + 1;
      end
      data_cycles = n;
    end
  endfunction

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

  // The setup and the loop, with `body` as the looped instruction and `disp`
  // as the DBcc's displacement, so a test can break either one.
  task automatic setup(input logic [15:0] body, input logic [15:0] dbcc,
                       input logic [15:0] disp, input logic [15:0] count);
    begin
      core_reset();
      poke_l(23'h000000, SSP0);
      poke_l(23'h000002, PC0);
      poke_l(23'h000012, H_TRACE);   // vector 9
      poke_l(23'h000004, H_BERR);    // vector 2
      poke_l(23'h00003E, H_IRQ);     // vector 31, autovector for level 7
      poke_w(H_DONE[23:1],  16'h60FE);
      poke_w(H_IRQ[23:1],   16'h60FE);
      poke_w(H_BERR[23:1],  16'h60FE);
      poke_w(H_TRACE[23:1], 16'h60FE);

      poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, SOURCE);
      poke_w(23'h000803, 16'h227C);  poke_l(23'h000804, DEST);
      poke_w(23'h000806, 16'h303C);  poke_w(23'h000807, count);
      poke_w(23'h000808, body);              // 1010
      poke_w(23'h000809, dbcc);              // 1012
      poke_w(23'h00080A, disp);              // 1014
      poke_w(23'h00080B, 16'h4EF9);          // 1016: JMP done
      poke_l(23'h00080C, H_DONE);
    end
  endtask

  // Eight words at SOURCE, none of them zero unless a test wants one.
  task automatic fill(input logic [15:0] zero_at);
    begin
      for (i = 0; i < 8; i = i + 1) begin
        poke_w(SOURCE[23:1] + 23'(i),
               (16'(i) == zero_at) ? 16'h0000 : 16'(16'h1100 + 16'(i)));
        poke_w(DEST[23:1] + 23'(i), 16'hFFFF);
      end
    end
  endtask

  initial begin
    errors = 0;

    // ======================================================================
    // The manual's example: six words, and the count runs out
    // ======================================================================
    setup(16'h32D8, 16'h57C8, 16'hFFFC, 16'd5);   // MOVE.W (A0)+,(A1)+ ; DBEQ
    fill(16'hFFFF);                               // no zero word
    core_start();
    run_until_pc(H_DONE, 3000);

    for (i = 0; i < 6; i = i + 1) begin
      expect_u32($sformatf("loop: word %0d moved", i),
                 {16'd0, mem.peek(DEST[23:1] + 23'(i))},
                 {16'd0, 16'(16'h1100 + 16'(i))});
    end
    expect_u32("loop: the word after the last is untouched",
               {16'd0, mem.peek(DEST[23:1] + 23'd6)}, 32'h0000_FFFF);
    expect_u32("loop: A0 advanced by six words", dut.u_seq.regs[8],
               SOURCE + 32'd12);
    expect_u32("loop: A1 advanced by six words", dut.u_seq.regs[9],
               DEST + 32'd12);
    expect_u32("loop: the counter ended at -1", dut.u_seq.regs[0] & 32'h0000FFFF,
               32'h0000_FFFF);

    // Six iterations, each of which would fetch three words if the loop were
    // not a loop. What actually happens is that the first two are fetched
    // normally -- "the looped instruction and the first word of the DBcc
    // instruction are each fetched twice when the loop is entered" -- and then
    // nothing until the loop ends and the pipe refills.
    expect_int("loop: program reads inside the loop", prog_reads(24'h001010,
                                                                 24'h001015), 5);
    expect_int("loop: the operand cycles are all of them", data_cycles(), 12);

    // ======================================================================
    // The condition stops it: a zero word, with DBEQ
    // ======================================================================
    setup(16'h32D8, 16'h57C8, 16'hFFFC, 16'd7);
    fill(16'd3);                                  // the fourth word is zero
    core_start();
    run_until_pc(H_DONE, 3000);
    expect_u32("cc exit: the zero word was moved",
               {16'd0, mem.peek(DEST[23:1] + 23'd3)}, 32'd0);
    expect_u32("cc exit: the word after it was not",
               {16'd0, mem.peek(DEST[23:1] + 23'd4)}, 32'h0000_FFFF);
    // Four moved, so the counter went 7 6 5 4 and then the condition held on
    // the fourth pass without being decremented again.
    expect_u32("cc exit: the counter stopped where the condition did",
               dut.u_seq.regs[0] & 32'h0000FFFF, 32'd4);

    // ======================================================================
    // A displacement that is not -4 never enters loop mode
    // ======================================================================
    // The same work, reached by going back six from a NOP placed in front of
    // the MOVE. Every iteration fetches, because the entry condition is the
    // displacement and not the shape of the loop.
    //
    //   1010 NOP ; 1012 MOVE.W (A0)+,(A1)+ ; 1014 DBEQ D0,1010 (disp -6)
    setup(16'h4E71, 16'h32D8, 16'h57C8, 16'd5);
    poke_w(23'h00080B, 16'hFFFA);          // 1016: displacement -6
    poke_w(23'h00080C, 16'h4EF9);  poke_l(23'h00080D, H_DONE);
    fill(16'hFFFF);
    core_start();
    run_until_pc(H_DONE, 4000);
    expect_u32("no loop mode: the words still moved",
               {16'd0, mem.peek(DEST[23:1] + 23'd5)}, 32'h0000_1105);
    expect_u32("no loop mode: A0 advanced by six words", dut.u_seq.regs[8],
               SOURCE + 32'd12);
    // Six iterations of three words each, plus the refill at the end.
    if (prog_reads(24'h001010, 24'h001017) < 18) begin
      $display("FAIL: a displacement of -6 entered loop mode anyway (%0d reads)",
               prog_reads(24'h001010, 24'h001017));
      errors = errors + 1;
    end

    // ======================================================================
    // An instruction the table does not list is not looped
    // ======================================================================
    // MOVE.W (A0)+,D1 is one word and uses only (An)+, but its destination is
    // a data register, which tables A-1 and 9-3 both leave out. The loop works
    // and fetches every time round.
    //
    //   1010 MOVE.W (A0)+,D1 ; 1012 DBF D0,1010 (disp -4)
    setup(16'h3218, 16'h51C8, 16'hFFFC, 16'd3);
    fill(16'hFFFF);
    core_start();
    run_until_pc(H_DONE, 4000);
    expect_u32("not a loop mode instruction: it still ran four times",
               dut.u_seq.regs[8], SOURCE + 32'd8);
    expect_u32("not a loop mode instruction: the last word is in D1",
               dut.u_seq.regs[1] & 32'h0000FFFF, 32'h0000_1103);
    if (prog_reads(24'h001010, 24'h001015) < 12) begin
      $display("FAIL: an instruction outside the table was looped (%0d reads)",
               prog_reads(24'h001010, 24'h001015));
      errors = errors + 1;
    end

    // ======================================================================
    // Tracing keeps loop mode out -- UM appendix A
    // ======================================================================
    // "While the T bit is set, a trace exception occurs at the end of both the
    // looped instruction and the DBcc instruction, making loop mode
    // unavailable while tracing is enabled."
    setup(16'h32D8, 16'h57C8, 16'hFFFC, 16'd5);
    fill(16'hFFFF);
    // Set the trace bit before the loop: MOVE #$A700,SR in place of the
    // count load, and the count in the instruction after.
    poke_w(23'h000806, 16'h46FC);  poke_w(23'h000807, 16'hA700);
    core_start();
    run_until_pc(H_TRACE, 2000);
    expect_u32("tracing: loop mode never started",
               {31'd0, dut.u_seq.loop_active}, 32'd0);

    // ======================================================================
    // An interrupt ends the loop, and it starts again afterwards
    // ======================================================================
    // "Any pending interrupt is taken after each execution of the DBcc
    // instruction, but not after each execution of the looped instruction."
    setup(16'h32D8, 16'h57C8, 16'hFFFC, 16'd5);
    fill(16'hFFFF);
    // Drop the interrupt mask so a level 7 gets in, using the word that
    // loaded the count and moving the count load after it.
    poke_w(23'h000806, 16'h46FC);  poke_w(23'h000807, 16'h2000);
    poke_w(23'h000808, 16'h303C);  poke_w(23'h000809, 16'd5);
    poke_w(23'h00080A, 16'h32D8);          // 1014: the MOVE
    poke_w(23'h00080B, 16'h57C8);          // 1016: DBEQ
    poke_w(23'h00080C, 16'hFFFC);          // 1018
    poke_w(23'h00080D, 16'h4EF9);  poke_l(23'h00080E, H_DONE);
    // The handler returns, so the loop can pick up where it left off.
    poke_w(H_IRQ[23:1], 16'h4E73);
    core_start();
    // Let the loop get going, then interrupt it.
    while (!dut.u_seq.loop_active) @(posedge clk);
    repeat (20) @(posedge clk);
    ipl_n_i = 3'b000;
    repeat (4) @(posedge clk);
    ipl_n_i = 3'b111;
    run_until_pc(H_DONE, 4000);
    expect_u32("interrupt: the loop finished all six words",
               {16'd0, mem.peek(DEST[23:1] + 23'd5)}, 32'h0000_1105);
    expect_u32("interrupt: A0 advanced by six words", dut.u_seq.regs[8],
               SOURCE + 32'd12);
    expect_u32("interrupt: the stack is where it started", dut.u_seq.ssp, SSP0);

    // ======================================================================
    // A bus error inside the loop, continued by RTE -- UM appendix A
    // ======================================================================
    // "A bus error during loop mode operation is handled the same as during
    // other processing; however, when the return from exception (RTE)
    // instruction continues execution of the looped instruction, the three-word
    // loop is not fetched again."
    setup(16'h32D8, 16'h57C8, 16'hFFFC, 16'd5);
    fill(16'hFFFF);
    poke_w(H_BERR[23:1], 16'h4E73);        // the handler is an RTE
    core_start();
    while (!dut.u_seq.loop_active) @(posedge clk);
    // Fault on the fourth word of the destination, which is well inside the
    // loop by then.
    berr_addr = (DEST + 32'd6) >> 1;
    berr_en   = 1'b1;
    run_until_pc(H_BERR, 3000);
    expect_u32("bus error in a loop: the loop was suspended, not ended",
               {31'd0, dut.u_seq.loop_active}, 32'd0);
    berr_en = 1'b0;
    run_until_pc(H_DONE, 3000);
    expect_u32("bus error in a loop: every word still moved",
               {16'd0, mem.peek(DEST[23:1] + 23'd5)}, 32'h0000_1105);
    expect_u32("bus error in a loop: and the faulted one",
               {16'd0, mem.peek(DEST[23:1] + 23'd3)}, 32'h0000_1103);
    expect_u32("bus error in a loop: the stack is where it started",
               dut.u_seq.ssp, SSP0);
    // The count, which the two words above only half constrain. Both pointers
    // post-increment, so a lost or repeated iteration shifts the destination
    // and one of those two catches it -- but a *seventh* iteration after the
    // resume leaves both of them right and writes past the end. These are the
    // clean case's checks, which say six and not five or seven.
    expect_u32("bus error in a loop: the word after the last is untouched",
               {16'd0, mem.peek(DEST[23:1] + 23'd6)}, 32'h0000_FFFF);
    expect_u32("bus error in a loop: A0 advanced by six words",
               dut.u_seq.regs[8], SOURCE + 32'd12);
    expect_u32("bus error in a loop: A1 advanced by six words",
               dut.u_seq.regs[9], DEST + 32'd12);
    expect_u32("bus error in a loop: the counter ended at -1",
               dut.u_seq.regs[0] & 32'h0000FFFF, 32'h0000_FFFF);
    // How many of the loop's three words come back over the bus, which is the
    // half of appendix A the two readings disagree about.
    //
    //   RTE_RESTORES_LOOP=1  five. Loop mode comes back out of the frame and no
    //                        word of the loop is fetched again, which is the
    //                        literal reading of "the three-word loop is not
    //                        fetched again".
    //   RTE_RESTORES_LOOP=0  eight. Loop mode has exited, as appendix A's own
    //                        list of abnormal conditions says a bus error makes
    //                        it, so the DBcc runs its ordinary path, reads the
    //                        displacement loop mode never read, and re-enters.
    //
    // doc/divergences.md argues both readings and says which is built.
    expect_int("bus error in a loop: the loop's words on the bus",
               prog_reads(24'h001010, 24'h001015),
               (`RD68011_RTE_RESTORES_LOOP != 0) ? 5 : 8);

    // What neither reading permits, and what makes the difference above a
    // choice of reading rather than a defect: the faulted instruction has to be
    // *continued*, not restarted. So between the RTE's last read of the frame
    // and the retried write that finishes the instruction, there must be no
    // instruction fetch at all. Any reload of the loop's words is visible on
    // the bus only after the instruction has been replayed.
    begin
      int i_rte, i_wr;
      i_rte = last_frame_read();
      i_wr  = first_write_after(i_rte, DEST + 32'd6);
      if ((i_rte < 0) || (i_wr < 0)) begin
        $display("FAIL: bus error in a loop: no RTE walk (%0d) or no retried write (%0d)",
                 i_rte, i_wr);
        errors = errors + 1;
      end else begin
        expect_int("bus error in a loop: the instruction is continued, not refetched",
                   prog_reads_between(i_rte, i_wr, 24'h001010, 24'h001015), 0);
      end
    end

    if (errors == 0) $display("PASS: core_loop_tb");
    else             $display("FAIL: core_loop_tb, %0d errors", errors);
    $finish;
  end

endmodule
