// Wait states and the read-modify-write cycle.
//
// Wait states, UM 5.1.1 state 4: "If neither termination signal is asserted
// before the falling edge at the end of S4, the processor inserts wait states
// (full clock cycles) until either DTACK or BERR is asserted." Figure 5-3 draws
// a two-wait-state read as S0 S1 S2 S3 S4 w w w w S5 S6 S7 -- the waits are
// whole clocks inserted between S4 and S5, so n wait states make the cycle
// 8 + 2n bus states long and hold AS one state longer per half-clock.
//
// Read-modify-write, UM 5.1.3: S0..S7 read, S8..S11 modify, S12..S19 write,
// with AS asserted throughout to make the cycle indivisible. R/W goes low on
// the rising edge of S14, the data bus is driven in S15, and the data strobes
// reassert on the rising edge of S16.

`timescale 1ns/1ps

module bus_wait_rmw_tb;

  localparam int   SLAVE_WAITS = 0;
  localparam logic SLAVE_M6800 = 1'b0;

`include "rd68011_bus_harness.svh"

  int t0;
  int n;
  int s;
  int last;

  initial begin
    harness_reset();
    slv.poke(23'h002000, 16'h5A5A);

    // ---- Wait states, zero through four ------------------------------------
    for (n = 0; n <= 4; n = n + 1) begin
      slv_waits = n[7:0];
      last      = 7 + 2 * n;

      bus_cycle(rd68011_pkg::CT_READ, rd68011_pkg::FC_SUPER_D,
                23'h002000, 1'b1, 1'b1, 16'h0000, t0);

      // AS holds from S2 until the falling edge entering the final state.
      expect_window($sformatf("%0d-wait read AS", n), t0, OB_ASN, 1'b0, 2, last - 1);
      expect_window($sformatf("%0d-wait read UDS", n), t0, OB_UDSN, 1'b0, 2, last - 1);
      expect_val($sformatf("%0d-wait read data", n),
                 {16'd0, req_rdata}, {16'd0, 16'h5A5A});
      expect_val($sformatf("%0d-wait read end", n),
                 {29'd0, req_end}, {29'd0, rd68011_pkg::CE_DTACK});

      // And the write side inserts them in the same place.
      bus_cycle(rd68011_pkg::CT_WRITE, rd68011_pkg::FC_SUPER_D,
                23'h002001, 1'b1, 1'b1, 16'h0000 + n[15:0], t0);
      expect_window($sformatf("%0d-wait write AS", n), t0, OB_ASN, 1'b0, 2, last - 1);
      expect_window($sformatf("%0d-wait write DS", n), t0, OB_UDSN, 1'b0, 4, last - 1);
      expect_window($sformatf("%0d-wait write d_oe", n), t0, OB_DOE, 1'b1, 3, last);
      expect_val($sformatf("%0d-wait write stored", n),
                 {16'd0, slv.peek(23'h002001)}, {16'd0, 16'h0000 + n[15:0]});
    end

    // ---- Read-modify-write --------------------------------------------------
    slv_waits = 8'd0;
    slv.poke(23'h002010, 16'h0F00);

    // TAS-like: read, set bit 7 of the addressed byte, write back. The write
    // data only has to be valid by S15, which is what the four modify states
    // exist for; present it as soon as the read data appears.
    req_wdata = 16'h8F00;
    bus_cycle(rd68011_pkg::CT_RMW, rd68011_pkg::FC_SUPER_D,
              23'h002010, 1'b1, 1'b0, 16'h8F00, t0);

    // AS asserted from S2 right through to the falling edge entering S19.
    expect_window("RMW AS", t0, OB_ASN, 1'b0, 2, 18);

    // The read half's data strobe: S2..S6, negated entering S7.
    expect_window("RMW read UDS", t0, OB_UDSN, 1'b0, 2, 6);
    // Nothing happens on the bus during the four modify states.
    for (s = 8; s <= 11; s = s + 1) begin
      expect_bit("RMW modify UDS", t0, s, OB_UDSN, 1'b1);
      expect_bit("RMW modify R/W", t0, s, OB_RW,   1'b1);
      expect_bit("RMW modify AS",  t0, s, OB_ASN,  1'b0);
    end
    // S12, S13: still a read as far as the pins are concerned.
    expect_bit("RMW R/W in S13", t0, 13, OB_RW, 1'b1);
    // S14: R/W low. S15: data driven. S16: data strobes.
    expect_window("RMW R/W low", t0, OB_RW,   1'b0, 14, 19);
    expect_window("RMW d_oe",    t0, OB_DOE,  1'b1, 15, 19);
    expect_window("RMW write UDS", t0, OB_UDSN, 1'b0, 16, 18);

    expect_val("RMW read data", {16'd0, req_rdata}, {16'd0, 16'h0F00});
    expect_val("RMW stored",    {16'd0, slv.peek(23'h002010)}, {16'd0, 16'h8F00});

    // ---- Read-modify-write with a slow slave -------------------------------
    // The read half takes its two wait states. The write half takes none: this
    // slave keys DTACK off AS, which stays asserted across the whole
    // indivisible cycle, so the acknowledge is still there when S16 samples.
    // That is precisely what figure 5-9 draws -- S16 S17 S18 S19 with no waits
    // between them -- and it is why a read-modify-write is not simply two bus
    // cycles glued together.
    slv_waits = 8'd2;
    slv.poke(23'h002012, 16'h0000);
    bus_cycle(rd68011_pkg::CT_RMW, rd68011_pkg::FC_SUPER_D,
              23'h002012, 1'b1, 1'b1, 16'h1111, t0);
    // 12 states of read half, 4 of modify, 8 of write half: 24 in all, so the
    // last state is index 23 and AS is asserted from S2 to index 22.
    expect_window("waited RMW AS", t0, OB_ASN, 1'b0, 2, 22);
    expect_val("waited RMW stored", {16'd0, slv.peek(23'h002012)}, {16'd0, 16'h1111});

    harness_done("bus_wait_rmw_tb");
  end

endmodule
