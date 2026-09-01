// Byte lanes: which half of the data bus a byte comes from, and goes to.
//
// A byte access puts no A0 on the address bus -- there is no A0 pin (UM 3.1).
// The strobe is the only thing that says which half of the word is meant: UDS
// for an even address, LDS for an odd one, and on a write the processor drives
// the byte on *both* halves so that the strobe alone decides which one lands
// (UM table 3-1 and its footnote). So a core that had the two strobes the wrong
// way round would read and write the wrong byte at every address, and nothing
// about the address bus would look wrong while it did.
//
// The memory model decodes the strobes exactly as a real memory does
// (sim/models/rd68011_slave.sv:88-89), so what ends up in memory is a real test
// of the lanes and not a restatement of the request.
//
// The case asked for is a memory-to-memory MOVE.B with *both* operands odd.
// Two separate mechanisms decide the two halves of it and they are worth naming
// apart, because the failures look different: the byte a read yields is chosen
// inside the core (`rdata_byte`, off the address's low bit), and the half a
// write lands in is chosen by the strobe and decoded by the memory. Inverting
// the first leaves the byte in the right half and makes it the wrong byte;
// inverting the second keeps the right byte and puts it in the wrong half.
// Both were injected, and odd-to-odd alone catches and distinguishes them.
//
// What odd-to-odd cannot do is the reason the other three combinations are
// here, and it is not the obvious one:
//
//   * it never asserts UDS. A byte at an odd address is LDS all the way in and
//     all the way out, so a UDS that never asserted would pass it. even-to-even
//     is what covers the other strobe.
//   * it cannot see the byte being driven on only one half of the bus. The
//     strobe still picks the right half and the right byte is there; only the
//     pin check below notices. odd-to-even fails in memory as well, because
//     landing in the *upper* half needs the byte on D8-D15, and it is only
//     there because the processor duplicates it (UM table 3-1, footnote).
//
// All four of those were injected into rtl/rd68011_seq.sv and watched to fail.

`timescale 1ns/1ps

module core_bytelane_tb;

`include "rd68011_core_harness.svh"

  localparam logic [31:0] SSP0 = 32'h0000_3000;
  localparam logic [31:0] PC0  = 32'h0000_1000;
  localparam logic [31:0] SRCW = 32'h0000_4000;  // the word a byte comes from
  localparam logic [31:0] DSTW = 32'h0000_5000;  // and the word it goes to

  localparam logic [15:0] SRC0 = 16'hA1B2;       // even byte A1, odd byte B2
  localparam logic [15:0] DST0 = 16'h3C4D;       // and what it lands among

  int i;

  // -- What the pins did, which the memory contents cannot say --------------
  //
  // Sampled on the falling edge while AS is low, which is inside every strobe's
  // assertion for both a read (UM 5.1.1 state 2) and a write (5.1.2 state 4),
  // and races with nothing.
  logic       rd_uds, rd_lds, wr_uds, wr_lds;
  logic [15:0] wr_data;
  logic        saw_write;

  always @(negedge clk) begin
    if (!as_n_o && ((fc_o == 3'd1) || (fc_o == 3'd5))) begin   // data space
      if (rw_o) begin
        if (!uds_n_o) rd_uds = 1'b1;
        if (!lds_n_o) rd_lds = 1'b1;
      end else if (d_oe && (!uds_n_o || !lds_n_o)) begin
        if (!uds_n_o) wr_uds = 1'b1;
        if (!lds_n_o) wr_lds = 1'b1;
        wr_data   = d_o;
        saw_write = 1'b1;
      end
    end
  end

  task automatic clear_watch();
    begin
      rd_uds = 1'b0;  rd_lds = 1'b0;
      wr_uds = 1'b0;  wr_lds = 1'b0;
      wr_data = 16'd0;  saw_write = 1'b0;
    end
  endtask

  // Data-space cycles, so the test can say that a byte access reaches the bus
  // as the *word* address and no more.
  function automatic int data_cycles(input logic want_read);
    int n;
    begin
      n = 0;
      for (int k = 0; k < ntr; k = k + 1) begin
        if (((tr_fc[k] == 3'd1) || (tr_fc[k] == 3'd5)) && (tr_rw[k] == want_read))
          n = n + 1;
      end
      data_cycles = n;
    end
  endfunction

  function automatic logic [23:1] first_data_addr(input logic want_read);
    begin
      first_data_addr = 23'h7FFFFF;
      for (int k = ntr - 1; k >= 0; k = k - 1) begin
        if (((tr_fc[k] == 3'd1) || (tr_fc[k] == 3'd5)) && (tr_rw[k] == want_read))
          first_data_addr = tr_addr[k];
      end
    end
  endfunction

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

  task automatic vectors();
    begin
      core_reset();
      clear_watch();
      poke_l(23'h000000, SSP0);
      poke_l(23'h000002, PC0);
      poke_w(SRCW[23:1], SRC0);
      poke_w(DSTW[23:1], DST0);
    end
  endtask

  // ---------------------------------------------------------------------------
  //   1000  MOVEA.L #src,A0
  //   1006  MOVEA.L #dst,A1
  //   100C  MOVE.B  (A0),(A1)
  //   100E  BRA     *
  // ---------------------------------------------------------------------------
  task automatic move_byte(input string what,
                           input logic [31:0] src, input logic [31:0] dst,
                           input logic [15:0] want_dst, input logic [7:0] want_b);
    begin
      vectors();
      poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, src);
      poke_w(23'h000803, 16'h227C);  poke_l(23'h000804, dst);
      poke_w(23'h000806, 16'h1290);              // MOVE.B (A0),(A1)
      poke_w(23'h000807, 16'h60FE);              // 100E: branch to self
      core_start();
      run_until_pc(32'h0000_100E, 600);

      expect_u32({what, ": the byte landed in the right half"},
                 {16'd0, mem.peek(DSTW[23:1])}, {16'd0, want_dst});
      expect_u32({what, ": the source word is untouched"},
                 {16'd0, mem.peek(SRCW[23:1])}, {16'd0, SRC0});

      // One read and one write, each at the word address: a byte access has no
      // A0 to put on the bus.
      expect_int({what, ": one data read"},  data_cycles(1'b1), 1);
      expect_int({what, ": one data write"}, data_cycles(1'b0), 1);
      expect_u32({what, ": the read is at the word address"},
                 {9'd0, first_data_addr(1'b1)}, {9'd0, SRCW[23:1]});
      expect_u32({what, ": the write is at the word address"},
                 {9'd0, first_data_addr(1'b0)}, {9'd0, DSTW[23:1]});

      // The strobes themselves, so a failure says "the wrong half" rather than
      // "the wrong byte".
      expect_u32({what, ": the read strobe"},
                 {30'd0, rd_uds, rd_lds}, {30'd0, !src[0], src[0]});
      expect_u32({what, ": the write strobe"},
                 {30'd0, wr_uds, wr_lds}, {30'd0, !dst[0], dst[0]});

      // UM table 3-1's footnote: the byte goes out on both halves, and the
      // strobe picks. Checked because the alternative -- driving it on one half
      // and relying on the strobe -- looks identical in memory.
      if (!saw_write) begin
        $display("FAIL: %s: no write reached the pins", what);
        errors = errors + 1;
      end
      expect_u32({what, ": both halves of the bus carry the byte"},
                 {16'd0, wr_data}, {16'd0, want_b, want_b});
    end
  endtask

  initial begin
    errors = 0;

    // ======================================================================
    // The case in question: both operands odd
    // ======================================================================
    move_byte("odd to odd", SRCW + 32'd1, DSTW + 32'd1,
              {DST0[15:8], SRC0[7:0]}, SRC0[7:0]);

    // ======================================================================
    // The three that cover what it cannot
    //
    // even-to-even for UDS, which odd-to-odd never asserts, and the mixed pair
    // for the duplicated write data, which odd-to-odd cannot see in memory
    // because the byte it wants is on the half it reads either way.
    // ======================================================================
    move_byte("odd to even", SRCW + 32'd1, DSTW,
              {SRC0[7:0], DST0[7:0]}, SRC0[7:0]);
    move_byte("even to odd", SRCW, DSTW + 32'd1,
              {DST0[15:8], SRC0[15:8]}, SRC0[15:8]);
    move_byte("even to even", SRCW, DSTW,
              {SRC0[15:8], DST0[7:0]}, SRC0[15:8]);

    // ======================================================================
    // Four bytes through (A0)+ to (A1)+, starting odd
    //
    // A byte post-increment steps by one, so every trip changes both lanes:
    // odd, even, odd, even. It is also a loop mode instruction with a
    // displacement of minus four, so this is the lanes checked with no
    // instruction fetches happening at all (UM appendix A).
    //
    //   1000  MOVEA.L #$4001,A0
    //   1006  MOVEA.L #$5001,A1
    //   100C  MOVE.W  #3,D0
    //   1010  MOVE.B  (A0)+,(A1)+
    //   1012  DBF     D0,1010
    //   1016  BRA     *
    // ======================================================================
    core_reset();
    clear_watch();
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, PC0);
    poke_w(23'h002000, 16'hA1B2);   // 4000: bytes A1 B2
    poke_w(23'h002001, 16'hC3D4);   // 4002: bytes C3 D4
    poke_w(23'h002002, 16'hE5F6);   // 4004: bytes E5 F6
    poke_w(23'h002800, 16'h1122);   // 5000
    poke_w(23'h002801, 16'h3344);   // 5002
    poke_w(23'h002802, 16'h5566);   // 5004
    poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, SRCW + 32'd1);
    poke_w(23'h000803, 16'h227C);  poke_l(23'h000804, DSTW + 32'd1);
    poke_w(23'h000806, 16'h303C);  poke_w(23'h000807, 16'd3);
    poke_w(23'h000808, 16'h12D8);              // MOVE.B (A0)+,(A1)+
    poke_w(23'h000809, 16'h51C8);  poke_w(23'h00080A, 16'hFFFC);
    poke_w(23'h00080B, 16'h60FE);              // 1016: branch to self
    core_start();
    run_until_pc(32'h0000_1016, 1200);

    expect_u32("post-increment: the odd byte of the first word",
               {16'd0, mem.peek(23'h002800)}, 32'h0000_11B2);
    expect_u32("post-increment: both bytes of the second",
               {16'd0, mem.peek(23'h002801)}, 32'h0000_C3D4);
    expect_u32("post-increment: the even byte of the third",
               {16'd0, mem.peek(23'h002802)}, 32'h0000_E566);
    expect_u32("post-increment: A0 advanced by one a byte",
               dut.u_seq.regs[8], SRCW + 32'd5);
    expect_u32("post-increment: A1 too", dut.u_seq.regs[9], DSTW + 32'd5);
    expect_int("post-increment: four reads", data_cycles(1'b1), 4);
    expect_int("post-increment: four writes", data_cycles(1'b0), 4);

    core_done("core_bytelane_tb");
  end

endmodule
