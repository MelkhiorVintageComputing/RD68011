// Bus error, address error, the format $8 frame, and continuation.
//
// This is what the MC68010 exists for. UM 5.4.1: "The MC68010 stacks the frame
// format and the vector offset followed by 22 words of internal register
// information. The return from exception (RTE) instruction restores the
// internal register information so that the MC68010 can continue execution of
// the instruction after the error handler routine completes."
//
// So the tests here are of two kinds. The first kind checks that a fault is
// taken where it should be and records what it should: the vector, the special
// status word of UM figure 6-9, the fault address, and a stack pointer
// fifty-eight bytes lower. The second kind is the one that matters -- fault,
// fix the cause, RTE, and check the instruction finished as if nothing had
// happened. A MOVEM faulting partway through its register list is the case
// doc/checkpoint.md named in P2 as the one that cannot be patched around.
//
// The reference vectors cannot check any of this: they are an MC68000, whose
// fault frame is seven words with no internal state at all.

`timescale 1ns/1ps

module core_fault_tb;

`include "rd68011_core_harness.svh"

  localparam logic [31:0] SSP0 = 32'h0000_3000;
  localparam logic [31:0] PC0  = 32'h0000_1000;

  localparam logic [31:0] H_BUSERR  = 32'h0000_2000;
  localparam logic [31:0] H_ADDRERR = 32'h0000_2100;
  localparam logic [31:0] H_FORMAT  = 32'h0000_2200;
  localparam logic [31:0] H_SPUR    = 32'h0000_2300;
  localparam logic [31:0] H_DONE    = 32'h0000_2400;

  // Where a frame lands, and the offsets into it.
  localparam logic [31:0] FRAME = SSP0 - 32'd58;

  int i;

  function automatic logic [15:0] fw(input int off);
    fw = mem.peek((FRAME + off) >> 1);
  endfunction

  function automatic logic [31:0] fl(input int off);
    fl = {mem.peek((FRAME + off) >> 1), mem.peek((FRAME + off + 2) >> 1)};
  endfunction

  // How many bus cycles went to one address.
  function automatic int hits(input logic [23:0] addr);
    int n;
    begin
      n = 0;
      for (int k = 0; k < ntr; k = k + 1)
        if ({tr_addr[k], 1'b0} == addr) n = n + 1;
      hits = n;
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

  task automatic setup();
    begin
      core_reset();
      poke_l(23'h000000, SSP0);
      poke_l(23'h000002, PC0);
      poke_l(23'h000004, H_BUSERR);    // vector 2
      poke_l(23'h000006, H_ADDRERR);   // vector 3
      poke_l(23'h00001C, H_FORMAT);    // vector 14
      poke_l(23'h000030, H_SPUR);      // vector 24
      poke_w(H_BUSERR[23:1],  16'h60FE);
      poke_w(H_ADDRERR[23:1], 16'h60FE);
      poke_w(H_FORMAT[23:1],  16'h60FE);
      poke_w(H_SPUR[23:1],    16'h60FE);
      poke_w(H_DONE[23:1],    16'h60FE);
    end
  endtask

  // Check the parts of a frame every fault shares.
  task automatic check_frame(input string what, input logic [7:0] vec,
                             input logic [31:0] faddr);
    logic [15:0] ver;
    begin
      ver = fw(26);
      expect_u32({what, ": stack pointer down by 58"},
                 dut.u_seq.ssp, SSP0 - 32'd58);
      expect_u32({what, ": format 8 and the vector offset"},
                 {16'd0, fw(6)}, {16'd0, 4'h8, 2'd0, vec, 2'b00});
      expect_u32({what, ": fault address"}, fl(10), faddr);
      // UM 6.4: the first internal word carries our version number.
      expect_u32({what, ": our version number"},
                 {28'd0, ver[13:10]},
                 {28'd0, rd68011_pkg::FRAME_VERSION});
    end
  endtask

  initial begin
    errors = 0;

    // ======================================================================
    // Address error on a data write -- UM 6.3.10
    // ======================================================================
    setup();
    //  1000: MOVE.L #$00004001,A0     an odd address
    //  1006: MOVE.W D0,(A0)           word at an odd address: address error
    poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, 32'h0000_4001);
    poke_w(23'h000803, 16'h3080);
    core_start();
    run_until_pc(H_ADDRERR, 900);
    check_frame("address error", 8'd3, 32'h0000_4001);
    // Write, word, data space, and neither an instruction nor a data fetch.
    expect_u32("address error: special status word",
               {16'd0, fw(8)},
               {16'd0, 8'b0000_0000, 5'd0, rd68011_pkg::FC_SUPER_D});
    // The cycle never happened: nothing on the bus went near $4000.
    begin
      int n;
      n = 0;
      for (i = 0; i < ntr; i = i + 1)
        if ({tr_addr[i], 1'b0} == 24'h004000) n = n + 1;
      expect_int("address error: the aborted cycle never reached the bus", n, 0);
    end

    // ======================================================================
    // Address error on an instruction fetch
    // ======================================================================
    setup();
    //  1000: MOVE.L #$00005001,A0
    //  1006: JMP (A0)                 the refill from an odd address faults
    poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, 32'h0000_5001);
    poke_w(23'h000803, 16'h4ED0);
    core_start();
    run_until_pc(H_ADDRERR, 900);
    check_frame("address error on a fetch", 8'd3, 32'h0000_5001);
    // A read, an instruction fetch, in program space.
    expect_u32("address error on a fetch: special status word",
               {16'd0, fw(8)},
               {16'd0, 8'b0010_0001, 5'd0, rd68011_pkg::FC_SUPER_P});

    // ======================================================================
    // Bus error on a data read
    // ======================================================================
    setup();
    //  1000: MOVE.L #$00004000,A0
    //  1006: MOVE.W (A0),D1
    poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, 32'h0000_4000);
    poke_w(23'h000803, 16'h3210);
    berr_en   = 1'b1;
    berr_addr = 23'h002000;          // $4000 >> 1
    core_start();
    run_until_pc(H_BUSERR, 900);
    check_frame("bus error", 8'd2, 32'h0000_4000);
    // A read, a word, a data fetch, in supervisor data space.
    expect_u32("bus error: special status word",
               {16'd0, fw(8)},
               {16'd0, 8'b0001_0001, 5'd0, rd68011_pkg::FC_SUPER_D});
    expect_u32("bus error: the instruction input buffer is stacked",
               {16'd0, fw(24)}, {16'd0, dut.u_seq.irc});

    // ======================================================================
    // Continuation: the fault goes away and RTE finishes the instruction
    // ======================================================================
    setup();
    //  1000: MOVE.L #$00004000,A0
    //  1006: MOVE.W (A0),D1
    //  1008: BRA to the handler-done marker
    poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, 32'h0000_4000);
    poke_w(23'h000803, 16'h3210);
    poke_w(23'h000804, 16'h4EF9);  poke_l(23'h000805, H_DONE);
    poke_w(23'h002000, 16'hBEEF);
    // The handler is an RTE, and the fault is arranged to happen once.
    poke_w(H_BUSERR[23:1], 16'h4E73);
    berr_en   = 1'b1;
    berr_addr = 23'h002000;
    core_start();
    // Wait for the handler, then take the fault away and let RTE rerun.
    run_until_pc(H_BUSERR, 900);
    berr_en = 1'b0;
    run_until_pc(H_DONE, 900);
    expect_u32("continuation: the read completed after RTE",
               dut.u_seq.regs[1], 32'h0000_BEEF);
    expect_u32("continuation: the stack pointer is back",
               dut.u_seq.ssp, SSP0);
    expect_int("continuation: the faulted cycle was attempted twice",
               hits(24'h004000), 2);

    // ======================================================================
    // Continuation when the faulted cycle was a prefetch
    // ======================================================================
    // Every continuation above resumes a data access. A prefetch is the other
    // half, and the frame carries the machinery for it: UM 6.3.9.2 lists the
    // instruction input buffer among the words a handler may need, and figure
    // 6-9's IF bit exists to say that the fetch, not the operand, is what
    // faulted. The instruction in flight is aborted along with the fetch that
    // was running ahead of it, so RTE has to finish that one *and* deliver the
    // word the fetch was for.
    setup();
    //  1000: NOP
    //  1002: NOP
    //  1004: MOVE.W #$1234,D0     in flight when the fetch ahead of it faults
    //  1008: MOVE.W #$5678,D1     the fetch of the word at 1008 is the fault
    //  100C: JMP to the handler-done marker
    poke_w(23'h000800, 16'h4E71);
    poke_w(23'h000801, 16'h4E71);
    poke_w(23'h000802, 16'h303C);  poke_w(23'h000803, 16'h1234);
    poke_w(23'h000804, 16'h323C);  poke_w(23'h000805, 16'h5678);
    poke_w(23'h000806, 16'h4EF9);  poke_l(23'h000807, H_DONE);
    poke_w(H_BUSERR[23:1], 16'h4E73);
    berr_en   = 1'b1;
    berr_addr = 23'h000804;
    core_start();
    run_until_pc(H_BUSERR, 900);
    check_frame("prefetch fault", 8'd2, 32'h0000_1008);
    // A read, an instruction fetch, in program space -- the same status word
    // the address error on a fetch produces, arrived at from the other cause.
    expect_u32("prefetch fault: special status word",
               {16'd0, fw(8)},
               {16'd0, 8'b0010_0001, 5'd0, rd68011_pkg::FC_SUPER_P});
    berr_en = 1'b0;
    run_until_pc(H_DONE, 900);
    expect_u32("prefetch continued: the aborted instruction finished",
               dut.u_seq.regs[0], 32'h0000_1234);
    expect_u32("prefetch continued: the instruction the fetch was for ran",
               dut.u_seq.regs[1], 32'h0000_5678);
    expect_u32("prefetch continued: the stack pointer is back",
               dut.u_seq.ssp, SSP0);
    expect_int("prefetch continued: the faulted fetch was attempted twice",
               hits(24'h001008), 2);

    // ======================================================================
    // MOVEM faulting partway through, continued to completion
    // ======================================================================
    setup();
    //  1000: MOVE.L #$00004000,A0
    //  1006: MOVEM.L (A0),D0-D3       eight word reads
    //  100C: BRA to the handler-done marker
    poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, 32'h0000_4000);
    poke_w(23'h000803, 16'h4CD0);  poke_w(23'h000804, 16'h000F);
    poke_w(23'h000805, 16'h4EF9);  poke_l(23'h000806, H_DONE);
    for (i = 0; i < 8; i = i + 1)
      poke_w(23'h002000 + 23'(i), 16'(16'h1000 + 16'(i)));
    poke_w(H_BUSERR[23:1], 16'h4E73);
    // Fault on the fifth word, which is in the middle of D2.
    berr_en   = 1'b1;
    berr_addr = 23'h002004;
    core_start();
    run_until_pc(H_BUSERR, 1500);
    berr_en = 1'b0;
    run_until_pc(H_DONE, 1500);
    expect_u32("MOVEM continued: D0", dut.u_seq.regs[0], 32'h1000_1001);
    expect_u32("MOVEM continued: D1", dut.u_seq.regs[1], 32'h1002_1003);
    expect_u32("MOVEM continued: D2", dut.u_seq.regs[2], 32'h1004_1005);
    expect_u32("MOVEM continued: D3", dut.u_seq.regs[3], 32'h1006_1007);
    expect_u32("MOVEM continued: A0 is untouched by a control mode",
               dut.u_seq.regs[8], 32'h0000_4000);
    expect_int("MOVEM continued: only the faulted word was reread",
               hits(24'h004008), 2);
    expect_int("MOVEM continued: the words before it were not",
               hits(24'h004006), 1);

    // ======================================================================
    // A read-modify-write faulting, and rerun whole
    // ======================================================================
    setup();
    //  1000: MOVE.L #$00004000,A0
    //  1006: TAS (A0)
    //  1008: BRA to the handler-done marker
    poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, 32'h0000_4000);
    poke_w(23'h000803, 16'h4AD0);
    poke_w(23'h000804, 16'h4EF9);  poke_l(23'h000805, H_DONE);
    poke_w(23'h002000, 16'h0F00);
    poke_w(H_BUSERR[23:1], 16'h4E73);
    berr_en   = 1'b1;
    berr_addr = 23'h002000;
    core_start();
    run_until_pc(H_BUSERR, 1200);
    // The read half faulted, so the special status word says so.
    expect_u32("TAS fault: a read-modify-write, reading, a byte",
               {16'd0, fw(8)},
               {16'd0, 8'b0001_1011, 5'd0, rd68011_pkg::FC_SUPER_D});
    berr_en = 1'b0;
    run_until_pc(H_DONE, 1200);
    expect_u32("TAS continued: bit 7 set in memory",
               {16'd0, mem.peek(23'h002000)}, 32'h0000_8F00);
    expect_u32("TAS continued: N from the operand as it was read",
               {28'd0, dut.u_seq.sr[3:0]}, 32'd0);

    // ======================================================================
    // The data output buffer survives, which a long store needs
    // ======================================================================
    // MOVE.L to -(An) writes the low word first and the high word second, both
    // out of the buffer the prefetch before them filled. If the second write
    // faults, continuing it needs that buffer back exactly as it was -- and
    // its two halves are in two different places in the frame, because the
    // architecture fixes where the low one goes and the high one is ours.
    setup();
    //  1000: MOVE.L #$00004004,A0
    //  1006: MOVE.L #$11223344,D0
    //  100C: MOVE.L D0,-(A0)      writes $4002 then $4000
    //  100E: BRA to the handler-done marker
    poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, 32'h0000_4004);
    poke_w(23'h000803, 16'h203C);  poke_l(23'h000804, 32'h1122_3344);
    poke_w(23'h000806, 16'h2100);
    poke_w(23'h000807, 16'h4EF9);  poke_l(23'h000808, H_DONE);
    poke_w(H_BUSERR[23:1], 16'h4E73);
    berr_en   = 1'b1;
    berr_addr = 23'h002000;          // the second write, at $4000
    core_start();
    run_until_pc(H_BUSERR, 1500);
    expect_u32("long store fault: a write, a word, neither fetch",
               {16'd0, fw(8)},
               {16'd0, 8'b0000_0000, 5'd0, rd68011_pkg::FC_SUPER_D});
    berr_en = 1'b0;
    run_until_pc(H_DONE, 1500);
    expect_u32("long store continued: both halves in memory",
               {mem.peek(23'h002000), mem.peek(23'h002001)}, 32'h1122_3344);
    expect_u32("long store continued: the register moved once",
               dut.u_seq.regs[8], 32'h0000_4000);

    // ======================================================================
    // A frame this processor did not write -- UM 6.4's version check
    // ======================================================================
    setup();
    //  1000: MOVE.L #$00002FC6,A7    point at a frame we build by hand
    //  1006: RTE
    poke_w(23'h000800, 16'h2E7C);  poke_l(23'h000801, FRAME);
    poke_w(23'h000803, 16'h4E73);
    poke_w(FRAME[23:1] + 23'd0, 16'h2000);            // SR
    poke_l(FRAME[23:1] + 23'd1, H_DONE);              // PC
    poke_w(FRAME[23:1] + 23'd3, 16'h8008);            // format 8, vector 2
    poke_w(FRAME[23:1] + 23'd13, 16'h0000);           // version word: not ours
    core_start();
    run_until_pc(H_FORMAT, 1200);
    expect_u32("format error: the stack pointer still points at the frame",
               dut.u_seq.ssp, FRAME - 32'd8);

    // ======================================================================
    // Software completed the access itself -- the rerun flag
    // ======================================================================
    setup();
    //  1000: MOVE.L #$00004000,A0
    //  1006: MOVE.W (A0),D1
    //  1008: BRA to the handler-done marker
    poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, 32'h0000_4000);
    poke_w(23'h000803, 16'h3210);
    poke_w(23'h000804, 16'h4EF9);  poke_l(23'h000805, H_DONE);
    poke_w(23'h002000, 16'hBEEF);
    // The handler sets the rerun flag and the data input buffer image, then
    // returns; the access must not happen again and the data must come from
    // the image (UM 6.3.9.2).
    //  2000: ORI.W #$8000,(58-58+8,A7)  -> set RR in the special status word
    //  ... simpler: write the two words directly with MOVE
    poke_w(H_BUSERR[23:1] + 23'd0, 16'h3F7C);   // MOVE.W #$8000,(8,A7)
    poke_w(H_BUSERR[23:1] + 23'd1, 16'h8000);
    poke_w(H_BUSERR[23:1] + 23'd2, 16'h0008);
    poke_w(H_BUSERR[23:1] + 23'd3, 16'h3F7C);   // MOVE.W #$CAFE,(20,A7)
    poke_w(H_BUSERR[23:1] + 23'd4, 16'hCAFE);
    poke_w(H_BUSERR[23:1] + 23'd5, 16'h0014);
    poke_w(H_BUSERR[23:1] + 23'd6, 16'h4E73);   // RTE
    berr_en   = 1'b1;
    berr_addr = 23'h002000;
    core_start();
    run_until_pc(H_DONE, 2000);
    expect_u32("software rerun: the data came from the input buffer image",
               dut.u_seq.regs[1], 32'h0000_CAFE);
    expect_int("software rerun: the access was not repeated",
               hits(24'h004000), 1);

    // ======================================================================
    // A fault inside fault processing halts the processor -- UM 6.3.9.1
    // ======================================================================
    setup();
    poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, 32'h0000_4001);
    poke_w(23'h000803, 16'h3080);        // address error, as above
    // ... and the frame write faults too, which is the second fault.
    berr_en   = 1'b1;
    berr_addr = (SSP0 - 32'd2) >> 1;
    core_start();
    begin
      int n;
      n = 0;
      while (!halt_n_oe && (n < 2000)) begin
        @(posedge clk);
        n = n + 1;
      end
      if (!halt_n_oe) begin
        $display("FAIL: double bus fault never drove HALT");
        errors = errors + 1;
      end
    end
    expect_u32("double bus fault: HALT is driven low",
               {31'd0, halt_n_o}, 32'd0);

    // ======================================================================
    // A fault partway through RTE's reload is a double bus fault
    // ======================================================================
    // UM 6.4: "After this read, the processor must be able to load the
    // remaining data without receiving a bus error; therefore, if a bus error
    // occurs on any of the remaining stack reads, the error becomes a double
    // bus fault, and the MC68010 enters the halted state." The probe at SP+56
    // and the version word at SP+26 both succeed here; the word after them
    // does not.
    setup();
    poke_w(23'h000800, 16'h207C);  poke_l(23'h000801, 32'h0000_4000);
    poke_w(23'h000803, 16'h3210);
    poke_w(H_BUSERR[23:1], 16'h4E73);
    berr_en   = 1'b1;
    berr_addr = 23'h002000;
    core_start();
    run_until_pc(H_BUSERR, 1200);
    berr_addr = (FRAME + 32'd30) >> 1;     // read during the reload walk
    begin
      int n;
      n = 0;
      while (!halt_n_oe && (n < 2000)) begin
        @(posedge clk);
        n = n + 1;
      end
      if (!halt_n_oe) begin
        $display("FAIL: a fault inside RTE's reload did not halt");
        errors = errors + 1;
      end
    end

    // ======================================================================
    // A fault while the reset vector is read halts too
    // ======================================================================
    setup();
    berr_en   = 1'b1;
    berr_addr = 23'h000000;                // the initial stack pointer
    core_start();
    begin
      int n;
      n = 0;
      while (!halt_n_oe && (n < 400)) begin
        @(posedge clk);
        n = n + 1;
      end
      if (!halt_n_oe) begin
        $display("FAIL: a fault during reset processing did not halt");
        errors = errors + 1;
      end
    end

    // ======================================================================
    // Only an external reset restarts a halted processor -- UM 6.3.9.1
    // ======================================================================
    // Picking up from the double bus fault just provoked: the processor is
    // halted and driving HALT out. Asserting RESET on the pin brings it back.
    berr_en = 1'b0;
    reset_n_i = 1'b0;
    repeat (8) @(posedge clk);
    expect_u32("external reset releases HALT", {31'd0, halt_n_oe}, 32'd0);
    poke_l(23'h000000, SSP0);
    poke_l(23'h000002, H_DONE);
    core_start();
    run_until_pc(H_DONE, 400);

    // ======================================================================
    // A bus error on an interrupt acknowledge is a spurious interrupt
    // ======================================================================
    // UM 6.3.4: "The processor separates the processing of this error from bus
    // error by forming a short format exception stack and fetching the
    // spurious interrupt vector instead of the bus error vector."
    setup();
    //  1000: MOVE #$2000,SR      supervisor, mask zero
    //  1004: BRA self
    poke_w(23'h000800, 16'h46FC);  poke_w(23'h000801, 16'h2000);
    poke_w(23'h000802, 16'h60FE);
    iack_berr = 1'b1;
    core_start();
    repeat (60) @(posedge clk);
    ipl_n_i = 3'b110;                     // level 1, above a mask of zero
    run_until_pc(H_SPUR, 900);
    expect_u32("spurious interrupt: the short frame, not the long one",
               dut.u_seq.ssp, SSP0 - 32'd8);
    expect_u32("spurious interrupt: format 0 and vector 24",
               {16'd0, mem.peek((SSP0 - 32'd8 + 32'd6) >> 1)},
               {22'd0, 8'd24, 2'b00});
    expect_u32("spurious interrupt: not halted",
               {31'd0, halt_n_oe}, 32'd0);

    if (errors == 0) $display("PASS: core_fault_tb");
    else             $display("FAIL: core_fault_tb, %0d errors", errors);
    $finish;
  end

endmodule
