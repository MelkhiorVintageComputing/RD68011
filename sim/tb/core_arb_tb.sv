// Bus arbitration with the processor actually running.
//
// sim/tb/bus_arb_tb.sv checks the handshake itself -- specifications 35, 36,
// 37, 57 and 57A, both the three-wire and two-wire protocols -- but it drives
// the bus unit directly, with no sequencer behind it. So until this file
// nothing had ever seen arbitration interact with prefetch, with a microword
// retiring, or with an instruction boundary. A machine with DMA in it does
// that constantly.
//
// The property worth asserting is not that the handshake is well formed, which
// the other testbench already covers, but that it is *invisible*: giving the
// bus away and taking it back must cost time and nothing else. So the same
// program runs twice, once undisturbed and once with an arbitration episode in
// the middle, and the two runs have to produce the same bus cycles in the same
// order -- and the same answers in memory.
//
// UM 5.2.1: "the processor [...] relinquishes the bus after it completes the
// current bus cycle", so a request arriving mid-instruction waits for the
// cycle, not for the instruction.
//
// The second half of the file is about the seam between two cycles of one
// transfer. A longword is two bus cycles and a MOVEM.L is four, and a master
// may legally take the bus between any two of them -- so the grant is swept
// across the whole transfer, half a clock at a time, and the assembled value
// is checked at every offset. The alignment that matters is the rising edge
// that ends S7, which both starts the next cycle and lets the arbiter reach
// ARB_GRANT: made from different views of the same signal, those two decisions
// let a cycle begin with the buses already promised away. rtl/rd68011_biu.sv's
// `arb_freeze` comment has the mechanism.

`timescale 1ns/1ps

module core_arb_tb;

`include "rd68011_core_harness.svh"

  localparam logic [31:0] SSP0 = 32'h0000_2000;
  localparam logic [31:0] PC0  = 32'h0000_1000;
  localparam logic [31:0] DONE = 32'h0000_1012;   // the branch-to-self

  int i;
  int n_quiet;
  logic [23:1] q_addr [0:MAXTR-1];
  logic  [2:0] q_fc   [0:MAXTR-1];
  logic        q_rw   [0:MAXTR-1];

  int as_during_grant;

  // The alternate master, as far as this file needs one: something that drives
  // the data bus while it owns it. Without it a re-latch during the grant
  // shows up as high impedance, which is a weaker signal than wrong data --
  // and on a real board there is no such thing as a quiet bus during DMA.
  localparam logic [15:0] MASTER_D = 16'h0E66;
  logic master_drive;
  assign dbus = master_drive ? MASTER_D : 16'bz;

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

  // Three stores and a branch to self. Six bytes each, so the boundaries are
  // easy to read: 1000, 1006, 100C, 1012.
  task automatic load();
    begin
      poke_l(23'h000000, SSP0);
      poke_l(23'h000002, PC0);
      poke_w(23'h000800, 16'h31FC);   // 1000: MOVE.W #$1111,($0900).W
      poke_w(23'h000801, 16'h1111);
      poke_w(23'h000802, 16'h0900);
      poke_w(23'h000803, 16'h31FC);   // 1006: MOVE.W #$2222,($0902).W
      poke_w(23'h000804, 16'h2222);
      poke_w(23'h000805, 16'h0902);
      poke_w(23'h000806, 16'h31FC);   // 100C: MOVE.W #$3333,($0904).W
      poke_w(23'h000807, 16'h3333);
      poke_w(23'h000808, 16'h0904);
      poke_w(23'h000809, 16'h60FE);   // 1012: branch to self
      poke_w(23'h000480, 16'h0000);
      poke_w(23'h000481, 16'h0000);
      poke_w(23'h000482, 16'h0000);
    end
  endtask

  task automatic check_result(input string what);
    begin
      expect_u32({what, ": first store"},  {16'd0, mem.peek(23'h000480)},
                 32'h0000_1111);
      expect_u32({what, ": second store"}, {16'd0, mem.peek(23'h000481)},
                 32'h0000_2222);
      expect_u32({what, ": third store"},  {16'd0, mem.peek(23'h000482)},
                 32'h0000_3333);
    end
  endtask

  // ==========================================================================
  // A grant between the cycles of one transfer
  // ==========================================================================
  //
  // A longword read is two bus cycles and a MOVEM.L of two registers is four.
  // UM 5.2.1 lets a master have the bus at the end of any of them, so the
  // interesting question is not whether the handshake is well formed -- the
  // first half of this file and sim/tb/bus_arb_tb.sv both cover that -- but
  // whether the transfer still assembles the right value afterwards.
  //
  // So: run the transfer, assert BR at a chosen offset from the moment the
  // first cycle's AS goes out, let the master have the bus, give it back, and
  // check what the processor stored. Then do it again half a clock later, over
  // the whole transfer and past the end of it, in both arbitration protocols.
  //
  // The offset is what makes this a test rather than an anecdote. The defect
  // it was written for needed BR to be recognised on one specific rising edge
  // -- the one that ends S7 -- and a sweep that stepped a whole clock at a
  // time from an arbitrary starting point would find it or miss it by luck.

  localparam logic [31:0] SW_PC   = 32'h0000_1100;
  localparam logic [31:0] SW_SRC  = 32'h0000_0900;   // what the transfer reads
  localparam logic [31:0] SW_DST  = 32'h0000_0910;   // and where it puts it
  localparam logic [63:0] SW_VAL  = 64'h00EE_3000_A004_3701;

  // Long: MOVE.L ($0900).W,D0 / MOVE.L D0,($0910).W / branch to self.
  task automatic load_long();
    begin
      poke_l(23'h000000, SSP0);
      poke_l(23'h000002, SW_PC);
      poke_l(SW_SRC[23:1], SW_VAL[63:32]);
      poke_w(23'h000880, 16'h2038);           // 1100
      poke_w(23'h000881, SW_SRC[15:0]);
      poke_w(23'h000882, 16'h21C0);           // 1104
      poke_w(23'h000883, SW_DST[15:0]);
      poke_w(23'h000884, 16'h60FE);           // 1108
      poke_l(SW_DST[23:1], 32'h0000_0000);
    end
  endtask

  // MOVEM: four word reads and four word writes, so there are three seams
  // inside the read half instead of one.
  task automatic load_movem();
    begin
      poke_l(23'h000000, SSP0);
      poke_l(23'h000002, SW_PC);
      poke_l(SW_SRC[23:1],          SW_VAL[63:32]);
      poke_l(SW_SRC[23:1] + 23'd2,  SW_VAL[31:0]);
      poke_w(23'h000880, 16'h4CF8);           // 1100: MOVEM.L ($0900).W,D0-D1
      poke_w(23'h000881, 16'h0003);
      poke_w(23'h000882, SW_SRC[15:0]);
      poke_w(23'h000883, 16'h48F8);           // 1106: MOVEM.L D0-D1,($0910).W
      poke_w(23'h000884, 16'h0003);
      poke_w(23'h000885, SW_DST[15:0]);
      poke_w(23'h000886, 16'h60FE);           // 110C
      poke_l(SW_DST[23:1],         32'h0000_0000);
      poke_l(SW_DST[23:1] + 23'd2, 32'h0000_0000);
    end
  endtask

  // One episode. `half_clocks` is how long after the first cycle's AS the
  // request goes in; `three_wire` picks the protocol.
  //
  // BR is driven a quarter of a clock after an edge rather than on one: it is
  // an asynchronous input with a synchroniser behind it, and a testbench that
  // changes it exactly when the synchroniser samples it is testing the
  // simulator's scheduler, not the processor.
  task automatic grant_episode(input int half_clocks, input bit three_wire,
                               output bit released);
    int k;
    begin
      released = 1'b0;
      wait (as_n_o === 1'b0 && a_o === SW_SRC[23:1]);
      for (k = 0; k < half_clocks; k = k + 1) @(clk);
      #(CLK_PERIOD / 4.0);
      br_n_i = 1'b0;
      wait (bg_n_o === 1'b0);

      // The buses are not the master's until the cycle in flight has finished
      // and AS is negated (figure 5-18 note 2), so wait for that rather than
      // for the grant.
      for (k = 0; (k < 40) && !released; k = k + 1) begin
        @(posedge clk);
        if (a_oe === 1'b0) released = 1'b1;
      end
      master_drive = released;

      if (three_wire) begin
        bgack_n_i = 1'b0;
        wait (bg_n_o === 1'b1);
        br_n_i = 1'b1;
        repeat (4) @(posedge clk);
        master_drive = 1'b0;
        bgack_n_i = 1'b1;
      end else begin
        repeat (4) @(posedge clk);
        master_drive = 1'b0;
        br_n_i = 1'b1;
      end
    end
  endtask

  task automatic sweep_grant();
    int  off, w;
    bit  three_wire, released;
    logic [31:0] got_hi, got_lo;
    int  n_released;
    begin
      n_released = 0;
      for (w = 0; w < 4; w = w + 1) begin
        three_wire = w[0];
        for (off = 0; off < 24; off = off + 1) begin
          core_reset();
          mem.clear();
          if (w[1]) load_movem(); else load_long();
          core_start();
          grant_episode(off, three_wire, released);
          if (released) n_released = n_released + 1;
          run_until_pc(w[1] ? (SW_PC + 32'd12) : (SW_PC + 32'd8), 4000);

          got_hi = {mem.peek(SW_DST[23:1]), mem.peek(SW_DST[23:1] + 23'd1)};
          got_lo = {mem.peek(SW_DST[23:1] + 23'd2),
                    mem.peek(SW_DST[23:1] + 23'd3)};
          if ((got_hi !== SW_VAL[63:32]) ||
              (w[1] && (got_lo !== SW_VAL[31:0]))) begin
            $display("FAIL: %s, %s grant %0d half clocks in: stored %08h %08h, \
expected %08h %08h", w[1] ? "MOVEM.L" : "MOVE.L",
                     three_wire ? "three-wire" : "two-wire", off,
                     got_hi, got_lo, SW_VAL[63:32],
                     w[1] ? SW_VAL[31:0] : 32'h0000_0000);
            errors = errors + 1;
          end
        end
      end

      // A sweep in which the bus was never actually handed over would pass
      // without testing anything.
      if (n_released < 80) begin
        $display("FAIL: the bus was only released in %0d of 96 episodes, so \
the sweep proves little", n_released);
        errors = errors + 1;
      end else begin
        $display("  the grant sweep handed the bus over in %0d of 96 episodes",
                 n_released);
      end
    end
  endtask

  initial begin
    errors = 0;
    master_drive = 1'b0;

    // ---- The same program, undisturbed -------------------------------------
    core_reset();
    mem.clear();
    load();
    core_start();
    run_until_pc(DONE, 2000);
    check_result("quiet run");

    n_quiet = ntr;
    for (i = 0; i < ntr; i = i + 1) begin
      q_addr[i] = tr_addr[i];
      q_fc[i]   = tr_fc[i];
      q_rw[i]   = tr_rw[i];
    end
    if (n_quiet < 8) begin
      $display("FAIL: the quiet run only made %0d bus cycles, so the \
comparison below would prove nothing", n_quiet);
      errors = errors + 1;
    end

    // ---- The same program, with the bus taken away in the middle -----------
    core_reset();
    mem.clear();
    load();
    core_start();

    repeat (16) @(posedge clk);          // well into the program
    br_n_i = 1'b0;
    wait (bg_n_o === 1'b0);

    // Not immediately: figure 5-18 note 2 releases the buses once the grant is
    // out *and* AS is negated, and UM 5.2.1 says the processor finishes the
    // cycle it is in first. A request landing mid-cycle therefore holds the
    // buses for a few more clocks, which is the interesting half of the rule
    // and the half a testbench driving an idle bus never sees.
    if (a_oe !== 1'b0) begin
      $display("  buses still driven when BG went out, as they should be if a cycle was in flight");
    end
    i = 0;
    while ((a_oe !== 1'b0) && (i < 40)) begin
      @(posedge clk);
      i = i + 1;
    end
    expect_u32("granted: the buses are released once the cycle ends",
               {28'd0, a_oe, as_oe, ds_oe, fc_oe}, 32'd0);

    // Three-wire: the alternate master takes the bus and holds it a while.
    bgack_n_i = 1'b0;
    wait (bg_n_o === 1'b1);
    br_n_i    = 1'b1;

    as_during_grant = 0;
    fork
      begin : watch_as
        forever begin
          @(negedge as_n_o);
          as_during_grant = as_during_grant + 1;
        end
      end
    join_none
    repeat (20) @(posedge clk);
    disable watch_as;
    // Two things stop a cycle here and only one of them is covered: the bus
    // unit sits in ST_ARB, which has no arm that starts one, and `arb_hold`
    // separately suppresses the request. Tying `arb_hold` low fails nothing in
    // the suite, so what it guards -- the window between the request being seen
    // and the bus actually being handed over -- is not reached by any test
    // here. It is not dead logic, it is untested logic, and the difference
    // matters if anyone is tempted to remove it.
    expect_int("granted: the processor starts no cycle", as_during_grant, 0);
    expect_u32("granted: the buses stay released",
               {28'd0, a_oe, as_oe, ds_oe, fc_oe}, 32'd0);

    bgack_n_i = 1'b1;                    // and gives it back
    wait (fc_oe === 1'b1);

    run_until_pc(DONE, 4000);
    check_result("after arbitration");

    // The point of the whole file: the same cycles, in the same order.
    expect_int("arbitration changed no bus cycle count", ntr, n_quiet);
    for (i = 0; (i < ntr) && (i < n_quiet); i = i + 1) begin
      if ((tr_addr[i] !== q_addr[i]) || (tr_fc[i] !== q_fc[i]) ||
          (tr_rw[i] !== q_rw[i])) begin
        $display("FAIL: cycle %0d differs: %06h fc=%0d %s, quiet run had \
%06h fc=%0d %s", i, {tr_addr[i], 1'b0}, tr_fc[i], tr_rw[i] ? "read" : "write",
                 {q_addr[i], 1'b0}, q_fc[i], q_rw[i] ? "read" : "write");
        errors = errors + 1;
      end
    end

    sweep_grant();

    core_done("core_arb_tb");
  end

endmodule
