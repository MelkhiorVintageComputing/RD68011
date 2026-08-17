// Real code, compiled and run.
//
// Everything else that tests this processor tests it one instruction at a
// time. The reference vectors are a single instruction each from a fabricated
// register state; the directed testbenches are a handful of hand-written ones.
// Nothing until here has run a *program*: a return address that survives three
// nested calls, a frame pointer that is still a frame pointer after the callee
// saved and restored eight registers, a handler that does real work and
// returns into the middle of the instruction that faulted.
//
// So this loads a flat image built by sim/programs/ -- the vector table at
// zero and everything after it, exactly what an MC68010 sees after reset --
// releases the processor, and waits for the program to say what happened.
// The contract is two words, at the addresses sim/programs/link.ld fixes:
//
//   0x0400  result    0 while running, $600D600D on success, otherwise the
//                     number of the check that failed, or $8xxx for an
//                     exception the program did not expect (xxx is its vector
//                     offset)
//   0x0404  progress  the check now running, so a program that hangs still
//                     says where it stopped
//   0x0408  done      one word, written last, because a long store is two bus
//                     cycles and this testbench polls memory while the
//                     processor runs
//
// Run one image with +prog=<file>; the Makefile's `programs` target runs them
// all. Some programs also want faults injected from outside, which +berr=
// arranges: the harness answers one address with a bus error, and the program
// is written knowing that it will.

`timescale 1ns/1ps

module core_program_tb;

`include "rd68011_core_harness.svh"

  localparam logic [22:0] RESULT_W   = 23'h000200;   // 0x0400 >> 1
  localparam logic [22:0] PROGRESS_W = 23'h000202;   // 0x0404 >> 1
  localparam logic [22:0] DONE_W     = 23'h000204;   // 0x0408 >> 1
  localparam logic [31:0] PASS_MARK  = 32'h600D_600D;

  string       progfile;
  int          limit;
  int          berr_word;
  logic [31:0] res, prog;
  int          n;

  function automatic logic [31:0] peek_l(input logic [22:0] wa);
    peek_l = {mem.peek(wa), mem.peek(wa + 23'd1)};
  endfunction

  initial begin
    errors = 0;

    if (!$value$plusargs("prog=%s", progfile)) begin
      $display("FAIL: core_program_tb needs +prog=<hex image>");
      $finish;
    end
    if (!$value$plusargs("limit=%d", limit))   limit = 3000000;
    if (!$value$plusargs("berr=%d", berr_word)) berr_word = -1;

    core_reset();
    mem.clear();
    $readmemh(progfile, mem.mem);

    if (berr_word >= 0) begin
      berr_addr = 23'(berr_word);
      berr_en   = 1'b1;
    end

    core_start();

    // The program writes its result and then stops in a tight loop, so the
    // wait is on memory rather than on the processor. The flag is one word and
    // is written last: a long store is two bus cycles, and polling between
    // them would read half of it.
    n = 0;
    while ((mem.peek(DONE_W) == 16'd0) && (n < limit)) begin
      @(posedge clk);
      n = n + 1;
    end

    res  = peek_l(RESULT_W);
    prog = peek_l(PROGRESS_W);

    if (mem.peek(DONE_W) == 16'd0) begin
      $display("FAIL: %s did not finish; it was in check %0d after %0d clocks",
               progfile, prog, n);
      $display("      pc %08h  ir %04h  sr %04h",
               dut.u_seq.ir_pc, dut.u_seq.ir, dut.u_seq.sr);
      errors = errors + 1;
    end else if (res == PASS_MARK) begin
      $display("  %s: %0d checks in %0d clocks", progfile, prog, n);
    end else if (res[31:16] == 16'h0000 && res[15] == 1'b1) begin
      $display("FAIL: %s took vector offset $%03h, which it did not expect,"
               , progfile, res[11:0]);
      $display("      during check %0d", prog);
      errors = errors + 1;
    end else begin
      // `fail` writes the check number plus one, so that check zero failing
      // does not look like a program that never started.
      $display("FAIL: %s failed check %0d", progfile, res - 32'd1);
      errors = errors + 1;
    end

    if (errors == 0) $display("PASS: %s", progfile);
    else             $display("FAIL: core_program_tb");
    $finish;
  end

endmodule
