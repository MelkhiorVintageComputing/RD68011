// Shared harness for the AC-timing testbenches.
//
// Included into a testbench module, like sim/tb/rd68011_bus_harness.svh and
// sim/tb/rd68011_core_harness.svh. It declares the pin bundle, puts pads with
// settable delays on the outputs, hangs a slave with nanosecond-timed answers
// off the bus, and writes an event log. What it deliberately does *not* do is
// instantiate a processor: each testbench supplies its own, which is the whole
// point -- our core and the Suska core are measured by the same instrument.
//
// WHAT IT MEASURES, AND WHY NOT IN BUS STATES
//
// Every other testbench here indexes observations by half-clock tick from the
// start of S0 and asserts against the S0-S7 ruler. That is the right instrument
// for asking whether this design does what UM section 5 draws, and the wrong one
// for asking whether it does what section 10 *requires*, for two reasons.
//
// The specifications are in nanoseconds against clock edges, not against bus
// states; and the other processor being measured has no S0-S7 ruler at all --
// its bus cycle is two clocks where the manual's is four. A tick index is not a
// common scale. Nanoseconds from a clock edge is.
//
// So the log carries times and nothing else. It does not know what a
// specification is, which two events one measures between, or what the limits
// are; tools/timing/ knows all three, and can be corrected without re-running a
// simulation. tools/timing/specs.py explains why the split falls there.
//
// THE CLOCK IS NOT NECESSARILY SYMMETRIC
//
// Specification 1 fixes the cycle time and specifications 2 and 3 the pulse
// width, and together they permit a duty cycle of 44 to 56 per cent at 8 MHz.
// This design uses both clock edges -- one bus state per half period -- so an
// asymmetric clock moves half its state boundaries, and no existing testbench
// can express that. +clk_hi and +clk_lo set the two halves independently.

`ifndef RD68011_TIMING_HARNESS_SVH
`define RD68011_TIMING_HARNESS_SVH

  // -- Clock ------------------------------------------------------------------
  real clk_hi_ns, clk_lo_ns;
  int  tb_timeout;
  int  tb_cycles;          // stop after this many bus cycles
  int  tb_reset_clocks;    // RESET+HALT held this long; Suska needs twenty

  logic clk;

  // -- The pin bundle. Outputs are driven by whichever processor the testbench
  //    instantiates; inputs are driven here.
  wire [23:1] a_o;
  wire        a_oe;
  wire [15:0] d_o;
  wire        d_oe;
  wire        as_n_o, as_oe;
  wire        rw_o, rw_oe;
  wire        uds_n_o, lds_n_o, ds_oe;
  wire        vma_n_o, vma_oe;
  wire  [2:0] fc_o;
  wire        fc_oe;
  wire        bg_n_o, e_o;
  wire        reset_n_o, reset_n_oe, halt_n_o, halt_n_oe;

  logic       rst_n;
  logic       reset_n_i, halt_n_i;
  logic [2:0] ipl_n_i;
  logic       br_n_i, bgack_n_i;
  logic       vpa_n_i;

  // -- The bus, as a slave sees it: after the pads.
  wire [23:1] a_pad;
  wire [15:0] d_pad;
  wire        as_n_pad, rw_pad, uds_n_pad, lds_n_pad, vma_n_pad;
  wire  [2:0] fc_pad;
  wire        bg_n_pad, e_pad;

  // The pad delays are parameters of the *testbench*, not of this include,
  // because iverilog's -P only reaches the root module and xelab's
  // -generic_top likewise. Each testbench declares the same sixteen and they
  // are forwarded here; tools/timing/corners.py emits the command line.
  rd68011_pads #(
      .P_A_VALID    (P_A_VALID),    .P_A_HIZ      (P_A_HIZ),
      .P_FC_VALID   (P_FC_VALID),
      .P_AS_ASSERT  (P_AS_ASSERT),  .P_AS_NEGATE  (P_AS_NEGATE),
      .P_DS_ASSERT  (P_DS_ASSERT),  .P_DS_NEGATE  (P_DS_NEGATE),
      .P_RW_LOW     (P_RW_LOW),     .P_RW_HIGH    (P_RW_HIGH),
      .P_DOUT_VALID (P_DOUT_VALID), .P_DOUT_HIZ   (P_DOUT_HIZ),
      .P_VMA_ASSERT (P_VMA_ASSERT), .P_VMA_NEGATE (P_VMA_NEGATE),
      .P_BG_ASSERT  (P_BG_ASSERT),  .P_BG_NEGATE  (P_BG_NEGATE),
      .P_E          (P_E)
  ) u_pads (
      .a_o (a_o), .a_oe (a_oe), .d_o (d_o), .d_oe (d_oe),
      .as_n_o (as_n_o), .as_oe (as_oe),
      .rw_o (rw_o), .rw_oe (rw_oe),
      .uds_n_o (uds_n_o), .lds_n_o (lds_n_o), .ds_oe (ds_oe),
      .vma_n_o (vma_n_o), .vma_oe (vma_oe),
      .fc_o (fc_o), .fc_oe (fc_oe),
      .bg_n_o (bg_n_o), .e_o (e_o),
      .a_pad (a_pad), .d_pad (d_pad),
      .as_n_pad (as_n_pad), .rw_pad (rw_pad),
      .uds_n_pad (uds_n_pad), .lds_n_pad (lds_n_pad),
      .vma_n_pad (vma_n_pad), .fc_pad (fc_pad),
      .bg_n_pad (bg_n_pad), .e_pad (e_pad)
  );

  wire [15:0] slv_d_out;
  wire        slv_d_oe;
  wire        slv_dtack_n, slv_vpa_n, slv_berr_n;

  rd68011_slave_ac #(
      .ADDR_BITS (14), .BASE (23'h000000), .MASK (23'h400000)
  ) u_slave (
      .a (a_pad), .as_n (as_n_pad), .uds_n (uds_n_pad), .lds_n (lds_n_pad),
      .rw (rw_pad), .fc (fc_pad),
      .d_in (d_pad), .d_out (slv_d_out), .d_oe (slv_d_oe),
      .dtack_n (slv_dtack_n), .vpa_n (slv_vpa_n), .berr_n (slv_berr_n)
  );

  assign d_pad = slv_d_oe ? slv_d_out : 16'bz;

  // The processor's inputs come off the bus, undelayed: the specifications that
  // govern them are setup and hold times measured at the pin, and the slave
  // above is what places them.
  wire [15:0] d_i     = d_pad;
  wire        dtack_n_i = slv_dtack_n;
  wire        berr_n_i  = slv_berr_n;

  // -- The log ----------------------------------------------------------------
  //
  // Times are printed with %0.3f and never with %t: the format %t produces is
  // simulator-dependent, and $timeformat is global state a harness should not be
  // reaching for. Three kinds of line, plus GLITCH from the pad model:
  //
  //   CLK  <ns> <rise|fall> tick=<n>
  //   EV   <ns> <SIGNAL> <transition> [<value>]
  //   BUS  <ns> addr=<hex> fc=<n> rw=<n>
  //
  // Nothing here decides what a transition means for a specification. A bus
  // changing from one valid value to another emits one `change`; the analyser
  // reads that as the old value going invalid and the new becoming valid at the
  // same instant, which is what a directly-switched bus does.
  int  ntr;         // bus cycles seen
  int  tick;        // half-clock index from the end of reset
  logic logging;    // print the log
  logic capturing;  // count and record cycles

  // Recording the cycles as well as printing them, because the setup and hold
  // measurements work by running the same program a few dozen times with an
  // input moved a little each time and asking whether anything changed. That
  // needs the transaction list in a variable, and does not want sixty logs.
  localparam int MAXTR = 256;
  logic [23:1] tr_addr [0:MAXTR-1];
  logic        tr_rw   [0:MAXTR-1];
  real         tr_time [0:MAXTR-1];

  // Macros rather than tasks. One shared automatic task called from a dozen
  // concurrent always blocks is the natural way to write this and it makes the
  // Vivado simulator's kernel abort at time zero with an internal error --
  // "an exceptional condition from which it cannot recover", naming the always
  // block rather than anything wrong with it. Expanding the same two lines at
  // each call site costs nothing and runs everywhere.
`define EV_S(SIG, TXT) \
    if (logging) $display("EV   %0.3f %s %s", $realtime, SIG, TXT)

`define EV_B(SIG, VAL, HIZ)                                              \
    if (logging) begin                                                   \
      if (HIZ) $display("EV   %0.3f %s hiz", $realtime, SIG);            \
      else     $display("EV   %0.3f %s change %0h", $realtime, SIG, VAL); \
    end

  always @(posedge clk) begin
    if (logging) $display("CLK  %0.3f rise tick=%0d", $realtime, tick);
    tick = tick + 1;
  end
  always @(negedge clk) begin
    if (logging) $display("CLK  %0.3f fall tick=%0d", $realtime, tick);
    tick = tick + 1;
  end

  always @(as_n_pad)
    `EV_S("AS", (as_n_pad === 1'b0) ? "assert" :
                (as_n_pad === 1'b1) ? "negate" : "x");

  // UM table 3-1 gives the byte lanes; for the width specifications 14 and 14A
  // what matters is whether *a* data strobe is asserted, so the two pins are
  // reported both individually and as the pair the manual calls DS.
  wire ds_n_pad = uds_n_pad & lds_n_pad;
  always @(ds_n_pad)
    `EV_S("DS", (ds_n_pad === 1'b0) ? "assert" :
                (ds_n_pad === 1'b1) ? "negate" : "x");
  always @(uds_n_pad)
    `EV_S("UDS", (uds_n_pad === 1'b0) ? "assert" : "negate");
  always @(lds_n_pad)
    `EV_S("LDS", (lds_n_pad === 1'b0) ? "assert" : "negate");

  always @(rw_pad)
    `EV_S("RW", (rw_pad === 1'b1) ? "high" :
                (rw_pad === 1'b0) ? "low"  : "x");

  always @(vma_n_pad)
    `EV_S("VMA", (vma_n_pad === 1'b0) ? "assert" : "negate");

  always @(a_pad)  `EV_B("A",  {9'd0, a_pad},  (a_pad  === 23'bz));
  always @(fc_pad) `EV_B("FC", {29'd0, fc_pad}, (fc_pad === 3'bz));

  // The data bus is two different signals depending on who is driving it, and
  // the specifications treat them separately -- 23, 25, 26, 53 and 55 are about
  // DOUT and 27, 29, 29A and 31 about DIN. The output enable says which.
  // Sensitive to the bus alone, and not also to the two output enables. An
  // enable and the value it gates change in the same instant but in different
  // delta cycles, so a block woken by both reports the bus twice -- once while
  // it is still the old value. That is the delta-cycle artefact this whole
  // harness observes on the pad side to avoid, and it would have been
  // reintroduced here. Which of the two is driving is read at the moment the
  // bus moves, which is when it is true.
  always @(d_pad) begin
    if (d_oe === 1'b1)          begin `EV_B("DOUT", {16'd0, d_pad}, (d_pad === 16'bz)); end
    else if (slv_d_oe === 1'b1) begin `EV_B("DIN",  {16'd0, d_pad}, (d_pad === 16'bz)); end
    else                        begin `EV_B("D",    {16'd0, d_pad}, (d_pad === 16'bz)); end
  end

  always @(slv_dtack_n)
    `EV_S("DTACK", (slv_dtack_n === 1'b0) ? "assert" : "negate");
  always @(slv_berr_n)
    `EV_S("BERR", (slv_berr_n === 1'b0) ? "assert" : "negate");

  // One line per bus cycle, so the analyser can group events into cycles
  // without knowing anything about either design's state machine.
  always @(negedge as_n_pad) begin
    if (capturing) begin
      if (ntr < MAXTR) begin
        tr_addr[ntr] = a_pad;
        tr_rw[ntr]   = rw_pad;
        tr_time[ntr] = $realtime;
      end
      if (logging)
        $display("BUS  %0.3f addr=%06h fc=%0d rw=%0d",
                 $realtime, {a_pad, 1'b0}, fc_pad, rw_pad);
      ntr = ntr + 1;
    end
  end

  // -- Setup ------------------------------------------------------------------
  task automatic timing_config();
    real period;
    begin
      if (!$value$plusargs("clk_hi=%f", clk_hi_ns)) clk_hi_ns = -1.0;
      if (!$value$plusargs("clk_lo=%f", clk_lo_ns)) clk_lo_ns = -1.0;
      if (!$value$plusargs("period=%f", period))    period    = 125.0;
      if (clk_hi_ns < 0.0) clk_hi_ns = period / 2.0;
      if (clk_lo_ns < 0.0) clk_lo_ns = period - clk_hi_ns;
      if (!$value$plusargs("timeout=%d", tb_timeout))     tb_timeout = 20000;
      if (!$value$plusargs("cycles=%d", tb_cycles))       tb_cycles  = 40;
      if (!$value$plusargs("reset=%d", tb_reset_clocks))  tb_reset_clocks = 20;
    end
  endtask

  initial begin
    clk = 1'b0;
    forever begin
      #(clk_lo_ns) clk = 1'b1;
      #(clk_hi_ns) clk = 1'b0;
    end
  end

  initial begin
    #(1.0);
    #((clk_hi_ns + clk_lo_ns) * tb_timeout);
    $display("FAIL: timeout after %0d clocks", tb_timeout);
    $finish;
  end

  // RESET and HALT asserted together is what resets an MC68010 (UM 5.5). The
  // Suska core needs twenty clock periods of it rather than the manual's ten --
  // measured, and recorded in doc/suska-crosscheck.md -- so the length is a
  // knob and both processors get the longer one, which disadvantages neither.
  task automatic timing_reset();
    begin
      logging   = 1'b0;
      capturing = 1'b0;
      ntr       = 0;
      tick      = 0;
      rst_n     = 1'b0;
      reset_n_i = 1'b0;
      halt_n_i  = 1'b0;
      ipl_n_i   = 3'b111;
      br_n_i    = 1'b1;
      bgack_n_i = 1'b1;
      vpa_n_i   = 1'b1;
      repeat (4) @(posedge clk);
      rst_n = 1'b1;
      repeat (tb_reset_clocks) @(posedge clk);
      reset_n_i = 1'b1;
      halt_n_i  = 1'b1;
    end
  endtask

  // `design` would be a natural name for the first argument and is a
  // SystemVerilog keyword, reserved for config declarations.
  task automatic timing_run(input string which, input string corner);
    begin
      $display("# design=%s corner=%s period=%0.3f hi=%0.3f lo=%0.3f",
               which, corner, clk_hi_ns + clk_lo_ns, clk_hi_ns, clk_lo_ns);
      tick      = 0;
      ntr       = 0;
      capturing = 1'b1;
      logging   = 1'b1;
      while (ntr < tb_cycles) @(posedge clk);
      logging   = 1'b0;
      capturing = 1'b0;
      $display("# cycles=%0d", ntr);
    end
  endtask

  // The same run with nothing printed: reset the processor, reload the image so
  // that a program which writes to memory starts from the same place every
  // time, and record `n` bus cycles. A trial is deterministic, so two trials
  // that differ differ because of the one input timing that was moved.
  task automatic timing_trial(input string image, input int n);
    real t0, budget;
    begin
      timing_reset();
      u_slave.reset();
      u_slave.clear();
      $readmemh(image, u_slave.mem);
      ntr       = 0;
      capturing = 1'b1;
      logging   = 1'b0;
      // Bounded from the start of *this* trial, not in absolute time. A trial
      // whose input arrives so late that the processor never latches anything
      // useful can wander off and stop issuing cycles altogether, and that is a
      // perfectly good answer -- it did not match the golden run -- but only if
      // the trial gives up. Bounded absolutely instead, the first such trial
      // eats the whole simulation.
      t0     = $realtime;
      budget = (clk_hi_ns + clk_lo_ns) * 20.0 * n;
      while ((ntr < n) && (($realtime - t0) < budget)) @(posedge clk);
      capturing = 1'b0;
    end
  endtask

`endif
