// E clock testbench.
//
// UM section 3.7: "A single period of clock E consists of 10 MC68000 clock
// periods (six clocks low, four clocks high). [...] The E signal is a
// free-running clock that runs regardless of the state of the MPU bus."
//
// Specifications 50 and 51 (E width high / E width low, figure 10-6) are the
// same statement in nanoseconds: at 8 MHz, >= 450 ns high and >= 700 ns low,
// which 4 and 6 clock periods of 125 ns satisfy with margin.

`timescale 1ns/1ps

module e_clock_tb;

  localparam realtime CLK_PERIOD = 125.0;   // 8 MHz, the slowest documented grade
  localparam int      PERIODS    = 4;       // E periods to observe

  logic clk;
  logic rst_n;

  // Pins we do not drive yet.
  logic [23:1] a_o;
  logic        a_oe;
  logic [15:0] d_i, d_o;
  logic        d_oe;
  logic        as_n_o, as_oe, rw_o, rw_oe, uds_n_o, lds_n_o, ds_oe;
  logic        dtack_n_i, br_n_i, bg_n_o, bgack_n_i;
  logic  [2:0] ipl_n_i;
  logic        berr_n_i, reset_n_i, reset_n_o, reset_n_oe;
  logic        halt_n_i, halt_n_o, halt_n_oe;
  logic        e_o, vpa_n_i, vma_n_o, vma_oe;
  logic  [2:0] fc_o;
  logic        fc_oe;

  int errors;

  rd68011_top dut (
      .clk (clk), .rst_n (rst_n),
      .a_o (a_o), .a_oe (a_oe),
      .d_i (d_i), .d_o (d_o), .d_oe (d_oe),
      .as_n_o (as_n_o), .as_oe (as_oe),
      .rw_o (rw_o), .rw_oe (rw_oe),
      .uds_n_o (uds_n_o), .lds_n_o (lds_n_o), .ds_oe (ds_oe),
      .dtack_n_i (dtack_n_i),
      .br_n_i (br_n_i), .bg_n_o (bg_n_o), .bgack_n_i (bgack_n_i),
      .ipl_n_i (ipl_n_i),
      .berr_n_i (berr_n_i),
      .reset_n_i (reset_n_i), .reset_n_o (reset_n_o), .reset_n_oe (reset_n_oe),
      .halt_n_i (halt_n_i), .halt_n_o (halt_n_o), .halt_n_oe (halt_n_oe),
      .e_o (e_o), .vpa_n_i (vpa_n_i), .vma_n_o (vma_n_o), .vma_oe (vma_oe),
      .fc_o (fc_o), .fc_oe (fc_oe)
  );

  // Clock ---------------------------------------------------------------------
  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2.0) clk = ~clk;
  end

  // Checks --------------------------------------------------------------------
  task automatic check_width(input string what, input realtime got,
                             input real want_clks);
    realtime want;
    begin
      want = want_clks * CLK_PERIOD;
      if (got != want) begin
        $display("FAIL: E %s width %0.1f ns, expected %0.1f ns (%0.0f clocks)",
                 what, got, want, want_clks);
        errors = errors + 1;
      end else begin
        $display("  E %s: %0.1f ns = %0.0f clocks  ok", what, got, want_clks);
      end
    end
  endtask

  realtime t_rise, t_fall, t_rise2;
  int      i;
  logic    e_before;

  initial begin
    errors    = 0;
    rst_n     = 1'b0;
    d_i       = '0;
    dtack_n_i = 1'b1;
    br_n_i    = 1'b1;
    bgack_n_i = 1'b1;
    ipl_n_i   = 3'b111;
    berr_n_i  = 1'b1;
    reset_n_i = 1'b1;
    halt_n_i  = 1'b1;
    vpa_n_i   = 1'b1;

    // E must be low out of reset, not undefined: nothing here initialises at
    // declaration, so this also proves the reset path covers e_o and e_cnt.
    repeat (3) @(posedge clk);
    if (e_o !== 1'b0) begin
      $display("FAIL: E is %b during reset, expected 0", e_o);
      errors = errors + 1;
    end

    @(negedge clk);
    rst_n = 1'b1;

    $display("E clock, %0.1f ns period (%0.2f MHz):", CLK_PERIOD, 1000.0 / CLK_PERIOD);

    for (i = 0; i < PERIODS; i = i + 1) begin
      @(posedge e_o); t_rise  = $realtime;
      @(negedge e_o); t_fall  = $realtime;
      @(posedge e_o); t_rise2 = $realtime;
      check_width("high",   t_fall  - t_rise, 4.0);
      check_width("low",    t_rise2 - t_fall, 6.0);
      check_width("period", t_rise2 - t_rise, 10.0);
    end

    // Transitions follow the falling edge of CLK (specification 41,
    // "Clock Low to E Transition"), so E must be stable across every rising
    // edge of CLK. Sample E just before and just after a posedge.
    for (i = 0; i < 20; i = i + 1) begin
      @(negedge clk);
      #(CLK_PERIOD / 4.0) e_before = e_o; // mid-low phase, after any E transition
      @(posedge clk);
      #(CLK_PERIOD / 4.0);                // mid-high phase
      if (e_o !== e_before) begin
        $display("FAIL: E changed across a rising clock edge at %0t", $realtime);
        errors = errors + 1;
      end
    end

    if (errors == 0) $display("PASS: e_clock_tb");
    else             $display("FAIL: e_clock_tb, %0d error(s)", errors);
    $finish;
  end

endmodule
