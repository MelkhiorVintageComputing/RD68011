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
  localparam logic [31:0] IRQ_H = 32'h0000_1100;  // the level 7 handler

  int i;
  int n_quiet;
  logic [23:1] q_addr [0:MAXTR-1];
  logic  [2:0] q_fc   [0:MAXTR-1];
  logic        q_rw   [0:MAXTR-1];

  int as_during_grant;
  // Whether the processor actually *wanted* the bus while it did not have
  // it. Without this, "no cycle started" is satisfied by a processor that
  // was not asking for one, and the check is vacuous.
  int req_during_grant;
  int irq_grant_want, irq_grant_idle;
  // At module scope rather than forked inside the task: iverilog aborts on a
  // join_none in an automatic task, and a gated always block says the same
  // thing with less machinery.
  logic watch_as_on;
  always @(negedge as_n_o) if (watch_as_on) as_during_grant = as_during_grant + 1;

  // The alternate master, as far as this file needs one: something that drives
  // the data bus while it owns it. Without it a re-latch during the grant
  // shows up as high impedance, which is a weaker signal than wrong data --
  // and on a real board there is no such thing as a quiet bus during DMA.
  localparam logic [15:0] MASTER_D = 16'h0E66;
  logic master_drive;
  assign dbus = master_drive ? MASTER_D : 16'bz;


  // ---------------------------------------------------------------------------
  // An interrupt arriving while another master owns the bus
  //
  // Everything above interrupts nothing. But a machine with DMA in it takes
  // interrupts during DMA constantly, and an interrupt is the one event that
  // makes the processor want the bus for something it did not ask for: an
  // acknowledge cycle in CPU space, a vector read, a frame push and a refill,
  // none of which the microcode was already running when the bus went away.
  //
  // Two things have to hold. The processor must start no cycle while the bus is
  // someone else's -- and it must *want* one, or that proves nothing, so
  // `req_valid` is watched too and a run where the processor never asked is a
  // failure. Then the interrupt has to be taken once the bus comes back, and
  // the interrupted program has to finish.
  //
  // The arrival point is swept in half-clock steps at two memory latencies,
  // because the state the grant lands in decides which arm of the bus unit
  // holds it off.
  //
  // What this does *not* do is fail. Four injections were tried and none of
  // them made it: tying `arb_hold` low; letting ST_ARB reach ST_S0 directly;
  // reordering the ST_IDLE arm to start a cycle before testing the grant; and
  // masking IPL while the bus is away. Once BGACK is out, ST_ARB has no arm
  // that reaches ST_S0 and both the ST_IDLE arm and `after_cycle` test the
  // grant before the request, so by then the ordering alone enforces this. The
  // fourth is not a defect at all: UM 3.5 requires the level to be held until
  // acknowledged, so an interrupt masked during the grant is simply taken when
  // the bus returns, which is what this asserts anyway.
  //
  // None of that says anything about `arb_hold`, whose window closes before
  // this test opens -- see `irq_with_br` below, which aims at it directly.
  //
  // So this is a regression test and not a gate, and it is worth keeping as
  // one: it asserts end to end that an interrupt arriving during DMA is
  // neither lost nor served early, and that the interrupted program finishes.
  // Anything that breaks the deferral in a way the ordering does not already
  // prevent will fire it.
  // ---------------------------------------------------------------------------
  task automatic irq_grant_once(input int delay_half, input logic [7:0] waits);
    begin
      core_reset();
      mem.clear();
      load();
      poke_l(23'h00003E, IRQ_H);              // autovector 31, level 7
      poke_w(IRQ_H[23:1] + 23'd0, 16'h31FC);  // MOVE.W #$4444,($0906).W
      poke_w(IRQ_H[23:1] + 23'd1, 16'h4444);
      poke_w(IRQ_H[23:1] + 23'd2, 16'h0906);
      poke_w(IRQ_H[23:1] + 23'd3, 16'h4E73);  // and back, so the program finishes
      poke_w(23'h000483, 16'h0000);
      mem_waits = waits;
      core_start();

      repeat (12) @(posedge clk);
      repeat (delay_half) @(clk);             // half-clock steps
      br_n_i = 1'b0;
      wait (bg_n_o === 1'b0);
      i = 0;
      while ((a_oe !== 1'b0) && (i < 120)) begin
        @(posedge clk);
        i = i + 1;
      end
      bgack_n_i    = 1'b0;
      wait (bg_n_o === 1'b1);
      br_n_i       = 1'b1;
      master_drive = 1'b1;

      // ... and only now does the interrupt arrive.
      ipl_n_i          = ~3'd7;
      as_during_grant  = 0;
      req_during_grant = 0;
      watch_as_on      = 1'b1;
      for (i = 0; i < 40; i = i + 1) begin
        @(posedge clk);
        if (dut.u_seq.req_valid) req_during_grant = req_during_grant + 1;
      end
      watch_as_on = 1'b0;
      if (as_during_grant != 0) begin
        $display("FAIL: interrupt during a grant (+%0d half, %0d waits): the \
processor started %0d cycle(s) on someone else's bus", delay_half, waits,
                 as_during_grant);
        errors = errors + 1;
      end
      if (req_during_grant == 0) irq_grant_idle = irq_grant_idle + 1;
      else                       irq_grant_want = irq_grant_want + 1;
      if ((a_oe !== 1'b0) || (as_oe !== 1'b0) || (ds_oe !== 1'b0) ||
          (fc_oe !== 1'b0)) begin
        $display("FAIL: interrupt during a grant (+%0d half): the buses are \
driven", delay_half);
        errors = errors + 1;
      end

      master_drive = 1'b0;
      bgack_n_i    = 1'b1;                    // and gives it back
      wait (fc_oe === 1'b1);

      run_until_pc(IRQ_H, 8000);
      ipl_n_i = 3'b111;                       // one interrupt, not a stream
      run_until_pc(DONE, 8000);
      mem_waits = 8'd0;
      expect_u32("interrupt during a grant: the handler ran once the bus came back",
                 {16'd0, mem.peek(23'h000483)}, 32'h0000_4444);
      expect_u32("interrupt during a grant: autovector 31",
                 {16'd0, mem.peek((SSP0 - 32'd8 + 32'd6) >> 1)},
                 {22'd0, 8'd31, 2'b00});
      // And the program's own work completes: an interrupt it did not ask for,
      // taken across a bus it did not own, costs it time and nothing else.
      check_result("interrupt during a grant");
    end
  endtask

  // The other window, and the one the sweep above does not reach: the interrupt
  // and the bus request arrive *together*.
  //
  // `arb_hold` is asserted the moment the arbiter leaves ARB_IDLE -- as soon as
  // BR is seen -- which is before the buses are released and therefore before
  // `arb_bus_released_nxt` guards anything. Between those two the ordering in
  // the state machine does nothing and `arb_hold` is the only thing stopping a
  // new cycle. An interrupt landing there is the way to ask: the acknowledge
  // cycle is one the processor wants and was not already running.
  //
  // Measured rather than merely asserted, because the number says how wide the
  // window is: one cycle starts at zero wait states and none at six. That one
  // is the synchroniser's shadow -- BR takes two clocks to become visible and a
  // cycle may legitimately start in them -- so more than one would mean a cycle
  // started after the request was seen.
  task automatic irq_with_br(input logic [7:0] waits, output int started);
    int n;
    begin
      core_reset();
      mem.clear();
      load();
      poke_l(23'h00003E, IRQ_H);
      poke_w(IRQ_H[23:1] + 23'd0, 16'h31FC);
      poke_w(IRQ_H[23:1] + 23'd1, 16'h4444);
      poke_w(IRQ_H[23:1] + 23'd2, 16'h0906);
      poke_w(IRQ_H[23:1] + 23'd3, 16'h4E73);
      poke_w(23'h000483, 16'h0000);
      mem_waits = waits;
      core_start();
      repeat (14) @(posedge clk);

      // Both at once.
      as_during_grant = 0;
      watch_as_on     = 1'b1;
      br_n_i          = 1'b0;
      ipl_n_i         = ~3'd7;
      n = 0;
      while ((a_oe !== 1'b0) && (n < 200)) begin
        @(posedge clk);
        n = n + 1;
      end
      watch_as_on = 1'b0;
      started     = as_during_grant;
      if (started > 1) begin
        $display("FAIL: interrupt with BR (%0d waits): %0d cycles started after \
the request was visible", waits, started);
        errors = errors + 1;
      end

      bgack_n_i    = 1'b0;
      wait (bg_n_o === 1'b1);
      br_n_i       = 1'b1;
      master_drive = 1'b1;
      repeat (20) @(posedge clk);
      master_drive = 1'b0;
      bgack_n_i    = 1'b1;
      wait (fc_oe === 1'b1);
      run_until_pc(IRQ_H, 8000);
      ipl_n_i = 3'b111;
      run_until_pc(DONE, 8000);
      mem_waits = 8'd0;
      check_result("interrupt with BR");
      expect_u32("interrupt with BR: the handler ran",
                 {16'd0, mem.peek(23'h000483)}, 32'h0000_4444);
    end
  endtask

  task automatic irq_grant_sweep();
    int d;
    begin
      irq_grant_want = 0;
      irq_grant_idle = 0;
      for (d = 0; d < 20; d = d + 1) irq_grant_once(d, 8'd0);
      for (d = 0; d < 12; d = d + 1) irq_grant_once(d, 8'd6);
      $display("  interrupt during a grant: %0d arrivals with a request \
outstanding, %0d with the processor idle", irq_grant_want, irq_grant_idle);
      // Both states are worth reaching and only one of them is the interesting
      // one: a request outstanding is what the hold-off has to suppress.
      if (irq_grant_want == 0) begin
        $display("FAIL: no arrival found the processor wanting the bus, so the \
sweep proves nothing");
        errors = errors + 1;
      end
    end
  endtask

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
    // Two things stop a cycle here and they cover different windows. Once the
    // grant is out and the buses are released, the ordering does it: the bus
    // unit sits in ST_ARB, which has no arm that starts a cycle, and both the
    // ST_IDLE arm and `after_cycle` test the grant before the request. Before
    // that -- from BR being seen until the buses are handed over -- only
    // `arb_hold` does, because `arb_bus_released_nxt` is still low.
    //
    // Tying `arb_hold` low still fails nothing here, and `irq_with_br` above
    // measures why: at zero wait states exactly one cycle starts after BR, and
    // that one is the synchroniser's shadow rather than anything `arb_hold`
    // could have stopped. So its window is real but at most a clock wide, and
    // no test in this file has been able to land a request inside it. That is
    // narrower than "untested logic" and it is still not "dead logic".
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

    irq_grant_sweep();

    begin
      int s0, s6;
      irq_with_br(8'd0, s0);
      irq_with_br(8'd6, s6);
      $display("  interrupt with BR: cycles started after BR and before the \
release: %0d at 0 waits, %0d at 6", s0, s6);
    end

    sweep_grant();

    core_done("core_arb_tb");
  end

endmodule
