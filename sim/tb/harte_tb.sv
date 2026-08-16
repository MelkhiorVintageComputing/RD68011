// Run SingleStepTests reference vectors through the core.
//
//   make harte OP=NOP
//
// For each test: force the initial state, load the memory it names, run one
// instruction, and compare registers, prefetch, memory and the bus transaction
// list against what the reference recorded.
//
// The vectors were generated from an MC68000. Where an MC68010 must differ,
// tools/harte/divergences.md says so and the mismatch is expected -- a test
// whose only disagreement is a documented divergence is reported separately
// from one that is simply wrong.
//
// Forcing state rather than executing into it is deliberate: it isolates the
// instruction under test from everything before it, which is what makes a
// failure point at one opcode instead of at a program.

`timescale 1ns/1ps

module harte_tb;

  localparam realtime CLK_PERIOD = 125.0;
  localparam int      MAXTR      = 64;
  localparam int      MAXRAM     = 64;

  logic clk;
  logic rst_n;

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

  rd68011_top dut (
      .clk (clk), .rst_n (rst_n),
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

  wire  [15:0] dbus;
  logic [15:0] mem_d_out;
  logic        mem_d_oe;
  logic        mem_overflow;

  assign dbus = d_oe     ? d_o       : 16'bz;
  assign dbus = mem_d_oe ? mem_d_out : 16'bz;
  assign d_i  = dbus;

  wire [23:1] abus;
  assign abus = a_oe ? a_o : 23'bx;

  rd68011_vecmem #(.ENTRIES (128)) mem (
      .clk (clk), .rst_n (rst_n),
      .a (abus), .as_n (as_n_o), .uds_n (uds_n_o), .lds_n (lds_n_o),
      .rw (rw_o),
      .d_in (dbus), .d_out (mem_d_out), .d_oe (mem_d_oe),
      .dtack_n (dtack_n_i), .overflow (mem_overflow)
  );

  assign vpa_n_i = 1'b1;

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2.0) clk = ~clk;
  end

  // A second decoder, so the testbench can put the sequencer straight at the
  // entry point for the opcode under test without running an instruction first.
  logic [rd68011_ucode_pkg::UADDR-1:0] tb_entry;
  logic                                tb_illegal;
  logic                         [15:0] tb_opcode;

  rd68011_decode_rom u_tb_decode (
      .op (tb_opcode), .entry (tb_entry), .illegal (tb_illegal)
  );

  // -- Instruction completion, and the state at that moment -------------------
  //
  // The boundary is the edge on which the instruction's last microword retires
  // with the DECODE exit. Sampling after that edge is too late -- upc has moved
  // on to the next instruction's first microword -- and sampling before it is
  // too early, because the instruction's final register writes happen on it.
  //
  // So: latch `boundary` on the edge itself, and copy the registers out on the
  // edge after, which sees the values that edge wrote and nothing later.
  logic boundary;
  assign boundary = dut.u_seq.retire &&
                    (dut.u_seq.f_seq == rd68011_ucode_pkg::U_SEQ_DECODE);

  logic        cap_arm, cap_done;
  logic [31:0] cap_regs [0:15];
  logic [15:0] cap_sr, cap_ir, cap_irc;
  logic [31:0] cap_pc;
  int          ci;

  always @(posedge clk) begin
    if (cap_arm && !cap_done) begin
      for (ci = 0; ci < 16; ci = ci + 1) cap_regs[ci] <= dut.u_seq.regs[ci];
      cap_sr   <= dut.u_seq.sr;
      cap_pc   <= dut.u_seq.pc;
      cap_ir   <= dut.u_seq.ir;
      cap_irc  <= dut.u_seq.irc;
      cap_done <= 1'b1;
    end
    cap_arm <= boundary && !cap_done;
  end

  // -- Transaction recorder ---------------------------------------------------
  int          ntr;
  logic [23:1] tr_addr [0:MAXTR-1];
  logic  [2:0] tr_fc   [0:MAXTR-1];
  logic        tr_rw   [0:MAXTR-1];

  // Recording stops the moment the instruction is complete. The next
  // instruction starts on that same edge and asserts AS a clock later, which
  // is exactly when the runner freezes the core -- a race that showed up as a
  // spurious extra bus cycle on about one test in fifteen.
  // Triggered by a data strobe rather than by AS: a read-modify-write holds AS
  // across both of its halves (UM 5.1.3), so watching AS would record one
  // transaction where the reference records two.
  wire ds_active;
  assign ds_active = !uds_n_o || !lds_n_o;

  initial begin
    ntr = 0;
    forever begin
      @(posedge ds_active);
      if (ntr < MAXTR && !cap_arm && !cap_done) begin
        tr_addr[ntr] = a_o;
        tr_fc[ntr]   = fc_o;
        tr_rw[ntr]   = rw_o;
        ntr          = ntr + 1;
      end
    end
  end

  // -- Vector file ------------------------------------------------------------
  string vecfile;
  int    fh;
  int    ntests;
  int    limit;
  int    verbose;

  // Per-test data.
  int          idx;
  logic [31:0] ireg [0:18];
  logic [31:0] freg [0:18];
  logic [15:0] ipf0, ipf1, fpf0, fpf1;
  int          nram, nfram, nvtr;
  logic [22:0] ram_a  [0:MAXRAM-1];
  logic [15:0] ram_d  [0:MAXRAM-1];
  logic [22:0] fram_a [0:MAXRAM-1];
  logic [15:0] fram_d [0:MAXRAM-1];
  int          vtr_k  [0:MAXTR-1];
  int          vtr_fc [0:MAXTR-1];
  logic [22:0] vtr_a  [0:MAXTR-1];

  int t, i, j, r, nfail, npass, nskip, ndiverge, nunimpl;
  int firstfail;
  logic ok;
  logic skipped;
  string why;

  task automatic rd(output int v);
    int code;
    begin
      code = $fscanf(fh, "%h", v);
      if (code != 1) begin
        $display("FAIL: vector file ended early");
        $finish;
      end
    end
  endtask

  task automatic read_test();
    int v;
    begin
      rd(idx);
      for (i = 0; i < 19; i = i + 1) begin rd(v); ireg[i] = v; end
      rd(v); ipf0 = v[15:0];
      rd(v); ipf1 = v[15:0];
      rd(nram);
      for (i = 0; i < nram; i = i + 1) begin
        rd(v); ram_a[i] = v[22:0];
        rd(v); ram_d[i] = v[15:0];
      end
      for (i = 0; i < 19; i = i + 1) begin rd(v); freg[i] = v; end
      rd(v); fpf0 = v[15:0];
      rd(v); fpf1 = v[15:0];
      rd(nfram);
      for (i = 0; i < nfram; i = i + 1) begin
        rd(v); fram_a[i] = v[22:0];
        rd(v); fram_d[i] = v[15:0];
      end
      rd(nvtr);
      for (i = 0; i < nvtr; i = i + 1) begin
        rd(vtr_k[i]);
        rd(vtr_fc[i]);
        rd(v); vtr_a[i] = v[22:0];
      end
    end
  endtask

  // Load the forced state into the core. The register file is D0-D7 then
  // A0-A7; A7 is whichever stack pointer the S bit selects.
  task automatic load_state();
    begin
      for (i = 0; i < 15; i = i + 1) dut.u_seq.regs[i] = ireg[i];
      // The vectors carry USP and SSP separately; A7 is whichever one the
      // S bit of the status register selects. The other becomes live only
      // when MOVE USP or a mode change exists, which is P4.
      dut.u_seq.regs[15] = ireg[17][13] ? ireg[16] : ireg[15];
      dut.u_seq.sr       = ireg[17][15:0];
      dut.u_seq.pc       = ireg[18];
      dut.u_seq.ir       = ipf0;
      dut.u_seq.irc      = ipf1;
      // At an instruction boundary at address A: ir came from A, irc from A+2,
      // and pc is A+4.
      dut.u_seq.ir_pc    = ireg[18] - 32'd4;
      dut.u_seq.irc_pc   = ireg[18] - 32'd2;
      dut.u_seq.t0       = 32'd0;
      dut.u_seq.t1       = 32'd0;
      dut.u_seq.dbuf     = 16'd0;
      tb_opcode          = ipf0;
      #1;
      dut.u_seq.upc      = tb_entry;
    end
  endtask

  task automatic check_reg(input int i, input string name);
    begin
      if (cap_regs[i] !== freg[i]) begin
        if (verbose != 0 || firstfail == 0) begin
          $display("    %s is %08h, reference says %08h",
                   name, cap_regs[i], freg[i]);
        end
        ok = 1'b0;
      end
    end
  endtask

  string rn [0:15];

  initial begin
    rn[0]="D0"; rn[1]="D1"; rn[2]="D2"; rn[3]="D3";
    rn[4]="D4"; rn[5]="D5"; rn[6]="D6"; rn[7]="D7";
    rn[8]="A0"; rn[9]="A1"; rn[10]="A2"; rn[11]="A3";
    rn[12]="A4"; rn[13]="A5"; rn[14]="A6"; rn[15]="A7";

    if (!$value$plusargs("vec=%s", vecfile)) begin
      $display("FAIL: no +vec=<file> given");
      $finish;
    end
    if (!$value$plusargs("limit=%d", limit)) limit = 0;
    if (!$value$plusargs("verbose=%d", verbose)) verbose = 0;

    fh = $fopen(vecfile, "r");
    if (fh == 0) begin
      $display("FAIL: cannot open %s", vecfile);
      $finish;
    end

    br_n_i    = 1'b1;
    bgack_n_i = 1'b1;
    ipl_n_i   = 3'b111;
    berr_n_i  = 1'b1;
    halt_n_i  = 1'b1;
    reset_n_i = 1'b1;
    rst_n     = 1'b0;
    cap_arm   = 1'b0;
    cap_done  = 1'b0;
    repeat (4) @(posedge clk);

    rd(ntests);
    if (limit != 0 && limit < ntests) ntests = limit;

    nfail = 0; npass = 0; nskip = 0; firstfail = 0;
    ndiverge = 0; nunimpl = 0;

    for (t = 0; t < ntests; t = t + 1) begin
      read_test();

      // Where an MC68010 must differ from the MC68000 the vectors came from,
      // adjust the expectation rather than skip the test: everything else the
      // test checks is still worth checking.
      //
      // CLR on a memory destination is the case that matters here. UM section
      // 9's execution times give the MC68010 two cycles fewer for every memory
      // CLR, because it does not read an operand it is about to overwrite. So
      // the reference's operand read -- the only data-space read a CLR does --
      // is removed, and the write, the flags and the final state are compared
      // as usual. See doc/divergences.md.
      if (((ipf0 & 16'hFF00) == 16'h4200) && (ipf0[5:3] != 3'b000) &&
          (ipf0[7:6] != 2'b11)) begin
        j = 0;
        for (i = 0; i < nvtr; i = i + 1) begin
          if (!((vtr_k[i] == 2) && ((vtr_fc[i] == 1) || (vtr_fc[i] == 5)))) begin
            vtr_k[j]  = vtr_k[i];
            vtr_fc[j] = vtr_fc[i];
            vtr_a[j]  = vtr_a[i];
            j = j + 1;
          end
        end
        if (j != nvtr) begin
          nvtr     = j;
          ndiverge = ndiverge + 1;
        end
      end

      // An MC68010 does not run these the way an MC68000 did, or the test
      // exercises something not built yet. Skipped, and counted.
      skipped = 1'b0;
      why     = "";
      for (i = 0; i < nvtr; i = i + 1) begin
        if (vtr_k[i] >= 4) begin
          skipped = 1'b1;
          why     = "address error: exception processing is P4";
        end
      end
      if (tb_skip(ipf0, ireg[17][15:0])) begin
        skipped = 1'b1;
        why     = "documented MC68000/MC68010 divergence";
      end
      // Not built yet: the decoder has no pattern for it. Counted separately
      // from the divergences so a sweep says what is missing rather than
      // quietly passing.
      tb_opcode = ipf0;
      #1;
      if (tb_illegal) begin
        skipped = 1'b1;
        why     = "not implemented";
        nunimpl = nunimpl + 1;
      end

      if (skipped) begin
        nskip = nskip + 1;
      end else begin
        mem.clear();
        for (i = 0; i < nram; i = i + 1) mem.poke(ram_a[i], ram_d[i]);

        // Hold the core in reset across the changeover, so nothing left over
        // from the previous test is still in flight, then release it and force
        // this test's state before the next rising edge.
        rst_n = 1'b0;
        @(posedge clk);
        @(negedge clk);
        rst_n    = 1'b1;
        cap_arm  = 1'b0;
        cap_done = 1'b0;
        load_state();
        ntr = 0;

        // Run until the instruction is complete, or give up.
        r = 0;
        while (r < 400 && !cap_done) begin
          @(posedge clk);
          #1;
          r = r + 1;
        end

        // Freeze. The word after the instruction is whatever the vector's
        // memory happens to hold, and executing it could write to memory
        // before the comparison below reads it.
        rst_n = 1'b0;

        ok = 1'b1;
        if (!cap_done) begin
          if (firstfail == 0) $display("  test %0d: did not finish", idx);
          ok = 1'b0;
        end else begin
          for (i = 0; i < 15; i = i + 1) check_reg(i, rn[i]);
          // A7 is compared against whichever stack pointer is active.
          if (cap_regs[15] !== (ireg[17][13] ? freg[16] : freg[15])) begin
            if (firstfail == 0) begin
              $display("    A7 is %08h, reference says %08h", cap_regs[15],
                       ireg[17][13] ? freg[16] : freg[15]);
            end
            ok = 1'b0;
          end
          if ({16'd0, cap_sr} !== freg[17]) begin
            if (firstfail == 0) begin
              $display("    SR is %04h, reference says %04h",
                       cap_sr, freg[17][15:0]);
            end
            ok = 1'b0;
          end
          if (cap_pc !== freg[18]) begin
            if (firstfail == 0) begin
              $display("    pc is %08h, reference says %08h", cap_pc, freg[18]);
            end
            ok = 1'b0;
          end
          if (cap_ir !== fpf0 || cap_irc !== fpf1) begin
            if (firstfail == 0) begin
              $display("    prefetch is %04h %04h, reference says %04h %04h",
                       cap_ir, cap_irc, fpf0, fpf1);
            end
            ok = 1'b0;
          end
          for (i = 0; i < nfram; i = i + 1) begin
            if (mem.peek(fram_a[i]) !== fram_d[i]) begin
              if (firstfail == 0) begin
                $display("    memory at %06h is %04h, reference says %04h",
                         {fram_a[i], 1'b0}, mem.peek(fram_a[i]), fram_d[i]);
              end
              ok = 1'b0;
            end
          end
          // The bus cycles, in order.
          if (ntr !== nvtr) begin
            if (firstfail == 0) begin
              $display("    %0d bus cycles, reference says %0d", ntr, nvtr);
              for (i = 0; i < ntr; i = i + 1) begin
                $display("      ours %0d: %s fc=%0d %06h", i,
                         tr_rw[i] ? "read " : "write", tr_fc[i],
                         {tr_addr[i], 1'b0});
              end
              for (i = 0; i < nvtr; i = i + 1) begin
                $display("      ref  %0d: %s fc=%0d %06h", i,
                         (vtr_k[i] == 2) ? "read " : "write", vtr_fc[i],
                         {vtr_a[i], 1'b0});
              end
            end
            ok = 1'b0;
          end else begin
            for (i = 0; i < ntr; i = i + 1) begin
              if (tr_addr[i] !== vtr_a[i] || tr_fc[i] !== vtr_fc[i][2:0] ||
                  tr_rw[i] !== (vtr_k[i] == 2)) begin
                if (firstfail == 0) begin
                  $display("    cycle %0d: %s fc=%0d %06h, ref %s fc=%0d %06h",
                           i, tr_rw[i] ? "read " : "write", tr_fc[i],
                           {tr_addr[i], 1'b0},
                           (vtr_k[i] == 2) ? "read " : "write", vtr_fc[i],
                           {vtr_a[i], 1'b0});
                end
                ok = 1'b0;
              end
            end
          end
        end

        if (ok) begin
          npass = npass + 1;
        end else begin
          nfail = nfail + 1;
          if (firstfail == 0) begin
            $display("  first failure: test %0d, opcode %04h, sr %04h",
                     idx, ipf0, ireg[17][15:0]);
            firstfail = 1;
          end
          // A histogram of which opcode shapes fail is worth more than one
          // detailed case: it says whether a mode is broken or a corner is.
          if (nfail <= 12) begin
            $display("  failing opcode %04h  (src mode %0d reg %0d, "
                     , ipf0, ipf0[5:3], ipf0[2:0]);
            $display("                        dst mode %0d reg %0d)",
                     ipf0[8:6], ipf0[11:9]);
          end
        end
      end
    end

    $fclose(fh);
    $display("%s: %0d passed, %0d failed, %0d skipped (of %0d)",
             vecfile, npass, nfail, nskip, ntests);
    if (nskip > 0) begin
      $display("  skipped: %0d not implemented, %0d needing exceptions",
               nunimpl, nskip - nunimpl);
    end
    if (ndiverge > 0) begin
      $display("  %0d tests compared with a documented MC68010 divergence applied",
               ndiverge);
    end
    if (nfail == 0) $display("PASS: harte");
    else            $display("FAIL: harte");
    $finish;
  end

  // Divergences that make a vector inapplicable to an MC68010. Kept as a
  // function so the reason for each is next to its test.
  function automatic logic tb_skip(input logic [15:0] op, input logic [15:0] sr);
    begin
      tb_skip = 1'b0;
      // MOVE from SR is privileged on the MC68010 and not on the MC68000
      // (PRM section 6). A user-mode vector traps where the reference did not.
      if (((op & 16'hFFC0) == 16'h40C0) && !sr[13]) tb_skip = 1'b1;
    end
  endfunction

  // Watchdog.
  initial begin
    #(CLK_PERIOD * 4000000);
    $display("FAIL: timeout");
    $finish;
  end

endmodule
