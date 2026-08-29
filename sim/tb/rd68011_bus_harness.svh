// Shared harness for the RD68011 bus testbenches.
//
// Instantiates rd68011_biu, wires a real three-state data bus between the core
// and the slave models (so a stuck output enable shows up as an X rather than
// being quietly ignored), and records every pin on every clock edge.
//
// THE STATE RULER
//
// Observations are indexed by half-clock tick. A test calls one of the
// bus_* tasks, which returns t0, the tick of the rising edge that begins S0.
// obs[t0 + k] is then the pin state during state Sk -- sampled SNAP after the
// edge that begins it, which is where a delay-free model has settled.
//
// This is the check the manual's figures actually support: figure 10-4's
// horizontal axis is the source's own S0..S7 ruler, so "AS asserts in S2" is a
// fact recoverable from the drawing.
//
// It is a check against the figure, and the figure is stricter than the
// specification. The nanosecond limits in ac-electrical-specifications.csv
// permit placements this harness rejects -- at 10 MHz, specifications 6 and 11
// between them put AS anywhere in the second half of S2 -- and whether *any*
// assignment of pad delays satisfies them all is a separate question with an
// exact answer. sim/tb/timing/ asks it and doc/ac-timing.md has the results.
// Both checks are kept: this one says the design matches what the manual draws,
// that one says it matches what the manual requires, and they are not the same
// statement.

`ifndef RD68011_BUS_HARNESS_SVH
`define RD68011_BUS_HARNESS_SVH

  localparam realtime CLK_PERIOD = 125.0;   // 8 MHz, the slowest documented grade
  localparam realtime SNAP       = 5.0;     // sample this long after each edge
  localparam int      OBSN       = 1024;

  // Observation bit positions.
  localparam int OB_ASN   = 0;
  localparam int OB_UDSN  = 1;
  localparam int OB_LDSN  = 2;
  localparam int OB_RW    = 3;
  localparam int OB_DOE   = 4;
  localparam int OB_AOE   = 5;
  localparam int OB_ASOE  = 6;
  localparam int OB_DSOE  = 7;
  localparam int OB_RWOE  = 8;
  localparam int OB_FCOE  = 9;
  localparam int OB_VMAN  = 10;
  localparam int OB_VMAOE = 11;
  localparam int OB_E     = 12;
  localparam int OB_BGN   = 13;

  logic clk;
  logic rst_n;
  int   errors;

  // Sequencer request interface.
  //
  // req_valid is a wire, not a variable: the bus unit starts the next cycle at
  // the same rising edge that ends this one if req_valid is still asserted
  // (figure 5-3), so a one-shot request has to drop on req_last, which the bus
  // unit raises combinationally at the start of the cycle's last state. A real
  // sequencer has exactly the same information at exactly the same moment.
  logic        req_pending;
  logic        req_chain;      // hold the request through the acknowledge
  // Declared before req_valid reads it: Questa rejects a variable used above
  // its declaration, where iverilog and Verilator invent an implicit net.
  logic        req_last;
  wire         req_valid = req_pending && !(req_last && !req_chain);
  logic  [2:0] req_kind;
  logic  [2:0] req_fc;
  logic [23:1] req_addr;
  logic        req_uds;
  logic        req_lds;
  logic [15:0] req_wdata;
  logic        req_ack;
  logic [15:0] req_rdata;
  logic  [2:0] req_end;
  // The signal the sequencer actually acts on, so it is what the tests check.
  // req_end is a clock later and so is only a report: a cycle that sets req_end
  // to CE_BERR without ever raising req_fault faults nothing at all.
  logic        req_fault;
  logic        req_fault_wr;
  // Sticky, because req_fault is asserted for one falling edge inside the cycle
  // and a test looks at it after bus_finish() has returned.
  logic        req_fault_seen;
  logic        reset_req;
  logic        reset_busy;
  logic  [2:0] ipl_sync_n;
  logic        reset_sync_n;
  logic        halt_sync_n;
  logic        bus_idle;
  logic        dbf;

  // Pins.
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

  // Testbench overrides, wire-ORed onto the pins with the slave models.
  logic        tb_dtack_n;
  logic        tb_berr_n;
  logic        tb_halt_n;
  logic        tb_vpa_n;

  rd68011_biu dut (
      .clk (clk), .rst_n (rst_n),
      .req_valid (req_valid), .req_kind (req_kind), .req_fc (req_fc),
      .req_addr (req_addr), .req_uds (req_uds), .req_lds (req_lds),
      .req_wdata (req_wdata), .req_ack (req_ack), .req_last (req_last),
      .req_rdata (req_rdata), .req_end (req_end),
      .req_fault (req_fault), .req_fault_wr (req_fault_wr),
      .reset_req (reset_req), .reset_busy (reset_busy),
      .ipl_sync_n (ipl_sync_n), .reset_sync_n (reset_sync_n),
      .halt_sync_n (halt_sync_n), .bus_idle (bus_idle), .dbf (dbf),
      .a_o (a_o), .a_oe (a_oe),
      .d_i (d_i), .d_o (d_o), .d_oe (d_oe),
      .as_n_o (as_n_o), .as_oe (as_oe), .rw_o (rw_o), .rw_oe (rw_oe),
      .uds_n_o (uds_n_o), .lds_n_o (lds_n_o), .ds_oe (ds_oe),
      .dtack_n_i (dtack_n_i),
      .br_n_i (br_n_i), .bg_n_o (bg_n_o), .bgack_n_i (bgack_n_i),
      .ipl_n_i (ipl_n_i), .berr_n_i (berr_n_i),
      .reset_n_i (reset_n_i), .reset_n_o (reset_n_o), .reset_n_oe (reset_n_oe),
      .halt_n_i (halt_n_i), .halt_n_o (halt_n_o), .halt_n_oe (halt_n_oe),
      .e_o (e_o), .vpa_n_i (vpa_n_i), .vma_n_o (vma_n_o), .vma_oe (vma_oe),
      .fc_o (fc_o), .fc_oe (fc_oe)
  );

  // -- The three-state data bus, as an external wrapper would build it --------
  wire [15:0] dbus;
  logic [15:0] slv_d_out;
  logic        slv_d_oe;
  logic        slv_dtack_n, slv_vpa_n;

  assign dbus = d_oe     ? d_o       : 16'bz;
  assign dbus = slv_d_oe ? slv_d_out : 16'bz;
  assign d_i  = dbus;

  // Termination signals are wire-ORed: the slave's, plus the testbench's.
  assign dtack_n_i = slv_dtack_n & tb_dtack_n;
  assign vpa_n_i   = slv_vpa_n   & tb_vpa_n;
  assign berr_n_i  = tb_berr_n;
  assign halt_n_i  = tb_halt_n;

  // The address the slave sees is the pin, which is only valid while driven.
  wire [23:1] abus;
  assign abus = a_oe ? a_o : 23'bx;

  logic [7:0] slv_waits;
  logic       slv_m6800;

  rd68011_slave #(.BASE (23'h000000), .MASK (23'h400000)) slv (
      .clk (clk), .rst_n (rst_n),
      .waits (slv_waits), .m6800 (slv_m6800),
      .a (abus), .as_n (as_n_o), .uds_n (uds_n_o), .lds_n (lds_n_o),
      .rw (rw_o), .fc (fc_o),
      .d_in (dbus), .d_out (slv_d_out), .d_oe (slv_d_oe),
      .dtack_n (slv_dtack_n), .vpa_n (slv_vpa_n)
  );

  // -- Clock ------------------------------------------------------------------
  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2.0) clk = ~clk;
  end

  // -- Watchdog ---------------------------------------------------------------
  // A test that waits on an edge that never comes must fail, not run forever.
  initial begin
    #(CLK_PERIOD * 20000);
    $display("FAIL: timeout after %0d clocks", 20000);
    $finish;
  end

  // req_fault is asserted for one falling edge inside the cycle, so a test that
  // looks at it after bus_finish() would always see zero. Latched here, cleared
  // by bus_start.
  initial req_fault_seen = 1'b0;
  always @(posedge req_fault) req_fault_seen = 1'b1;

  // -- Observation ------------------------------------------------------------
  int          etick;
  logic [15:0] obs   [0:OBSN-1];
  logic [23:1] obs_a [0:OBSN-1];
  logic [15:0] obs_d [0:OBSN-1];
  logic  [2:0] obs_fc[0:OBSN-1];

  initial begin
    etick = 0;
    forever begin
      @(clk);
      #(SNAP);
      obs[etick % OBSN] = '0;
      obs[etick % OBSN][OB_ASN]   = as_n_o;
      obs[etick % OBSN][OB_UDSN]  = uds_n_o;
      obs[etick % OBSN][OB_LDSN]  = lds_n_o;
      obs[etick % OBSN][OB_RW]    = rw_o;
      obs[etick % OBSN][OB_DOE]   = d_oe;
      obs[etick % OBSN][OB_AOE]   = a_oe;
      obs[etick % OBSN][OB_ASOE]  = as_oe;
      obs[etick % OBSN][OB_DSOE]  = ds_oe;
      obs[etick % OBSN][OB_RWOE]  = rw_oe;
      obs[etick % OBSN][OB_FCOE]  = fc_oe;
      obs[etick % OBSN][OB_VMAN]  = vma_n_o;
      obs[etick % OBSN][OB_VMAOE] = vma_oe;
      obs[etick % OBSN][OB_E]     = e_o;
      obs[etick % OBSN][OB_BGN]   = bg_n_o;
      obs_a [etick % OBSN] = a_o;
      obs_d [etick % OBSN] = d_o;
      obs_fc[etick % OBSN] = fc_o;
      etick = etick + 1;
    end
  end

  function automatic logic ob(input int t, input int b);
    ob = obs[t % OBSN][b];
  endfunction

  // -- Checking ---------------------------------------------------------------
  string sname [0:13];

  task automatic expect_bit(input string what, input int t0, input int state,
                            input int b, input logic want);
    if (ob(t0 + state, b) !== want) begin
      $display("FAIL: %s should be %b in S%0d, is %b",
               what, want, state, ob(t0 + state, b));
      errors = errors + 1;
    end
  endtask

  task automatic expect_eq(input string what, input int got, input int want);
    if (got != want) begin
      $display("FAIL: %s is %0d, expected %0d", what, got, want);
      errors = errors + 1;
    end
  endtask

  task automatic expect_val(input string what, input logic [31:0] got,
                            input logic [31:0] want);
    if (got !== want) begin
      $display("FAIL: %s is %h, expected %h", what, got, want);
      errors = errors + 1;
    end
  endtask

  // Check that a signal is asserted in exactly the inclusive state range
  // [first, last] of a cycle and negated in the states either side of it.
  task automatic expect_window(input string what, input int t0, input int b,
                               input logic active,
                               input int first, input int last);
    int s;
    begin
      if (first > 0) begin
        if (ob(t0 + first - 1, b) === active) begin
          $display("FAIL: %s already %b in S%0d, should assert in S%0d",
                   what, active, first - 1, first);
          errors = errors + 1;
        end
      end
      for (s = first; s <= last; s = s + 1) begin
        if (ob(t0 + s, b) !== active) begin
          $display("FAIL: %s not %b in S%0d", what, active, s);
          errors = errors + 1;
        end
      end
      if (ob(t0 + last + 1, b) === active) begin
        $display("FAIL: %s still %b in S%0d, should negate after S%0d",
                 what, active, last + 1, last);
        errors = errors + 1;
      end
    end
  endtask

  // -- Stimulus ---------------------------------------------------------------

  // Start a bus cycle and return the tick of its S0 rising edge. The request is
  // presented on a falling edge, which is where a sequencer would present it,
  // and held until the acknowledge.
  task automatic bus_start(input logic [2:0] kind, input logic [2:0] fc,
                           input logic [23:1] addr,
                           input logic uds, input logic lds,
                           input logic [15:0] wdata,
                           output int t0);
    begin
      req_fault_seen = 1'b0;
      @(negedge clk);
      req_kind    = kind;
      req_fc      = fc;
      req_addr    = addr;
      req_uds     = uds;
      req_lds     = lds;
      req_wdata   = wdata;
      req_pending = 1'b1;
      @(posedge clk);
      t0 = etick;
    end
  endtask

  task automatic bus_finish();
    begin
      @(posedge req_ack);
      @(negedge clk);
      req_pending = 1'b0;
      req_chain   = 1'b0;
    end
  endtask

  // A complete cycle: start, wait for the acknowledge, drop the request.
  task automatic bus_cycle(input logic [2:0] kind, input logic [2:0] fc,
                           input logic [23:1] addr,
                           input logic uds, input logic lds,
                           input logic [15:0] wdata,
                           output int t0);
    begin
      bus_start(kind, fc, addr, uds, lds, wdata, t0);
      bus_finish();
    end
  endtask

  // Wait until the observation for state `s` of the cycle beginning at t0 has
  // been taken. Stimulus applied here lands just after the start of that state,
  // which meets specification 47 for the falling edge that ends it.
  task automatic wait_state(input int t0, input int s);
    wait (etick == t0 + s + 1);
  endtask

  task automatic harness_reset();
    begin
      errors      = 0;
      rst_n       = 1'b0;
      req_pending = 1'b0;
      req_chain   = 1'b0;
      req_kind    = rd68011_pkg::CT_READ;
      req_fc     = rd68011_pkg::FC_SUPER_D;
      req_addr   = '0;
      req_uds    = 1'b0;
      req_lds    = 1'b0;
      req_wdata  = '0;
      reset_req  = 1'b0;
      dbf        = 1'b0;
      br_n_i     = 1'b1;
      bgack_n_i  = 1'b1;
      ipl_n_i    = 3'b111;
      reset_n_i  = 1'b1;
      tb_dtack_n = 1'b1;
      tb_berr_n  = 1'b1;
      tb_halt_n  = 1'b1;
      tb_vpa_n    = 1'b1;
      slv_waits   = SLAVE_WAITS;
      slv_m6800   = SLAVE_M6800;
      repeat (4) @(posedge clk);
      @(negedge clk);
      rst_n = 1'b1;
      repeat (2) @(posedge clk);
    end
  endtask

  task automatic harness_done(input string name);
    begin
      if (errors == 0) $display("PASS: %s", name);
      else             $display("FAIL: %s, %0d error(s)", name, errors);
      $finish;
    end
  endtask

`endif
