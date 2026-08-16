// M6800 synchronous cycles: UM appendix B.
//
// When VPA is recognised instead of DTACK the cycle becomes synchronous with E,
// and its length depends entirely on where the recognition lands in E's period:
//
//   "After recognizing VPA, the processor assures that enable (E) is low by
//    waiting, if necessary, and subsequently asserts VMA. [...] The
//    synchronization delay is an integral number of system clock cycles within
//    the following extremes:
//      1. Best Case - the assertion of VPA is recognized on the falling edge
//         three clock cycles before E rises.
//      2. Worst Case - the assertion of VPA is recognized on the falling edge
//         two clock cycles before E rises."
//
// Read the two together with specification 43 (VMA asserted to E high, at least
// 200 ns at 8 MHz, which is 1.6 clocks) and the pair stops looking like a
// contradiction: three clocks before the rise is the last moment at which VMA
// can still be asserted in time for this E cycle. Two clocks before, it cannot,
// so the cycle waits out a whole E period instead -- which is why the later
// recognition is the *worse* case.
//
// The observable consequence is the wait-state count, and the manual draws it:
// figure B-4, best case, has six wait states; figure B-5, worst case, has
// fifteen. Sweeping the start phase across a whole E period must reproduce
// exactly that pair and nothing outside it.
//
// UM appendix B also fixes where the cycle ends: "the processor negates the
// address and data strobes one-half clock cycle later in state 7 (S7), and E
// goes low at this time."

`timescale 1ns/1ps

module bus_m6800_tb;

  localparam int   SLAVE_WAITS = 0;
  localparam logic SLAVE_M6800 = 1'b1;

`include "rd68011_bus_harness.svh"

  int t0, t1;
  int len, waits;
  int min_waits, max_waits;
  int phase;
  int s;
  int vma_first;

  initial begin
    harness_reset();
    slv_m6800 = 1'b1;
    slv.poke(23'h005000, 16'h00C3);

    min_waits = 1000;
    max_waits = -1;

    // Sweep the start of the cycle across a full E period, ten clocks, so every
    // possible phase relationship is covered.
    for (phase = 0; phase < 10; phase = phase + 1) begin
      repeat (phase) @(posedge clk);

      bus_start(rd68011_pkg::CT_READ, rd68011_pkg::FC_SUPER_D,
                23'h005000, 1'b1, 1'b1, 16'h0000, t0);
      bus_finish();
      t1  = etick;
      len = t1 - t0 - 1;          // states, S0 through the last

      // 8 + 2n states for n wait states.
      waits = (len - 8) / 2;
      if (waits < min_waits) min_waits = waits;
      if (waits > max_waits) max_waits = waits;

      // The data still arrives.
      expect_val($sformatf("phase %0d data", phase),
                 {16'd0, req_rdata}, {16'd0, 16'h00C3});
      expect_val($sformatf("phase %0d end code", phase),
                 {29'd0, req_end}, {29'd0, rd68011_pkg::CE_VPA});

      // E goes low as the cycle enters its last state, and was high in the one
      // before it -- the peripheral ran during E high.
      expect_bit($sformatf("phase %0d E in S6", phase), t0, len - 2, OB_E, 1'b1);
      expect_bit($sformatf("phase %0d E in S7", phase), t0, len - 1, OB_E, 1'b0);

      // VMA is asserted for the run-up to E and negated again entering S7.
      expect_bit($sformatf("phase %0d VMA in S6", phase), t0, len - 2, OB_VMAN, 1'b0);
      expect_bit($sformatf("phase %0d VMA in S7", phase), t0, len - 1, OB_VMAN, 1'b1);

      // AS holds to the falling edge entering the last state, as always.
      expect_window($sformatf("phase %0d AS", phase), t0, OB_ASN, 1'b0, 2, len - 2);

      // VMA is never asserted while E is high: it exists to tell the peripheral
      // the address is valid and synchronised *before* E rises.
      vma_first = -1;
      for (s = 0; s < len; s = s + 1) begin
        if ((ob(t0 + s, OB_VMAN) === 1'b0) && (vma_first < 0)) vma_first = s;
        if ((ob(t0 + s, OB_VMAN) === 1'b0) && (ob(t0 + s, OB_E) === 1'b1) &&
            (s < len - 1) && (vma_first == s)) begin
          $display("FAIL: phase %0d VMA first asserted while E is high, in S%0d",
                   phase, s);
          errors = errors + 1;
        end
      end
      if (vma_first < 0) begin
        $display("FAIL: phase %0d VMA never asserted", phase);
        errors = errors + 1;
      end

      $display("  phase %0d: %0d states, %0d wait states", phase, len, waits);
      repeat (2) @(posedge clk);
    end

    // Figures B-4 and B-5.
    expect_eq("best case wait states (figure B-4)",  min_waits, 6);
    expect_eq("worst case wait states (figure B-5)", max_waits, 15);

    // ---- Autovectored interrupt acknowledge (UM 5.1.4, appendix B.2) -------
    // "the interrupt acknowledge cycle can be autovectored. The interrupt
    // acknowledge cycle is the same, except the interrupting device asserts VPA
    // instead of DTACK."
    slv_m6800 = 1'b0;
    bus_start(rd68011_pkg::CT_IACK, rd68011_pkg::FC_CPU,
              23'h7FFFF5, 1'b1, 1'b1, 16'h0000, t0);
    wait_state(t0, 4);
    tb_vpa_n = 1'b0;
    bus_finish();
    tb_vpa_n = 1'b1;
    expect_val("autovector end code", {29'd0, req_end}, {29'd0, rd68011_pkg::CE_AVEC});
    expect_val("autovector function code", {29'd0, obs_fc[(t0 + 2) % OBSN]},
               {29'd0, rd68011_pkg::FC_CPU});

    // A vectored acknowledge, for contrast: DTACK, so the vector number on the
    // data bus is what counts (figure 5-11).
    tb_dtack_n = 1'b1;
    slv.poke(23'h005000, 16'h1234);
    bus_start(rd68011_pkg::CT_IACK, rd68011_pkg::FC_CPU,
              23'h7FFFF5, 1'b1, 1'b1, 16'h0000, t0);
    wait_state(t0, 4);
    tb_dtack_n = 1'b0;
    bus_finish();
    tb_dtack_n = 1'b1;
    expect_val("vectored acknowledge end code",
               {29'd0, req_end}, {29'd0, rd68011_pkg::CE_DTACK});

    harness_done("bus_m6800_tb");
  end

endmodule
