// Read and write cycle timing.
//
// Checks the S0..S7 asynchronous cycle against UM 5.1.1 and 5.1.2 state by
// state, and against the state ruler recovered in figure 10-4 / 10-5:
//
//   STATE 0  valid function codes on FC2-FC0, R/W driven high
//   STATE 1  entering S1, a valid address on the address bus
//   STATE 2  on the rising edge, AS asserted; UDS/LDS too on a read;
//            R/W driven low on a write
//   STATE 3  on a write, the data bus is driven out of high impedance
//   STATE 4  on a write, the rising edge asserts UDS/LDS; the falling edge
//            samples DTACK, BERR and VPA
//   STATE 7  on the falling edge entering S7, data is latched and AS and the
//            data strobes are negated; at the rising edge that ends S7 the
//            data bus is released and R/W driven high
//
// Also covers wait states, byte lane selection (UM table 3-1), and that
// back-to-back cycles run four clocks apart with no idle state (figure 5-3).

`timescale 1ns/1ps

module bus_rw_tb;

  localparam int   SLAVE_WAITS = 0;
  localparam logic SLAVE_M6800 = 1'b0;

`include "rd68011_bus_harness.svh"

  int t0, t1;
  int s;

  // A read cycle: everything the manual says about S0..S7.
  task automatic check_read(input string tag, input int t0,
                            input logic uds, input logic lds);
    begin
      // S0: R/W high, function code out.
      expect_bit({tag, " R/W"}, t0, 0, OB_RW, 1'b1);
      expect_val({tag, " FC"}, {29'd0, obs_fc[t0 % OBSN]},
                 {29'd0, rd68011_pkg::FC_SUPER_D});

      // S2..S6 and the first half of S7: AS asserted.
      expect_window({tag, " AS"}, t0, OB_ASN, 1'b0, 2, 6);

      // A read asserts its data strobes with AS, in S2 (UM 5.1.1 state 2).
      if (uds) expect_window({tag, " UDS"}, t0, OB_UDSN, 1'b0, 2, 6);
      else     expect_bit   ({tag, " UDS"}, t0, 4, OB_UDSN, 1'b1);
      if (lds) expect_window({tag, " LDS"}, t0, OB_LDSN, 1'b0, 2, 6);
      else     expect_bit   ({tag, " LDS"}, t0, 4, OB_LDSN, 1'b1);

      // R/W stays high all cycle, and the data bus is never driven.
      for (s = 0; s <= 7; s = s + 1) begin
        expect_bit({tag, " R/W held"}, t0, s, OB_RW, 1'b1);
        expect_bit({tag, " d_oe"},     t0, s, OB_DOE, 1'b0);
      end
    end
  endtask

  task automatic check_write(input string tag, input int t0,
                             input logic uds, input logic lds);
    begin
      // S0: R/W is driven high first, even on a write (UM 5.1.2 state 0).
      expect_bit({tag, " R/W in S0"}, t0, 0, OB_RW, 1'b1);
      expect_bit({tag, " R/W in S1"}, t0, 1, OB_RW, 1'b1);
      // S2: AS asserted and R/W driven low.
      expect_window({tag, " AS"},  t0, OB_ASN, 1'b0, 2, 6);
      expect_window({tag, " R/W"}, t0, OB_RW,  1'b0, 2, 7);
      // S3: the data bus comes out of high impedance.
      expect_window({tag, " d_oe"}, t0, OB_DOE, 1'b1, 3, 7);
      // S4: the data strobes assert a clock later than on a read.
      if (uds) expect_window({tag, " UDS"}, t0, OB_UDSN, 1'b0, 4, 6);
      else     expect_bit   ({tag, " UDS"}, t0, 5, OB_UDSN, 1'b1);
      if (lds) expect_window({tag, " LDS"}, t0, OB_LDSN, 1'b0, 4, 6);
      else     expect_bit   ({tag, " LDS"}, t0, 5, OB_LDSN, 1'b1);
    end
  endtask

  initial begin
    sname[0] = "";
    harness_reset();

    slv.poke(23'h001000, 16'h1234);
    slv.poke(23'h001001, 16'hA55A);

    // ---- Word read ---------------------------------------------------------
    bus_cycle(rd68011_pkg::CT_READ, rd68011_pkg::FC_SUPER_D,
              23'h001000, 1'b1, 1'b1, 16'h0000, t0);
    check_read("word read", t0, 1'b1, 1'b1);
    expect_val("word read data", {16'd0, req_rdata}, {16'd0, 16'h1234});
    expect_val("word read end",  {29'd0, req_end}, {29'd0, rd68011_pkg::CE_DTACK});
    expect_val("word read addr", {9'd0, obs_a[(t0 + 1) % OBSN]},
               {9'd0, 23'h001000});
    // The address is not yet the new one during S0 (spec 6: clock low to
    // address valid, i.e. entering S1).
    expect_bit("addr driven in S1", t0, 1, OB_AOE, 1'b1);

    // ---- Byte reads: UM table 3-1 -----------------------------------------
    bus_cycle(rd68011_pkg::CT_READ, rd68011_pkg::FC_SUPER_D,
              23'h001000, 1'b1, 1'b0, 16'h0000, t0);
    check_read("upper byte read", t0, 1'b1, 1'b0);

    bus_cycle(rd68011_pkg::CT_READ, rd68011_pkg::FC_SUPER_D,
              23'h001000, 1'b0, 1'b1, 16'h0000, t0);
    check_read("lower byte read", t0, 1'b0, 1'b1);

    // ---- Word write --------------------------------------------------------
    bus_cycle(rd68011_pkg::CT_WRITE, rd68011_pkg::FC_SUPER_D,
              23'h001002, 1'b1, 1'b1, 16'hBEEF, t0);
    check_write("word write", t0, 1'b1, 1'b1);
    expect_val("word write data on bus", {16'd0, obs_d[(t0 + 4) % OBSN]},
               {16'd0, 16'hBEEF});
    expect_val("word write stored", {16'd0, slv.peek(23'h001002)},
               {16'd0, 16'hBEEF});

    // ---- Byte write: only the addressed lane changes -----------------------
    slv.poke(23'h001003, 16'h0000);
    bus_cycle(rd68011_pkg::CT_WRITE, rd68011_pkg::FC_SUPER_D,
              23'h001003, 1'b1, 1'b0, 16'hAA55, t0);
    check_write("upper byte write", t0, 1'b1, 1'b0);
    expect_val("upper byte write stored", {16'd0, slv.peek(23'h001003)},
               {16'd0, 16'hAA00});

    slv.poke(23'h001003, 16'h0000);
    bus_cycle(rd68011_pkg::CT_WRITE, rd68011_pkg::FC_SUPER_D,
              23'h001003, 1'b0, 1'b1, 16'hAA55, t0);
    expect_val("lower byte write stored", {16'd0, slv.peek(23'h001003)},
               {16'd0, 16'h0055});

    // ---- Read then write, back to back -------------------------------------
    // Figure 5-3 draws S7 followed straight by the next S0. Hold the request
    // across the acknowledge so the second cycle starts immediately.
    req_chain = 1'b1;
    bus_start(rd68011_pkg::CT_READ, rd68011_pkg::FC_SUPER_D,
              23'h001000, 1'b1, 1'b1, 16'h0000, t0);
    // req_last rises on the falling edge entering S7, which is the last moment
    // a sequencer can present the next request in time for the rising edge that
    // ends the cycle. Presenting it any later costs a whole bus cycle.
    @(posedge req_last);
    req_addr  = 23'h001004;
    req_kind  = rd68011_pkg::CT_WRITE;
    req_wdata = 16'hC0DE;
    @(posedge clk);
    t1        = etick;
    req_chain = 1'b0;
    // This rising edge both acknowledges the first cycle and starts the second.
    // Step past the first acknowledge before waiting for the second.
    @(negedge clk);
    bus_finish();
    expect_eq("back-to-back cycle spacing, in states", t1 - t0, 8);
    check_write("second of a pair", t1, 1'b1, 1'b1);

    harness_done("bus_rw_tb");
  end

endmodule
