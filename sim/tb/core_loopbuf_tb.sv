// The loop buffer -- doc/divergences.md, "Deliberate divergences: the loop
// buffer". Not an MC68010 mechanism, and off unless LOOP_BUF_WORDS says
// otherwise, so this is the only testbench that turns it on.
//
// Loop mode proper asks its question as a negative one: once the loop is
// running, no cycle in program space happens at all. This asks the same shape
// of question with the number the buffer actually promises -- *one* program
// cycle a trip, at the top of the loop, because the fetch straight after the
// backward branch is deliberately not looked up.
//
// The other half is what the buffer must not do. A window is a logical address
// and it is only good while nothing has changed what it maps to, so every one
// of the four invalidations gets a test whose whole content is that the cycles
// come back.

`timescale 1ns/1ps
`define RD68011_LOOP_BUF_WORDS 16

module core_loopbuf_tb;

`include "rd68011_core_harness.svh"

  localparam logic [31:0] SSP0   = 32'h0000_3000;
  localparam logic [31:0] PC0    = 32'h0000_1000;
  localparam logic [31:0] SOURCE = 32'h0000_4000;
  localparam logic [31:0] DEST   = 32'h0000_5000;
  localparam logic [31:0] SPARE  = 32'h0000_1022;  // inside the window, not code
  localparam logic [31:0] H_DONE = 32'h0000_2000;
  localparam logic [31:0] H_IRQ  = 32'h0000_2100;

  localparam logic [31:0] LOOP   = 32'h0000_1010;
  localparam logic [15:0] TRIPS  = 16'd8;          // DBRA runs count+1 times

  int i;

  // ---------------------------------------------------------------------------
  // Counting
  // ---------------------------------------------------------------------------
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

  function automatic int prog_reads_at(input logic [31:0] addr);
    prog_reads_at = prog_reads(addr[23:0], addr[23:0]);
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

  // ---------------------------------------------------------------------------
  // The program. A prologue at $1000 that sets the two pointers and the count,
  // then whatever loop the test pokes at $1010, then a JMP out of it.
  // ---------------------------------------------------------------------------
  task automatic prologue(input logic [15:0] count);
    begin
      core_reset();
      poke_l(23'h000000, SSP0);
      poke_l(23'h000002, PC0);
      poke_l(23'h00003E, H_IRQ);     // vector 31, autovector for level 7
      poke_w(H_DONE[23:1], 16'h60FE);
      poke_w(H_IRQ[23:1],  16'h60FE);

      poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, SOURCE);  // MOVEA.L #SOURCE,A0
      poke_w(23'h000803, 16'h227C);  poke_l(23'h000804, DEST);    // MOVEA.L #DEST,A1
      poke_w(23'h000806, 16'h303C);  poke_w(23'h000807, count);   // MOVE.W  #count,D0
    end
  endtask

  task automatic jmp_out(input logic [23:1] at);
    begin
      poke_w(at, 16'h4EF9);
      poke_l(at + 23'd1, H_DONE);
    end
  endtask

  // Sixteen words at SOURCE, and DEST cleared to something that cannot be
  // mistaken for a result.
  task automatic fill(input logic [15:0] zero_at);
    begin
      for (i = 0; i < 16; i = i + 1) begin
        poke_w(SOURCE[23:1] + 23'(i),
               (16'(i) == zero_at) ? 16'h0000 : 16'(16'h1100 + 16'(i)));
        poke_w(DEST[23:1] + 23'(i), 16'hFFFF);
      end
    end
  endtask

  // The loop the first four tests all use. Three instructions, one of them two
  // words long with an extension word -- which is the whole point, because loop
  // mode as the manual defines it can hold neither a second instruction nor an
  // extension word.
  //
  //   1010  MOVE.W (A0)+,D1
  //   1012  ADDI.W #1,D1
  //   1016  MOVE.W D1,(A1)+
  //   1018  DBRA   D0,1010
  //   101C  JMP    done
  task automatic loop_three();
    begin
      poke_w(23'h000808, 16'h3218);                       // 1010
      poke_w(23'h000809, 16'h0641);  poke_w(23'h00080A, 16'h0001);
      poke_w(23'h00080B, 16'h32C1);                       // 1016
      poke_w(23'h00080C, 16'h51C8);  poke_w(23'h00080D, 16'hFFF6);
      jmp_out(23'h00080E);                                // 101C
    end
  endtask

  task automatic check_moved(input string what, input int n);
    begin
      for (i = 0; i < n; i = i + 1) begin
        expect_u32($sformatf("%s: word %0d", what, i),
                   {16'd0, mem.peek(DEST[23:1] + 23'(i))},
                   {16'd0, 16'(16'h1101 + 16'(i))});
      end
    end
  endtask

  // Somewhere in the middle of a warm loop, which is the only place an
  // invalidation is worth testing: before the buffer arms there is nothing to
  // empty, and a test that fires too early measures nothing and still passes.
  task automatic settle();
    begin
      wait (dut.u_seq.lb_armed === 1'b1);
      repeat (40) @(posedge clk);
    end
  endtask

  int reads_top, reads_rest, reads_cold;

  initial begin
    errors = 0;

    // ======================================================================
    // A three-instruction loop, one of them with an extension word
    //
    // The first trip is fetched because nothing has armed yet, and the second
    // because the DBcc arming the window is what empties it -- the same "each
    // fetched twice when the loop is entered" the manual says of loop mode.
    // After that every trip costs one cycle, at the top of the loop.
    // ======================================================================
    prologue(TRIPS - 16'd1);
    loop_three();
    fill(16'hFFFF);
    core_start();
    run_until_pc(H_DONE, 6000);
    check_moved("three-instruction loop", int'(TRIPS));

    reads_top  = prog_reads_at(LOOP);
    reads_rest = prog_reads(LOOP[23:0] + 24'd2, 24'h00101B);
    expect_int("the loop top is read once a trip", reads_top, int'(TRIPS));
    expect_int("the rest of the loop is read twice over", reads_rest, 2 * 5);

    // ======================================================================
    // The same loop, with the buffer disabled from outside
    //
    // Holding loop_inv_n_i asserted is how a board says the buffer may never
    // be trusted, and it has to give back exactly the machine that was built
    // without one: every word of every trip, fetched.
    // ======================================================================
    prologue(TRIPS - 16'd1);
    loop_three();
    fill(16'hFFFF);
    core_start();
    loop_inv_n_i = 1'b0;
    run_until_pc(H_DONE, 6000);
    loop_inv_n_i = 1'b1;
    check_moved("loop_inv_n_i held low", int'(TRIPS));

    reads_cold = prog_reads(LOOP[23:0], 24'h00101B);
    expect_int("held low, the loop top is read once a trip",
               prog_reads_at(LOOP), int'(TRIPS));
    expect_int("held low, every word of every trip is fetched",
               reads_cold, 6 * int'(TRIPS));

    // ======================================================================
    // A pulse on the pin empties it
    //
    // Two clock periods is the synchroniser's depth and the width the pinout
    // states. One pulse costs one extra refill, so the loop's cycles land
    // between the two counts above and nowhere else.
    // ======================================================================
    prologue(TRIPS - 16'd1);
    loop_three();
    fill(16'hFFFF);
    core_start();
    settle();
    wait (dut.u_seq.ir_pc === LOOP);    // the top of a trip, so the cost is fixed
    loop_inv_n_i = 1'b0;
    repeat (3) @(posedge clk);
    loop_inv_n_i = 1'b1;
    run_until_pc(H_DONE, 6000);
    check_moved("loop_inv_n_i pulsed", int'(TRIPS));
    // Nine more than the eighteen above, and each of the nine is accounted
    // for. The pin disarms as well as empties, so the four words left in the
    // trip it lands in are fetched and not filled; the five of the next trip
    // are fetched and do fill, and after that the loop is warm again. The top
    // of the loop is still read once a trip either way.
    expect_int("a pulse costs the rest of one trip and all of the next",
               prog_reads(LOOP[23:0], 24'h00101B), 18 + 4 + 5);
    expect_int("a pulse does not change the loop top's count",
               prog_reads_at(LOOP), int'(TRIPS));

    // ======================================================================
    // A write into the window empties it
    //
    // The loop stores through A1, and A1 is aimed inside the window at a word
    // the loop does not execute. Nothing about the code changes; the core
    // cannot know that, and must assume the worst.
    // ======================================================================
    prologue(16'd3);                    // four trips, to stay clear of the code
    loop_three();
    fill(16'hFFFF);
    poke_w(23'h000804, SPARE[31:16]);   // A1 = SPARE: in the window, not code
    poke_w(23'h000805, SPARE[15:0]);
    core_start();
    run_until_pc(H_DONE, 6000);
    expect_int("a write into the window empties it every trip",
               prog_reads(LOOP[23:0], 24'h00101B), 6 * 4);

    // ======================================================================
    // A bus grant empties it
    // ======================================================================
    prologue(TRIPS - 16'd1);
    loop_three();
    fill(16'hFFFF);
    core_start();
    settle();
    br_n_i = 1'b0;
    wait (bg_n_o === 1'b0);
    repeat (6) @(posedge clk);
    br_n_i = 1'b1;
    run_until_pc(H_DONE, 6000);
    check_moved("a bus grant", int'(TRIPS));
    if (prog_reads(LOOP[23:0], 24'h00101B) <= 5 * 2 + int'(TRIPS)) begin
      $display("FAIL: a bus grant did not empty the loop buffer (%0d reads)",
               prog_reads(LOOP[23:0], 24'h00101B));
      errors = errors + 1;
    end

    // ======================================================================
    // An interrupt empties it, because the supervisor bit moved
    //
    // A program fetch carries function code 2 or 6, and with an MMU in front
    // those are different address spaces. So the S bit changing is enough on
    // its own, twice over: into the handler and back out of it.
    // ======================================================================
    prologue(TRIPS - 16'd1);
    loop_three();
    fill(16'hFFFF);
    poke_w(H_IRQ[23:1], 16'h4E73);      // RTE, straight back to the loop
    core_start();
    settle();
    ipl_n_i = 3'b000;                   // level 7
    repeat (4) @(posedge clk);
    ipl_n_i = 3'b111;
    run_until_pc(H_DONE, 8000);
    check_moved("an interrupt", int'(TRIPS));
    if (prog_reads(LOOP[23:0], 24'h00101B) <= 5 * 2 + int'(TRIPS)) begin
      $display("FAIL: an S transition did not empty the loop buffer (%0d reads)",
               prog_reads(LOOP[23:0], 24'h00101B));
      errors = errors + 1;
    end

    // ======================================================================
    // A loop too long for the window arms nothing
    //
    //   1010  MOVE.W (A0)+,D1
    //   1012  fourteen NOPs
    //   102E  MOVE.W D1,(A1)+
    //   1030  DBRA   D0,1010          -- eighteen words, and the window is 16
    // ======================================================================
    prologue(TRIPS - 16'd1);
    poke_w(23'h000808, 16'h3218);
    for (i = 0; i < 14; i = i + 1) poke_w(23'h000809 + 23'(i), 16'h4E71);
    poke_w(23'h000817, 16'h32C1);                       // 102E
    poke_w(23'h000818, 16'h51C8);  poke_w(23'h000819, 16'hFFDE);
    jmp_out(23'h00081A);                                // 1034
    fill(16'hFFFF);
    core_start();
    run_until_pc(H_DONE, 12000);
    for (i = 0; i < int'(TRIPS); i = i + 1) begin
      expect_u32($sformatf("too long: word %0d", i),
                 {16'd0, mem.peek(DEST[23:1] + 23'(i))},
                 {16'd0, 16'(16'h1100 + 16'(i))});
    end
    expect_int("a loop that does not fit is fetched in full",
               prog_reads(LOOP[23:0], 24'h001033), 18 * int'(TRIPS));

    // ======================================================================
    // A branch inside the body keeps the window
    //
    //   1010  MOVE.W (A0)+,D1
    //   1012  BEQ.B  1016            -- forward, and inside the window
    //   1014  ADDQ.W #1,D1
    //   1016  MOVE.W D1,(A1)+
    //   1018  DBRA   D0,1010
    //
    // The buffer must survive it: a transfer whose target is already inside
    // the armed window is the loop branching within itself, not a new loop.
    // ======================================================================
    prologue(TRIPS - 16'd1);
    poke_w(23'h000808, 16'h3218);                       // 1010
    poke_w(23'h000809, 16'h6702);                       // 1012 BEQ.B 1016
    poke_w(23'h00080A, 16'h5241);                       // 1014 ADDQ.W #1,D1
    poke_w(23'h00080B, 16'h32C1);                       // 1016
    poke_w(23'h00080C, 16'h51C8);  poke_w(23'h00080D, 16'hFFF6);
    jmp_out(23'h00080E);
    fill(16'd3);                                        // SOURCE[3] is zero
    core_start();
    run_until_pc(H_DONE, 8000);
    for (i = 0; i < int'(TRIPS); i = i + 1) begin
      expect_u32($sformatf("branch in body: word %0d", i),
                 {16'd0, mem.peek(DEST[23:1] + 23'(i))},
                 {16'd0, (i == 3) ? 16'h0000 : 16'(16'h1101 + 16'(i))});
    end
    expect_int("a branch inside the body keeps the window",
               prog_reads_at(LOOP), int'(TRIPS));

    // ======================================================================
    // A Bcc closes a loop as well as a DBcc does
    //
    //   1010  MOVE.W (A0)+,D1
    //   1012  MOVE.W D1,(A1)+
    //   1014  SUBQ.W #1,D0
    //   1016  BNE.B  1010
    //
    // Nothing about the buffer knows what a DBcc is. It arms on the microword
    // that loads the program counter, whatever put it there.
    // ======================================================================
    prologue(TRIPS);
    poke_w(23'h000808, 16'h3218);                       // 1010
    poke_w(23'h000809, 16'h32C1);                       // 1012
    poke_w(23'h00080A, 16'h5340);                       // 1014 SUBQ.W #1,D0
    poke_w(23'h00080B, 16'h66F8);                       // 1016 BNE.B 1010
    jmp_out(23'h00080C);                                // 1018
    fill(16'hFFFF);
    core_start();
    run_until_pc(H_DONE, 8000);
    for (i = 0; i < int'(TRIPS); i = i + 1) begin
      expect_u32($sformatf("Bcc loop: word %0d", i),
                 {16'd0, mem.peek(DEST[23:1] + 23'(i))},
                 {16'd0, 16'(16'h1100 + 16'(i))});
    end
    expect_int("a Bcc loop reads its top once a trip",
               prog_reads_at(LOOP), int'(TRIPS));

    core_done("core_loopbuf_tb");
  end

endmodule
