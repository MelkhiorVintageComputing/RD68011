// The bisections themselves, shared by the two setup/hold testbenches.
//
// Separated from rd68011_setup_tb.sv only so that the Suska testbench is the
// same file with a different processor in it. rd68011_setup_tb.sv says what the
// measurement is for and why it asserts what it asserts.

`ifndef RD68011_SETUP_BODY_SVH
`define RD68011_SETUP_BODY_SVH

  // The knobs, by number, because a task cannot be handed a reference to one of
  // the slave's variables in a way all four simulators agree about.
  localparam int K_DTACK_ASSERT = 0;   // specification 47
  localparam int K_DATA_VALID   = 1;   // specification 27
  localparam int K_DATA_INVALID = 2;   // specification 29
  localparam int K_DTACK_NEGATE = 3;   // specification 28
  localparam int K_BERR_AFTER   = 4;   // specifications 48*, 27A

  string image;
  int    ncyc;
  real   resolution;

  // The acknowledge delay every trial starts from. Normally quick, so that a
  // cycle takes no wait states and the measurement is of the processor. The
  // specification 28 measurement deliberately makes it slow -- see there.
  real   base_dtack_assert;

  logic [23:1] g_addr [0:MAXTR-1];
  int          g_n;
  real         g_span;
  // How far apart this design's bus cycles actually are. The search ranges are
  // scaled to it rather than to the clock period, because the two processors
  // being measured have bus cycles of different lengths and a range that is
  // generous for one can fall short for the other -- which it did: four clock
  // periods covers our read-data latch point and not the other core's, and a
  // bisection whose ends behave alike reports nothing rather than the truth.
  real         g_spacing;

  task automatic knob_defaults();
    begin
      u_slave.dtack_assert_ns = base_dtack_assert;
      u_slave.dtack_negate_ns =   0.0;
      u_slave.data_valid_ns   =  25.0;
      u_slave.data_invalid_ns =   5.0;
      u_slave.data_hiz_ns     =  10.0;
      u_slave.vpa_assert_ns   =  -1.0;
      u_slave.berr_assert_ns  =  -1.0;
      u_slave.berr_after_ns   =  -1.0;
      u_slave.berr_negate_ns  =   0.0;
    end
  endtask

  task automatic set_knob(input int id, input real v);
    begin
      case (id)
        K_DTACK_ASSERT: u_slave.dtack_assert_ns = v;
        K_DATA_VALID:   u_slave.data_valid_ns   = v;
        K_DATA_INVALID: u_slave.data_invalid_ns = v;
        K_DTACK_NEGATE: u_slave.dtack_negate_ns = v;
        K_BERR_AFTER:   u_slave.berr_after_ns   = v;
        default: ;
      endcase
    end
  endtask

  // The golden run: generous timings everywhere, so that what it records is the
  // program and not the slave.
  task automatic take_golden();
    begin
      knob_defaults();
      timing_trial(image, ncyc);
      g_n = (ntr > ncyc) ? ncyc : ntr;
      for (int i = 0; i < g_n; i = i + 1) g_addr[i] = tr_addr[i];
      g_span    = tr_time[g_n - 1] - tr_time[0];
      g_spacing = (g_n > 1) ? (g_span / (g_n - 1)) : (clk_hi_ns + clk_lo_ns);
      $display("# golden: %0d cycles spanning %0.3f ns, %0.3f ns apart",
               g_n, g_span, g_spacing);
    end
  endtask

  // Did this trial do what the golden one did? Same addresses in the same
  // order, and the same length.
  //
  // The length has to be compared in both directions, which is not obvious. A
  // missed acknowledge costs a wait state and makes the run *longer*; an
  // acknowledge left asserted from the previous cycle terminates the next one
  // early and makes it *shorter*. Testing only for longer -- which is the
  // natural thing to write -- silently passes every stale-acknowledge trial and
  // reports the processor as tolerating anything.
  task automatic matches_golden(output bit ok);
    real span, diff;
    begin
      ok = 1'b1;
      if (ntr < g_n) ok = 1'b0;
      for (int i = 0; i < g_n; i = i + 1)
        if (tr_addr[i] !== g_addr[i]) ok = 1'b0;
      if (ok) begin
        span = tr_time[g_n - 1] - tr_time[0];
        diff = (span > g_span) ? (span - g_span) : (g_span - span);
        if (diff > 1.0) ok = 1'b0;
      end
    end
  endtask

  task automatic trial(input int id, input real v, output bit ok);
    begin
      knob_defaults();
      set_knob(id, v);
      timing_trial(image, ncyc);
      matches_golden(ok);
    end
  endtask

  // Find where the behaviour changes between `lo` and `hi`. `ok_at_lo` says
  // which end is expected to work, so the same code does a setup time (early is
  // fine, late is not) and a hold time (late is fine, early is not).
  //
  // Returns the last value on the working side, which is the threshold. If the
  // far end works too there is no threshold in range, and that is reported
  // rather than bisected into a meaningless number.
  task automatic bisect(input int id, input real lo, input real hi,
                        input bit ok_at_lo, output real thresh,
                        output bit found);
    real a, b, m;
    bit  ok_a, ok_b, ok_m;
    begin
      trial(id, lo, ok_a);
      trial(id, hi, ok_b);
      found  = 1'b0;
      thresh = ok_at_lo ? hi : lo;
      if (ok_a == ok_b) begin
        // Both ends behave the same: nothing changes across the range.
      end else if (ok_a != ok_at_lo) begin
        $display("# warning: the ends are the wrong way round for knob %0d", id);
      end else begin
        found = 1'b1;
        a = lo;
        b = hi;
        while ((b - a) > resolution) begin
          m = (a + b) / 2.0;
          trial(id, m, ok_m);
          if ($test$plusargs("tracebisect"))
            $display("BISECT id=%0d a=%0.3f b=%0.3f m=%0.3f ok=%0d",
                     id, a, b, m, ok_m);
          if (ok_m == ok_at_lo) a = m; else b = m;
        end
        thresh = ok_at_lo ? a : b;
      end
    end
  endtask

  // The clock edge that acted on an input which arrived at `t` nanoseconds
  // after AS asserted. Both processors assert AS on a clock edge, so the edges
  // after it fall on multiples of the half period; the acting one is the first
  // strictly later than the last arrival that still worked, and the difference
  // is the setup the processor actually needs.
  function automatic real acting_edge(input real t);
    real half, e;
    begin
      half = (clk_hi_ns + clk_lo_ns) / 2.0;
      e = half;
      while (e <= t + 1.0e-6) e = e + half;
      acting_edge = e;
    end
  endfunction

  // A plain scan across the range, printing whether each point matched. The
  // bisection assumes the answer changes once and stays changed; when a result
  // looks wrong this is what shows whether that assumption holds.
  task automatic scan(input string what, input int id,
                      input real lo, input real hi, input int steps);
    real v;
    bit  ok;
    begin
      for (int i = 0; i <= steps; i = i + 1) begin
        v = lo + ((hi - lo) * i) / steps;
        trial(id, v, ok);
        $display("SCAN %s %0.3f %0d", what, v, ok);
      end
    end
  endtask

  task automatic measure_setup(input string spec, input string what,
                               input int id, input real lo, input real hi);
    real thresh, edge_ns;
    bit  found;
    begin
      bisect(id, lo, hi, 1'b1, thresh, found);
      if (!found) begin
        $display("MEASURE %s %s none %0.3f nothing changed between %0.3f and %0.3f",
                 spec, what, thresh, lo, hi);
      end else begin
        edge_ns = acting_edge(thresh);
        $display("MEASURE %s %s latest %0.3f edge %0.3f setup %0.3f",
                 spec, what, thresh, edge_ns, edge_ns - thresh);
      end
    end
  endtask

  task automatic measure_hold(input string spec, input string what,
                              input int id, input real lo, input real hi);
    real thresh;
    bit  found, ok;
    begin
      // A hold time is the other way round: holding longer is safer. If the
      // shortest hold in range already works, the requirement is at or below
      // it and there is nothing to bisect.
      trial(id, lo, ok);
      if (ok) begin
        $display("MEASURE %s %s atmost %0.3f", spec, what, lo);
      end else begin
        bisect(id, lo, hi, 1'b0, thresh, found);
        if (!found)
          $display("MEASURE %s %s none %0.3f nothing changed between %0.3f and %0.3f",
                   spec, what, thresh, lo, hi);
        else
          $display("MEASURE %s %s needs %0.3f", spec, what, thresh);
      end
    end
  endtask

  // How long an input may stay asserted past the end of a cycle before the
  // processor mistakes it for the next one's. Here the processor is the one
  // that has to tolerate the specification's maximum, so a larger number is
  // better and the assertion runs the other way.
  task automatic measure_tolerance(input string spec, input string what,
                                   input int id, input real lo, input real hi);
    real thresh;
    bit  found, ok;
    begin
      bisect(id, lo, hi, 1'b1, thresh, found);
      if (!found) begin
        trial(id, hi, ok);
        if (ok) $display("MEASURE %s %s tolerates %0.3f atleast", spec, what, hi);
        else    $display("MEASURE %s %s tolerates %0.3f atmost", spec, what, lo);
      end else begin
        $display("MEASURE %s %s tolerates %0.3f", spec, what, thresh);
      end
    end
  endtask

  task automatic setup_main(input string which);
    real period;
    begin
      timing_config();
      if (!$value$plusargs("image=%s", image)) image = "bus_probe.hex";
      if (!$value$plusargs("trialcycles=%d", ncyc)) ncyc = 12;
      if (!$value$plusargs("resolution=%f", resolution)) resolution = 0.05;
      period = clk_hi_ns + clk_lo_ns;
      base_dtack_assert = 20.0;

      $display("# design=%s period=%0.3f hi=%0.3f lo=%0.3f resolution=%0.3f",
               which, period, clk_hi_ns, clk_lo_ns, resolution);

      take_golden();

      if ($test$plusargs("scan")) begin
        scan("dtack",  K_DTACK_ASSERT, 0.0, 2.0 * g_spacing, 24);
        scan("datain", K_DATA_VALID,   0.0, 2.0 * g_spacing, 24);
      end

      // 47: how late DTACK may arrive, measured from AS asserting, and the
      //     clock edge that therefore acts on it.
      measure_setup("47", "dtack", K_DTACK_ASSERT, 0.0, 2.0 * g_spacing);

      // 27: the same for read data, which is latched later than the
      //     acknowledge is sampled, so the range has to reach further.
      measure_setup("27", "datain", K_DATA_VALID, 0.0, 2.0 * g_spacing);

      // 29: how soon read data may be taken away after the strobes negate.
      measure_hold("29", "datain", K_DATA_INVALID, 0.0, period);

      // 28: how long DTACK may stay asserted after the strobes negate before
      //     the processor takes it for the next cycle's acknowledge.
      //
      // With a slave that answers every cycle promptly this cannot be measured
      // at all: an acknowledge left over from the last cycle and one given
      // immediately for this one produce the same bus, so there is nothing to
      // detect. The trick is to make the slave slow first. Against a golden run
      // that takes wait states, a stale acknowledge terminates the next cycle
      // early and shortens it, which is visible.
      base_dtack_assert = 2.0 * period;
      take_golden();
      measure_tolerance("28", "dtack", K_DTACK_NEGATE, 0.0, 3.0 * g_spacing);
      base_dtack_assert = 20.0;

      $display("PASS: setup measurements for %s", which);
      $finish;
    end
  endtask

`endif
