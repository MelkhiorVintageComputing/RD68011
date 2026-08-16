// RD68011 - micro-sequencer and datapath.
//
// Executes the microcode in rd68011_ucode_rom, generated from
// tools/ucode/program.py. Read that file and build/ucode.lst alongside this
// one: what the microcode can ask for is defined there, and this module is the
// machine that does it.
//
// TIMING: WHY THE REQUEST COMES FROM THE *NEXT* MICROWORD
//
// A microword occupies one clock, unless it asks for a bus cycle, in which case
// it occupies the cycle. The bus unit latches a request on the rising edge that
// ends the previous cycle (figure 5-3 draws S7 followed straight by the next
// S0), so a request presented on that edge is already too late if it comes from
// the microword that is only now retiring.
//
// So everything the bus unit sees is computed from the microword that will be
// current *after* this edge, and from the register values those registers will
// have after this edge -- pc_nxt, t0_nxt, t1_nxt below. When the current
// microword is not retiring, "next" is the same as "current" and the request
// sits still, which is what the bus unit requires of a request in progress.
//
// The payoff is exact cycle counts: NOP is one prefetch and costs four clocks,
// and a taken branch is two internal microwords and two prefetches and costs
// ten. Both match the reference vectors.
//
// NOT YET HERE: condition codes, exceptions, interrupts, address error
// detection, and the register selection that reads the opcode's register
// fields. Those arrive with the instructions that need them.

module rd68011_seq (
    input  logic        clk,
    input  logic        rst_n,

    // -- Bus unit -------------------------------------------------------------
    output logic        req_valid,
    output logic  [2:0] req_kind,
    output logic  [2:0] req_fc,
    output logic [23:1] req_addr,
    output logic        req_uds,
    output logic        req_lds,
    output logic [15:0] req_wdata,
    input  logic        req_ack,
    input  logic        req_last,
    input  logic [15:0] req_rdata,
    input  logic  [2:0] req_end,

    input  logic  [2:0] ipl_sync_n,
    input  logic        reset_sync_n,
    input  logic        halt_sync_n,
    input  logic        bus_idle,
    output logic        reset_req,
    input  logic        reset_busy,   // the RESET instruction's pulse is running
    output logic        dbf
);

  // ===========================================================================
  // Architectural and working state
  //
  // Everything here that carries a value across a bus cycle is part of the
  // checkpoint set -- see doc/checkpoint.md. The format $8 stack frame has to
  // be able to save and restore all of it for RTE to continue a faulted
  // instruction, which is why the working registers are a fixed, named set
  // rather than whatever the microcode happens to need.
  // ===========================================================================
  logic [rd68011_ucode_pkg::UADDR-1:0] upc;

  logic [31:0] pc;        // next prefetch address
  logic [15:0] ir;        // opcode being executed
  logic [15:0] irc;       // next word, already fetched
  logic [31:0] ir_pc;     // address ir was fetched from
  logic [31:0] irc_pc;    // address irc was fetched from
  logic [31:0] t0, t1;    // working registers
  // The address the address unit last computed. Real hardware calls this the
  // address output buffer, and it exists here for the same reason: MOVE to
  // -(An) prefetches *before* it writes (which the reference vectors show
  // plainly), so by the time the write happens `ir` already holds the next
  // instruction and the address register field is gone. This holds the address
  // across that. It is also the fault address the format $8 frame needs.
  logic [31:0] ea_latch;
  // The data output buffer, 32 bits: a long store has to hold the whole
  // operand, because MOVE to -(An) prefetches first and by the time the two
  // write cycles run, ir holds the next instruction and the source register
  // field has gone.
  logic [31:0] dbuf;
  logic [15:0] sr;
  logic [31:0] vbr;
  // The status register as it was when an exception began, kept where the
  // stack frame can find it after the supervisor bit has already been set.
  logic [15:0] sr_save;
  // D0-D7 and A0-A6. A7 is not in the array: it is whichever of the two stack
  // pointers the S bit selects, so that an exception entering supervisor mode
  // switches stacks without moving anything (PRM section 1).
  logic [31:0] regs [0:14];
  logic [31:0] usp;
  logic [31:0] ssp;

  // The extension-word latch, for the words that outlive the prefetch that
  // replaces irc: MOVEM's register mask, and the register-and-direction word
  // of MOVEC and MOVES.
  //
  // MOVEM is what shapes it. Its transfers have to cost nothing but their bus
  // cycles -- the reference charges 8+4n and 12+4n and no more -- so the
  // register number cannot come from a counter the microcode steps. It comes
  // from a priority encoder over the mask instead, which makes `rsel` naming
  // the register and the transfer happening the same microword. The bit is
  // dropped as that microword retires, and whether any bit is left is the
  // loop's branch condition.
  //
  // To -(An) the mask runs the other way round -- bit 0 is A7, not D0 -- so
  // `mdown` reverses the mapping and nothing else (PRM section 4).
  logic [15:0] xw;
  logic [15:0] xw_after;
  logic  [3:0] mlow;
  logic [15:0] mlow_bit;
  logic  [3:0] mreg;

  // The MC68010's function code registers, which MOVES uses to reach an
  // address space of the program's choosing. Three bits each; MOVEC reads
  // them back zero-extended to 32, "unimplemented bits are read as zeros"
  // (PRM section 6).
  logic  [2:0] sfc;
  logic  [2:0] dfc;

  // ===========================================================================
  // The current microword, and the one that follows it
  // ===========================================================================
  logic [rd68011_ucode_pkg::UW-1:0]    uw;
  logic [rd68011_ucode_pkg::UW-1:0]    uw_nxt;
  logic [rd68011_ucode_pkg::UADDR-1:0] upc_nxt;
  logic [rd68011_ucode_pkg::UADDR-1:0] upc_target;

  rd68011_ucode_rom u_urom     (.addr (upc),     .uw (uw));
  rd68011_ucode_rom u_urom_nxt (.addr (upc_nxt), .uw (uw_nxt));

  // Field extraction. The positions come from the generated package, so the
  // microcode format is defined in exactly one place.
  `define UF(w, f) w[rd68011_ucode_pkg::U_``f``_LSB +: rd68011_ucode_pkg::U_``f``_W]

  logic [rd68011_ucode_pkg::U_SEQ_W-1:0]  f_seq;
  logic [rd68011_ucode_pkg::U_COND_W-1:0] f_cond;
  logic [rd68011_ucode_pkg::U_ASRC_W-1:0] f_asrc;
  logic [rd68011_ucode_pkg::U_BSRC_W-1:0] f_bsrc;
  logic [rd68011_ucode_pkg::U_ALU_W-1:0]  f_alu;
  logic [rd68011_ucode_pkg::U_DST_W-1:0]  f_dst;
  logic [rd68011_ucode_pkg::U_BUS_W-1:0]  f_bus;
  logic [rd68011_ucode_pkg::U_ASEL_W-1:0] f_asel;
  logic [rd68011_ucode_pkg::U_AUPD_W-1:0] f_aupd;
  logic [rd68011_ucode_pkg::U_PF_W-1:0]   f_pf;
  logic [rd68011_ucode_pkg::U_RSEL_W-1:0] f_rsel;
  logic [rd68011_ucode_pkg::U_WSEL_W-1:0] f_wsel;
  logic [rd68011_ucode_pkg::U_EASEL_W-1:0] f_easel;
  logic [rd68011_ucode_pkg::U_SIZE_W-1:0]  f_size;
  logic [rd68011_ucode_pkg::U_CCR_W-1:0]   f_ccr;
  logic [rd68011_ucode_pkg::U_MOP_W-1:0]   f_mop;

  assign f_seq  = `UF(uw, SEQ);
  assign f_cond = `UF(uw, COND);
  assign f_asrc = `UF(uw, ASRC);
  assign f_bsrc = `UF(uw, BSRC);
  assign f_alu  = `UF(uw, ALU);
  assign f_dst  = `UF(uw, DST);
  assign f_bus  = `UF(uw, BUS);
  assign f_asel  = `UF(uw, ASEL);
  assign f_aupd  = `UF(uw, AUPD);
  assign f_pf   = `UF(uw, PF);
  assign f_rsel  = `UF(uw, RSEL);
  assign f_wsel  = `UF(uw, WSEL);
  assign f_easel = `UF(uw, EASEL);
  assign f_size  = `UF(uw, SIZE);
  assign f_ccr   = `UF(uw, CCR);
  assign f_mop   = `UF(uw, MOP);

  // ===========================================================================
  // Retirement
  //
  // A microword with no bus request lasts one clock. One with a bus request
  // lasts until the bus unit reaches the last state of its cycle, which
  // req_last announces combinationally -- and which a retried cycle
  // deliberately does not announce, so a rerun is invisible here (UM 5.4.2).
  // ===========================================================================
  logic retire;
  logic bus_busy;

  assign bus_busy = (f_bus != rd68011_ucode_pkg::U_BUS_NONE);
  assign retire   = !bus_busy || req_last;

  // ===========================================================================
  // Prefetch pipe
  // ===========================================================================
  logic pf_adv, pf_fetch;
  logic [15:0] ir_nxt, irc_nxt;
  logic [31:0] ir_pc_nxt, irc_pc_nxt;

  assign pf_adv   = (f_pf == rd68011_ucode_pkg::U_PF_ADV) ||
                    (f_pf == rd68011_ucode_pkg::U_PF_ADVFETCH);
  assign pf_fetch = (f_pf == rd68011_ucode_pkg::U_PF_FETCH) ||
                    (f_pf == rd68011_ucode_pkg::U_PF_ADVFETCH);

  // ir takes the *old* irc, so an advance and a fetch in the same microword
  // shift the pipe along by one rather than colliding.
  assign ir_nxt     = (retire && pf_adv)   ? irc       : ir;
  assign ir_pc_nxt  = (retire && pf_adv)   ? irc_pc    : ir_pc;
  assign irc_nxt    = (retire && pf_fetch) ? req_rdata : irc;
  assign irc_pc_nxt = (retire && pf_fetch) ? pc        : irc_pc;

  // ===========================================================================
  // Decode
  //
  // The decoder is fed the opcode that will be current after this edge, so a
  // microword that both advances the pipe and ends the instruction lands on the
  // right entry point in one step.
  // ===========================================================================
  logic [rd68011_ucode_pkg::UADDR-1:0] dec_entry;
  logic                                dec_illegal;

  rd68011_decode_rom u_decode (
      .op      (ir_nxt),
      .entry   (dec_entry),
      .illegal (dec_illegal)
  );

  // ===========================================================================
  // Source buses and the ALU
  // ===========================================================================
  logic [31:0] a_bus, b_bus, y;
  logic  [7:0] rdata_byte;
  logic        n_flag, n_flag_alu, z_flag, z_flag_alu, v_flag, c_flag;

  // UM table 3-1: a byte at an even address arrives on D15-D8 and one at an
  // odd address on D7-D0. The address's low bit is the only thing that decides
  // it, so the microcode never has to know how an address turned out.
  assign rdata_byte = addr_lsb ? req_rdata[7:0] : req_rdata[15:8];

  // The index register of a brief extension word (PRM section 2). Bit 15 picks
  // data or address, bits 14-12 the number, and bit 11 selects the whole
  // register or its sign-extended low word.
  // The register in bits 11:9, available at the same time as the one the
  // addressing mode names: ADD <ea>,Dn needs both in one microword.
  logic [31:0] reg2_val;
  // Reading a register: index 15 is the active stack pointer.
  `define RDREG(i) (((i) == 4'd15) ? (sr[rd68011_pkg::SR_S] ? ssp : usp) \
                                   : regs[(i)])

  logic [31:0] index_reg;
  logic [31:0] index_val;
  assign reg2_val  = regs[{1'b0, ir[11:9]}];
  // ADDQ and SUBQ take their operand from bits 11:9, where zero means eight.
  logic [31:0] quick_val;
  assign quick_val = (ir[11:9] == 3'd0) ? 32'd8 : {29'd0, ir[11:9]};
  assign index_reg = `RDREG({irc[15], irc[14:12]});
  assign index_val = irc[11] ? index_reg
                             : {{16{index_reg[15]}}, index_reg[15:0]};

  // Register selection.
  //
  // `easel` picks which half of the opcode carries the mode and register
  // fields. MOVE is the reason this exists: its destination is bits 11:6 with
  // the two fields swapped -- register in 11:9, mode in 8:6 (PRM section 4) --
  // where every other instruction puts mode in 5:3 and register in 2:0.
  logic [2:0] ea_mode;
  logic [2:0] ea_reg;
  logic [3:0] reg_index;

  always_comb begin
    if (f_easel == rd68011_ucode_pkg::U_EASEL_DST) begin
      ea_mode = ir[8:6];
      ea_reg  = ir[11:9];
    end else begin
      ea_mode = ir[5:3];
      ea_reg  = ir[2:0];
    end
  end

  // The lowest register still named by the mask, and what the mask becomes
  // when this microword is done with it. `xw_after` is what the branch
  // condition reads, so a microword can load the mask and test it at once --
  // which is how an empty mask skips the loop without costing a cycle.
  always_comb begin
    mlow = 4'd15;
    for (int unsigned b = 15; b != 0; b = b - 1) begin
      if (xw[b - 1]) mlow = 4'(b - 1);
    end
  end
  assign mlow_bit = 16'd1 << mlow;
  assign mreg     = `UF(uw, MDOWN) ? (4'd15 - mlow) : mlow;

  // The general register MOVEC and MOVES name, out of the latched extension
  // word: bit 15 picks data or address, bits 14-12 the number.
  logic [3:0] xw_reg;
  assign xw_reg = {xw[15], xw[14:12]};
  logic [3:0] irc_reg;
  assign irc_reg = {irc[15], irc[14:12]};

  // The register written, which is not always the one read: MOVE reads the
  // source the mode names and writes the destination in bits 11:9.
  //
  // Written as always_comb rather than as a function called from a continuous
  // assignment: iverilog re-evaluates such a call only when an argument
  // changes, so a selection that depended on the opcode would go stale.
  // doc/coding-standard.md has the measurement.
  logic [3:0] wreg_index;
  always_comb begin
    unique case (f_wsel)
      rd68011_ucode_pkg::U_WSEL_SAME:   wreg_index = reg_index;
      rd68011_ucode_pkg::U_WSEL_A7:     wreg_index = 4'd15;
      rd68011_ucode_pkg::U_WSEL_EA_ANY: wreg_index = {(ea_mode != 3'b000),
                                                      ea_reg};
      rd68011_ucode_pkg::U_WSEL_EA_D:   wreg_index = {1'b0, ea_reg};
      rd68011_ucode_pkg::U_WSEL_EA_A:   wreg_index = {1'b1, ea_reg};
      rd68011_ucode_pkg::U_WSEL_IR9_D:  wreg_index = {1'b0, ir[11:9]};
      rd68011_ucode_pkg::U_WSEL_IR9_A:  wreg_index = {1'b1, ir[11:9]};
      rd68011_ucode_pkg::U_WSEL_MNEXT:  wreg_index = mreg;
      rd68011_ucode_pkg::U_WSEL_XW:     wreg_index = xw_reg;
      rd68011_ucode_pkg::U_WSEL_IRC_X:  wreg_index = irc_reg;
      default:                          wreg_index = 4'd15;
    endcase
  end

  always_comb begin
    unique case (f_mop)
      rd68011_ucode_pkg::U_MOP_LOAD: xw_after = irc;
      rd68011_ucode_pkg::U_MOP_STEP: xw_after = xw & ~mlow_bit;
      default:                       xw_after = xw;
    endcase
  end


  always_comb begin
    unique case (f_rsel)
      rd68011_ucode_pkg::U_RSEL_A7:     reg_index = 4'd15;
      // The register the mode itself names: a data register for mode 000, an
      // address register for every other mode that names one.
      rd68011_ucode_pkg::U_RSEL_EA_ANY: reg_index = {(ea_mode != 3'b000), ea_reg};
      rd68011_ucode_pkg::U_RSEL_EA_D:   reg_index = {1'b0, ea_reg};
      rd68011_ucode_pkg::U_RSEL_EA_A:   reg_index = {1'b1, ea_reg};
      rd68011_ucode_pkg::U_RSEL_IR9_D:  reg_index = {1'b0, ir[11:9]};
      rd68011_ucode_pkg::U_RSEL_IR9_A:  reg_index = {1'b1, ir[11:9]};
      rd68011_ucode_pkg::U_RSEL_MNEXT:  reg_index = mreg;
      rd68011_ucode_pkg::U_RSEL_XW:     reg_index = xw_reg;
      rd68011_ucode_pkg::U_RSEL_IRC_X:  reg_index = irc_reg;
      default:                          reg_index = 4'd15;
    endcase
  end

  // The control registers MOVEC reaches, and whether the code names one at all
  // (PRM section 6: "any other code causes an illegal instruction
  // exception"). The code is in irc, which MOVEC has not prefetched over yet.
  logic [31:0] creg_val;
  logic        creg_valid;
  always_comb begin
    creg_valid = 1'b1;
    unique case (irc[11:0])
      12'h000: creg_val = {29'd0, sfc};
      12'h001: creg_val = {29'd0, dfc};
      12'h800: creg_val = usp;
      12'h801: creg_val = vbr;
      default: begin creg_val = 32'd0; creg_valid = 1'b0; end
    endcase
  end

  // The source multiplexers.
  //
  // Written out twice as always_comb rather than once as a function called
  // from two continuous assignments, which is what this was first: iverilog
  // re-evaluates such a function only when its explicit arguments change, so a
  // mux that reads req_rdata internally never saw the read data arrive.
  // The other two tools infer the real dependencies and were happy, which is
  // exactly the kind of disagreement `make lint` cannot catch on its own.
  // Two muxes is also what the hardware is: two independent source buses.

  always_comb begin
    unique case (f_asrc)
      rd68011_ucode_pkg::U_ASRC_ZERO:     a_bus = 32'd0;
      rd68011_ucode_pkg::U_ASRC_ONE:      a_bus = 32'd1;
      rd68011_ucode_pkg::U_ASRC_TWO:      a_bus = 32'd2;
      rd68011_ucode_pkg::U_ASRC_FOUR:     a_bus = 32'd4;
      rd68011_ucode_pkg::U_ASRC_PC:       a_bus = pc;
      rd68011_ucode_pkg::U_ASRC_IR_PC:    a_bus = ir_pc;
      rd68011_ucode_pkg::U_ASRC_IRC_PC:   a_bus = irc_pc;
      rd68011_ucode_pkg::U_ASRC_IRC:      a_bus = {16'd0, irc};
      rd68011_ucode_pkg::U_ASRC_IRC_SX:   a_bus = {{16{irc[15]}}, irc};
      rd68011_ucode_pkg::U_ASRC_IR_SXB:   a_bus = {{24{ir[7]}}, ir[7:0]};
      rd68011_ucode_pkg::U_ASRC_T0:       a_bus = t0;
      rd68011_ucode_pkg::U_ASRC_T1:       a_bus = t1;
      rd68011_ucode_pkg::U_ASRC_RDATA:    a_bus = {16'd0, req_rdata};
      rd68011_ucode_pkg::U_ASRC_RDATA_SX: a_bus = {{16{req_rdata[15]}}, req_rdata};
      rd68011_ucode_pkg::U_ASRC_REG:      a_bus = `RDREG(reg_index);
      rd68011_ucode_pkg::U_ASRC_CREG:     a_bus = creg_val;
      rd68011_ucode_pkg::U_ASRC_RDATA_B:  a_bus = {24'd0, rdata_byte};
      rd68011_ucode_pkg::U_ASRC_INDEX:    a_bus = index_val;
      rd68011_ucode_pkg::U_ASRC_IRC_SXB:  a_bus = {{24{irc[7]}}, irc[7:0]};
      rd68011_ucode_pkg::U_ASRC_DBUF:     a_bus = dbuf;
      rd68011_ucode_pkg::U_ASRC_REG2:     a_bus = reg2_val;
      rd68011_ucode_pkg::U_ASRC_QUICK:    a_bus = quick_val;
      rd68011_ucode_pkg::U_ASRC_BITMASK:  a_bus = bit_mask;
      rd68011_ucode_pkg::U_ASRC_SCC:      a_bus = {32{cc_true}};
      rd68011_ucode_pkg::U_ASRC_BIT7:     a_bus = 32'h0000_0080;
      rd68011_ucode_pkg::U_ASRC_EAL:      a_bus = ea_latch;
      rd68011_ucode_pkg::U_ASRC_SRSAVE:   a_bus = {16'd0, sr_save};
      rd68011_ucode_pkg::U_ASRC_VBR:      a_bus = vbr;
      rd68011_ucode_pkg::U_ASRC_VECOFF:   a_bus = {22'd0, vec_num, 2'd0};
      rd68011_ucode_pkg::U_ASRC_FMTVEC:   a_bus = {18'd0, 4'h0, vec_num, 2'd0};
      rd68011_ucode_pkg::U_ASRC_SR:       a_bus = {16'd0, sr};
      rd68011_ucode_pkg::U_ASRC_CCRVAL:   a_bus = {24'd0, 3'd0, sr[4:0]};
      rd68011_ucode_pkg::U_ASRC_USP:      a_bus = usp;
      rd68011_ucode_pkg::U_ASRC_IRQVEC:   a_bus = {8'd0, 20'hFFFFF, irq_taken, 1'b1};
      rd68011_ucode_pkg::U_ASRC_IRQPC:    a_bus = irq_from_stop ? pc : ir_pc;
      rd68011_ucode_pkg::U_ASRC_DIVRES:   a_bus = {div_r, div_q};
      default:                            a_bus = 32'd0;
    endcase
  end

  always_comb begin
    unique case (f_bsrc)
      rd68011_ucode_pkg::U_BSRC_ZERO:     b_bus = 32'd0;
      rd68011_ucode_pkg::U_BSRC_ONE:      b_bus = 32'd1;
      rd68011_ucode_pkg::U_BSRC_TWO:      b_bus = 32'd2;
      rd68011_ucode_pkg::U_BSRC_FOUR:     b_bus = 32'd4;
      rd68011_ucode_pkg::U_BSRC_PC:       b_bus = pc;
      rd68011_ucode_pkg::U_BSRC_IR_PC:    b_bus = ir_pc;
      rd68011_ucode_pkg::U_BSRC_IRC_PC:   b_bus = irc_pc;
      rd68011_ucode_pkg::U_BSRC_IRC:      b_bus = {16'd0, irc};
      rd68011_ucode_pkg::U_BSRC_IRC_SX:   b_bus = {{16{irc[15]}}, irc};
      rd68011_ucode_pkg::U_BSRC_IR_SXB:   b_bus = {{24{ir[7]}}, ir[7:0]};
      rd68011_ucode_pkg::U_BSRC_T0:       b_bus = t0;
      rd68011_ucode_pkg::U_BSRC_T1:       b_bus = t1;
      rd68011_ucode_pkg::U_BSRC_RDATA:    b_bus = {16'd0, req_rdata};
      rd68011_ucode_pkg::U_BSRC_RDATA_SX: b_bus = {{16{req_rdata[15]}}, req_rdata};
      rd68011_ucode_pkg::U_BSRC_REG:      b_bus = `RDREG(reg_index);
      rd68011_ucode_pkg::U_BSRC_RDATA_B:  b_bus = {24'd0, rdata_byte};
      rd68011_ucode_pkg::U_BSRC_INDEX:    b_bus = index_val;
      rd68011_ucode_pkg::U_BSRC_IRC_SXB:  b_bus = {{24{irc[7]}}, irc[7:0]};
      rd68011_ucode_pkg::U_BSRC_DBUF:     b_bus = dbuf;
      rd68011_ucode_pkg::U_BSRC_REG2:     b_bus = reg2_val;
      rd68011_ucode_pkg::U_BSRC_QUICK:    b_bus = quick_val;
      rd68011_ucode_pkg::U_BSRC_BITMASK:  b_bus = bit_mask;
      rd68011_ucode_pkg::U_BSRC_SCC:      b_bus = {32{cc_true}};
      rd68011_ucode_pkg::U_BSRC_BIT7:     b_bus = 32'h0000_0080;
      rd68011_ucode_pkg::U_BSRC_EAL:      b_bus = ea_latch;
      rd68011_ucode_pkg::U_BSRC_SRSAVE:   b_bus = {16'd0, sr_save};
      rd68011_ucode_pkg::U_BSRC_VBR:      b_bus = vbr;
      rd68011_ucode_pkg::U_BSRC_VECOFF:   b_bus = {22'd0, vec_num, 2'd0};
      rd68011_ucode_pkg::U_BSRC_FMTVEC:   b_bus = {18'd0, 4'h0, vec_num, 2'd0};
      rd68011_ucode_pkg::U_BSRC_SR:       b_bus = {16'd0, sr};
      rd68011_ucode_pkg::U_BSRC_CCRVAL:   b_bus = {24'd0, 3'd0, sr[4:0]};
      rd68011_ucode_pkg::U_BSRC_USP:      b_bus = usp;
      rd68011_ucode_pkg::U_BSRC_IRQVEC:   b_bus = {8'd0, 20'hFFFFF, irq_taken, 1'b1};
      rd68011_ucode_pkg::U_BSRC_IRQPC:    b_bus = irq_from_stop ? pc : ir_pc;
      rd68011_ucode_pkg::U_BSRC_DIVRES:   b_bus = {div_r, div_q};
      default:                            b_bus = 32'd0;
    endcase
  end

  // The shift count: an immediate one to eight from bits 11:9, or the low six
  // bits of the register they name, depending on bit 5 (PRM section 4).
  logic [5:0] shift_count;
  // The memory forms shift by one and have no count field at all -- the bits
  // a register form would take it from are their addressing mode.
  assign shift_count = `UF(uw, SHONE) ? 6'd1
                     : ir[5] ? regs[{1'b0, ir[11:9]}][5:0]
                             : ((ir[11:9] == 3'd0) ? 6'd8 : {3'd0, ir[11:9]});

  // The bit a BTST/BCHG/BCLR/BSET names, as a mask. The number comes from a
  // register for the dynamic forms and from the extension word for the static
  // ones, and it is taken modulo the operand's width -- 32 for a register
  // destination, 8 for a memory one (PRM section 4).
  // The condition code test of PRM section 3, on bits 11:8. Bcc, DBcc and Scc
  // all use it, and it is the only place the flags are read as a group.
  logic cc_true;
  always_comb begin
    unique case (ir[11:8])
      4'h0: cc_true = 1'b1;                                        // T
      4'h1: cc_true = 1'b0;                                        // F
      4'h2: cc_true = !sr[rd68011_pkg::SR_C] && !sr[rd68011_pkg::SR_Z];  // HI
      4'h3: cc_true =  sr[rd68011_pkg::SR_C] ||  sr[rd68011_pkg::SR_Z];  // LS
      4'h4: cc_true = !sr[rd68011_pkg::SR_C];                      // CC
      4'h5: cc_true =  sr[rd68011_pkg::SR_C];                      // CS
      4'h6: cc_true = !sr[rd68011_pkg::SR_Z];                      // NE
      4'h7: cc_true =  sr[rd68011_pkg::SR_Z];                      // EQ
      4'h8: cc_true = !sr[rd68011_pkg::SR_V];                      // VC
      4'h9: cc_true =  sr[rd68011_pkg::SR_V];                      // VS
      4'hA: cc_true = !sr[rd68011_pkg::SR_N];                      // PL
      4'hB: cc_true =  sr[rd68011_pkg::SR_N];                      // MI
      4'hC: cc_true =  (sr[rd68011_pkg::SR_N] == sr[rd68011_pkg::SR_V]); // GE
      4'hD: cc_true =  (sr[rd68011_pkg::SR_N] != sr[rd68011_pkg::SR_V]); // LT
      4'hE: cc_true =  (sr[rd68011_pkg::SR_N] == sr[rd68011_pkg::SR_V]) &&
                       !sr[rd68011_pkg::SR_Z];                     // GT
      default: cc_true = (sr[rd68011_pkg::SR_N] != sr[rd68011_pkg::SR_V]) ||
                          sr[rd68011_pkg::SR_Z];                   // LE
    endcase
  end

  // -- Interrupts -----------------------------------------------------------
  //
  // UM section 6: a request is taken when its level is higher than the mask in
  // the status register, and level seven is taken whatever the mask says. The
  // decision is made where an instruction ends, which is the only place the
  // machine is in a state an exception can be built from.
  logic [2:0] irq_level;
  logic       irq_pending;
  logic [2:0] irq_taken;      // the level being serviced, latched
  logic       trace_armed;    // the trace bit as the current instruction began
  logic       irq_from_stop;  // this interrupt woke a STOP
  logic [7:0] irq_vec;
  logic       irq_auto;

  assign irq_level   = ~ipl_sync_n;
  assign irq_pending = (irq_level == 3'd7) ||
                       (irq_level > sr[rd68011_pkg::SR_I0+2 -: 3]);

  // The vector number: the one the device put on the bus, or the autovector
  // for its level when it answered with VPA instead (UM 5.1.4, appendix B.2).
  assign irq_auto = (req_end == rd68011_pkg::CE_AVEC);
  assign irq_vec  = irq_auto ? (rd68011_pkg::VEC_AUTOVEC0 + {5'd0, irq_taken})
                             : req_rdata[7:0];

  // The vector an exception is taking, and the two things built from it: the
  // offset into the vector table, and the frame's format-and-offset word,
  // whose top four bits are the format code -- zero for the four-word frame
  // (UM section 6, figure 6-6).
  logic  [7:0] vec_num;
  always_comb begin
    unique case (`UF(uw, VSEL))
      2'd1:    vec_num = {4'd2, ir[3:0]};   // TRAP #n is vector 32 + n
      2'd2:    vec_num = irq_vec;           // the interrupt's own
      default: vec_num = `UF(uw, VEC);
    endcase
  end

  logic  [4:0] bit_num;
  logic [31:0] bit_mask;
  logic        bit_z;

  always_comb begin
    // Modulo 32 covers both cases: a memory destination reduces further, to
    // modulo 8, and a register destination uses all five bits.
    bit_num = `UF(uw, BITIMM) ? irc[4:0] : regs[{1'b0, ir[11:9]}][4:0];
    if (f_size == rd68011_ucode_pkg::U_SIZE_LONG) begin
      bit_mask = 32'd1 << bit_num;
    end else begin
      bit_mask = 32'd1 << bit_num[2:0];
    end
  end

  // The tested bit, taken from the two source buses rather than from the mask
  // directly: the static forms have to save the mask before the prefetch
  // replaces the extension word it came from, so by the time the test happens
  // it arrives on the A bus out of the data output buffer.
  assign bit_z = ((b_bus & a_bus) == 32'd0);

  // The divider, which is sequential: the sequencer waits on it the way it
  // waits on a bus cycle. See rd68011_divider for why this one unit is not
  // combinational like the rest.
  logic        div_busy, div_ovf;
  logic [15:0] div_q, div_r;

  rd68011_divider u_divider (
      .clk       (clk),
      .rst_n     (rst_n),
      .start     (retire && `UF(uw, DIVST)),
      .is_signed (`UF(uw, DIVSG)),
      .dividend  (b_bus),
      .divisor   (a_bus[15:0]),
      .busy      (div_busy),
      .quotient  (div_q),
      .remainder (div_r),
      .ovf       (div_ovf)
  );

  logic [31:0] sh_out;
  logic        sh_c, sh_v, sh_xupd;

  rd68011_shifter u_shifter (
      .sh    (`UF(uw, SH)),
      .size  (f_size),
      .count (shift_count),
      .din   (b_bus),
      .x_in  (sr[rd68011_pkg::SR_X]),
      .dout  (sh_out),
      .c_out (sh_c),
      .v_out (sh_v),
      .x_upd (sh_xupd)
  );

  logic [31:0] alu_y;

  rd68011_alu u_alu (
      .op (f_alu), .size (f_size), .a (a_bus), .b (b_bus),
      .x_in (sr[rd68011_pkg::SR_X]), .y (alu_y),
      .n_out (n_flag_alu), .z_out (z_flag_alu), .v_out (v_flag),
      .c_out (c_flag)
  );

  // The shifter shares the result path, so everything downstream -- the
  // destination merge, the register write, the data output buffer -- is the
  // same for a shift as for anything else.
  assign y      = (f_alu == rd68011_ucode_pkg::U_ALU_SHIFT) ? sh_out : alu_y;
  assign n_flag = (f_alu == rd68011_ucode_pkg::U_ALU_SHIFT)
                    ? ((f_size == rd68011_ucode_pkg::U_SIZE_BYTE) ? y[7]
                     : (f_size == rd68011_ucode_pkg::U_SIZE_WORD) ? y[15] : y[31])
                    : n_flag_alu;
  assign z_flag = (f_alu == rd68011_ucode_pkg::U_ALU_SHIFT)
                    ? ((f_size == rd68011_ucode_pkg::U_SIZE_BYTE) ? (y[7:0] == 8'd0)
                     : (f_size == rd68011_ucode_pkg::U_SIZE_WORD) ? (y[15:0] == 16'd0)
                     : (y == 32'd0))
                    : z_flag_alu;

  // ===========================================================================
  // The address register update
  //
  // (An)+ and -(An) have to modify the register in the same microword that
  // addresses through it -- the reference gives MOVE.W (A0)+,D0 two bus cycles
  // and no internal ones -- so this is a second write port, independent of the
  // ALU's destination.
  //
  // The amount is the operation's size, except that a byte access through A7
  // moves it by two: the stack pointer stays even (PRM section 2).
  // ===========================================================================
  logic [3:0]  ea_areg;
  logic [31:0] ea_base;
  logic [31:0] ea_inc;
  logic [31:0] ea_updated;
  logic [31:0] ea_used;      // the address this microword actually addresses
  logic        aupd_we;

  // The address side reads its register field through aeasel, which is not
  // always the same half of the opcode the data side uses.
  logic [2:0] aea_reg;
  always_comb begin
    unique case (`UF(uw, AEASEL))
      rd68011_ucode_pkg::U_AEASEL_DST: aea_reg = ir[11:9];
      rd68011_ucode_pkg::U_AEASEL_SP:  aea_reg = 3'b111;
      default:                         aea_reg = ir[2:0];
    endcase
  end

  assign ea_areg = {1'b1, aea_reg};
  assign ea_base = `RDREG(ea_areg);

  always_comb begin
    unique case (f_size)
      rd68011_ucode_pkg::U_SIZE_BYTE: ea_inc = (ea_areg == 4'd15) ? 32'd2 : 32'd1;
      rd68011_ucode_pkg::U_SIZE_LONG: ea_inc = 32'd4;
      default:                        ea_inc = 32'd2;
    endcase
  end

  always_comb begin
    ea_updated = ea_base;
    ea_used    = ea_base;
    aupd_we    = 1'b0;
    unique case (f_aupd)
      rd68011_ucode_pkg::U_AUPD_POST: begin
        ea_updated = ea_base + ea_inc;
        aupd_we    = 1'b1;
      end
      // RTR pops a status word and a long together, so its stack pointer
      // moves by six rather than by an operand size.
      rd68011_ucode_pkg::U_AUPD_POST6: begin
        ea_updated = ea_base + 32'd6;
        aupd_we    = 1'b1;
      end
      // Room for the four-word exception frame, in one step.
      rd68011_ucode_pkg::U_AUPD_PRE8: begin
        ea_updated = ea_base - 32'd8;
        ea_used    = ea_base - 32'd8;
        aupd_we    = 1'b1;
      end
      rd68011_ucode_pkg::U_AUPD_POST8: begin
        ea_updated = ea_base + 32'd8;
        aupd_we    = 1'b1;
      end
      rd68011_ucode_pkg::U_AUPD_PRE: begin
        ea_updated = ea_base - ea_inc;
        ea_used    = ea_base - ea_inc;
        aupd_we    = 1'b1;
      end
      default: ;   // NONE and LATCH leave the register alone
    endcase
    // The address the cycle actually uses is computed on the next-microword
    // path (n_ea_addr), for the same reason every other request field is:
    // the bus unit latches it on the edge that ends the previous cycle.
  end

  // ===========================================================================
  // Next values of every register the bus address can come from
  //
  // These exist because the request presented to the bus unit has to use the
  // values the registers will have after this edge, not the ones they have now.
  // Registering them is then a plain assignment, which is also why there is one
  // place to look for what a microword does to the datapath.
  // ===========================================================================
  logic [31:0] pc_nxt, t0_nxt, t1_nxt, ea_latch_nxt;
  // The destination register's current value, for the byte and word merges.
  logic [31:0] wreg_val;
  logic [31:0] dbuf_nxt;
  logic [31:0] reg_wdata;
  logic        reg_we;
  logic        addr_lsb;      // low bit of the address of the cycle in progress
  logic [15:0] sr_nxt;

  assign wreg_val = `RDREG(wreg_index);

  always_comb begin
    pc_nxt       = pc;
    t0_nxt       = t0;
    t1_nxt       = t1;
    // The address output buffer keeps whatever address the address unit last
    // produced. Every read-modify-write needs it: the reference shape is
    // read, prefetch, write, and the prefetch replaces ir, so by the time the
    // write runs the register field that named the address has gone.
    //
    // Only the base form latches, not EA_PLUS2, so the second word of a long
    // transfer leaves the base intact for the write that follows.
    ea_latch_nxt = (retire &&
                    ((f_aupd != rd68011_ucode_pkg::U_AUPD_NONE) ||
                     (bus_busy && (f_asel == rd68011_ucode_pkg::U_ASEL_EA))))
                     ? ea_used : ea_latch;
    dbuf_nxt  = dbuf;
    reg_wdata = y;
    reg_we    = 1'b0;

    if (retire) begin
      // A prefetch advances pc by one word.
      if (pf_fetch) pc_nxt = pc + 32'd2;

      // The address unit's own incrementer, so the ALU stays free for data.
      // A microword must not both post-increment a register and write it.
      if (bus_busy && (f_asel == rd68011_ucode_pkg::U_ASEL_T0_INC2)) begin
        t0_nxt = t0 + 32'd2;
      end
      // Downward, the address used *is* the new value, so T0 moves first and
      // the address unit reads it already decremented.
      if (bus_busy && (f_asel == rd68011_ucode_pkg::U_ASEL_T0_DEC2)) begin
        t0_nxt = t0 - 32'd2;
      end

      unique case (f_dst)
        rd68011_ucode_pkg::U_DST_PC:      pc_nxt   = y;
        rd68011_ucode_pkg::U_DST_T0:      t0_nxt   = y;
        rd68011_ucode_pkg::U_DST_T1:      t1_nxt   = y;
        rd68011_ucode_pkg::U_DST_T0_SHW:  t0_nxt   = {t0[15:0], y[15:0]};
        rd68011_ucode_pkg::U_DST_T1_SHW:  t1_nxt   = {t1[15:0], y[15:0]};
        rd68011_ucode_pkg::U_DST_T0_HIW:  t0_nxt   = {y[15:0], t0[15:0]};
        rd68011_ucode_pkg::U_DST_T1_HIW:  t1_nxt   = {y[15:0], t1[15:0]};
        rd68011_ucode_pkg::U_DST_DBUF_SHW: dbuf_nxt = {dbuf[15:0], y[15:0]};
        // UM table 3-1's footnote: a byte write drives the byte on both
        // halves of the bus and lets the strobe decide which lands. Doing the
        // duplication here means it holds however the buffer is read back.
        rd68011_ucode_pkg::U_DST_DBUF:
          dbuf_nxt = (f_size == rd68011_ucode_pkg::U_SIZE_BYTE)
                       ? {y[31:16], y[7:0], y[7:0]} : y;
        // A byte or word write to a data register leaves the rest of it
        // alone (PRM section 2); a long write replaces the lot.
        rd68011_ucode_pkg::U_DST_REG: begin
          reg_we = 1'b1;
          unique case (f_size)
            rd68011_ucode_pkg::U_SIZE_BYTE:
              reg_wdata = {wreg_val[31:8], y[7:0]};
            rd68011_ucode_pkg::U_SIZE_WORD:
              reg_wdata = {wreg_val[31:16], y[15:0]};
            default:
              reg_wdata = y;
          endcase
        end
        rd68011_ucode_pkg::U_DST_REG_L: reg_we = 1'b1;
        // MOVES: "if the destination is a data register, the source operand
        // replaces the corresponding low-order bits ... if the destination is
        // an address register, the source operand is sign-extended to 32 bits
        // and then loaded" (PRM section 6).
        rd68011_ucode_pkg::U_DST_REG_AD: begin
          reg_we = 1'b1;
          if (wreg_index[3]) begin
            unique case (f_size)
              rd68011_ucode_pkg::U_SIZE_BYTE: reg_wdata = {{24{y[7]}}, y[7:0]};
              rd68011_ucode_pkg::U_SIZE_WORD: reg_wdata = {{16{y[15]}},
                                                           y[15:0]};
              default:                        reg_wdata = y;
            endcase
          end else begin
            unique case (f_size)
              rd68011_ucode_pkg::U_SIZE_BYTE:
                reg_wdata = {wreg_val[31:8], y[7:0]};
              rd68011_ucode_pkg::U_SIZE_WORD:
                reg_wdata = {wreg_val[31:16], y[15:0]};
              default: reg_wdata = y;
            endcase
          end
        end
        // The high half alone, for a long that arrives a word at a time:
        // MOVEM.L to registers reads the high word first.
        rd68011_ucode_pkg::U_DST_REG_HIW: begin
          reg_we    = 1'b1;
          reg_wdata = {y[15:0], wreg_val[15:0]};
        end
        rd68011_ucode_pkg::U_DST_USP:   ;   // written in the register block
        rd68011_ucode_pkg::U_DST_CREG:  ;   // ditto: not through the ALU port
        rd68011_ucode_pkg::U_DST_SETV:  ;   // handled with the flags
        // RTR restores the condition codes and leaves the supervisor half of
        // the status register alone (PRM section 4).
        rd68011_ucode_pkg::U_DST_CCR: ;
        default: ;   // NONE and SR, which is not written from here yet
      endcase
    end
  end

  // ===========================================================================
  // Condition codes
  //
  // PRM section 4 gives them per instruction; they collapse to a few rules,
  // and which rule a microword uses is its `ccr` field. X is deliberately
  // separate from C: most operations leave it alone, which is the whole point
  // of having both.
  // ===========================================================================
  always_comb begin
    sr_nxt = sr;
    if (retire) begin
      unique case (f_ccr)
        rd68011_ucode_pkg::U_CCR_LOGIC: begin
          sr_nxt[rd68011_pkg::SR_N] = n_flag;
          sr_nxt[rd68011_pkg::SR_Z] = z_flag;
          sr_nxt[rd68011_pkg::SR_V] = 1'b0;
          sr_nxt[rd68011_pkg::SR_C] = 1'b0;
        end
        rd68011_ucode_pkg::U_CCR_ARITH: begin
          sr_nxt[rd68011_pkg::SR_N] = n_flag;
          sr_nxt[rd68011_pkg::SR_Z] = z_flag;
          sr_nxt[rd68011_pkg::SR_V] = v_flag;
          sr_nxt[rd68011_pkg::SR_C] = c_flag;
          sr_nxt[rd68011_pkg::SR_X] = c_flag;
        end
        rd68011_ucode_pkg::U_CCR_CMP: begin
          sr_nxt[rd68011_pkg::SR_N] = n_flag;
          sr_nxt[rd68011_pkg::SR_Z] = z_flag;
          sr_nxt[rd68011_pkg::SR_V] = v_flag;
          sr_nxt[rd68011_pkg::SR_C] = c_flag;
        end
        rd68011_ucode_pkg::U_CCR_ARITHX: begin
          sr_nxt[rd68011_pkg::SR_N] = n_flag;
          // Z is only ever cleared: a multi-precision result reads as zero
          // only if every part of it was.
          if (!z_flag) sr_nxt[rd68011_pkg::SR_Z] = 1'b0;
          sr_nxt[rd68011_pkg::SR_V] = v_flag;
          sr_nxt[rd68011_pkg::SR_C] = c_flag;
          sr_nxt[rd68011_pkg::SR_X] = c_flag;
        end
        rd68011_ucode_pkg::U_CCR_LOGIC_A: begin
          sr_nxt[rd68011_pkg::SR_N] =
              (f_size == rd68011_ucode_pkg::U_SIZE_BYTE) ? a_bus[7]
            : (f_size == rd68011_ucode_pkg::U_SIZE_WORD) ? a_bus[15] : a_bus[31];
          sr_nxt[rd68011_pkg::SR_Z] =
              (f_size == rd68011_ucode_pkg::U_SIZE_BYTE) ? (a_bus[7:0] == 8'd0)
            : (f_size == rd68011_ucode_pkg::U_SIZE_WORD) ? (a_bus[15:0] == 16'd0)
            : (a_bus == 32'd0);
          sr_nxt[rd68011_pkg::SR_V] = 1'b0;
          sr_nxt[rd68011_pkg::SR_C] = 1'b0;
        end
        rd68011_ucode_pkg::U_CCR_BIT: begin
          sr_nxt[rd68011_pkg::SR_Z] = bit_z;
        end
        rd68011_ucode_pkg::U_CCR_SHIFT: begin
          sr_nxt[rd68011_pkg::SR_N] = n_flag;
          sr_nxt[rd68011_pkg::SR_Z] = z_flag;
          sr_nxt[rd68011_pkg::SR_V] = sh_v;
          sr_nxt[rd68011_pkg::SR_C] = sh_c;
          if (sh_xupd) sr_nxt[rd68011_pkg::SR_X] = sh_c;
        end
        default: ;
      endcase
      if (f_dst == rd68011_ucode_pkg::U_DST_SR) sr_nxt = y[15:0];
      // The whole status register, including the bits that decide which stack
      // pointer A7 is. RTE and MOVE to SR both write it.
      if (f_dst == rd68011_ucode_pkg::U_DST_SR_ALL) begin
        sr_nxt = y[15:0] & rd68011_pkg::SR_IMPLEMENTED;
      end
      // A division that overflowed leaves the destination register alone.
      // PRM calls N and Z undefined here; what the part does is set N and
      // clear Z, the same way in every one of the reference's 791 overflow
      // cases, so that is what this does.
      if (f_dst == rd68011_ucode_pkg::U_DST_SETV) begin
        sr_nxt[rd68011_pkg::SR_N] = 1'b1;
        sr_nxt[rd68011_pkg::SR_Z] = 1'b0;
        sr_nxt[rd68011_pkg::SR_V] = 1'b1;
        sr_nxt[rd68011_pkg::SR_C] = 1'b0;
      end
      if (f_dst == rd68011_ucode_pkg::U_DST_CCR) begin
        sr_nxt[7:0] = y[7:0] & 8'h1F;   // only the five defined bits
      end
      // Entering exception processing: supervisor mode on, trace off, and the
      // old value kept for the frame. UM section 6.
      if (f_dst == rd68011_ucode_pkg::U_DST_SR_EXC) begin
        sr_nxt[rd68011_pkg::SR_S] = 1'b1;
        sr_nxt[rd68011_pkg::SR_T] = 1'b0;
      end
      if (f_dst == rd68011_ucode_pkg::U_DST_SR_IRQ) begin
        sr_nxt[rd68011_pkg::SR_S] = 1'b1;
        sr_nxt[rd68011_pkg::SR_T] = 1'b0;
        sr_nxt[rd68011_pkg::SR_I0+2 -: 3] = irq_taken;
      end
    end
  end

  // ===========================================================================
  // Micro-address
  // ===========================================================================
  logic cond_true;

  always_comb begin
    unique case (f_cond)
      rd68011_ucode_pkg::U_COND_SUPER: cond_true = sr[rd68011_pkg::SR_S];
      rd68011_ucode_pkg::U_COND_CC:    cond_true = cc_true;
      // DBcc's counter, tested on the value being written rather than on the
      // register, so the decrement and the test are one microword.
      rd68011_ucode_pkg::U_COND_CNT:   cond_true = (y[15:0] == 16'hFFFF);
      rd68011_ucode_pkg::U_COND_V:     cond_true = sr[rd68011_pkg::SR_V];
      // UM 6.4: RTE checks the frame's format code before it commits to
      // anything, and raises a format error on one it does not know.
      rd68011_ucode_pkg::U_COND_FMT0:  cond_true = (req_rdata[15:12] == 4'h0);
      rd68011_ucode_pkg::U_COND_N:     cond_true = n_flag;
      rd68011_ucode_pkg::U_COND_RSTB:  cond_true = reset_busy;
      rd68011_ucode_pkg::U_COND_ZERO:  cond_true = z_flag;
      rd68011_ucode_pkg::U_COND_DIVB:  cond_true = div_busy;
      rd68011_ucode_pkg::U_COND_MASK:  cond_true = (xw_after != 16'd0);
      rd68011_ucode_pkg::U_COND_CRVALID: cond_true = creg_valid;
      rd68011_ucode_pkg::U_COND_XWDR:  cond_true = xw_after[11];
      rd68011_ucode_pkg::U_COND_DIVV:  cond_true = div_ovf;
      default:                         cond_true = 1'b0;
    endcase
  end

  always_comb begin
    if (f_seq == rd68011_ucode_pkg::U_SEQ_DECODE) begin
      upc_target = dec_entry;
    end else begin
      // A conditional branch lands on next, or next+1 when the condition
      // holds. The assembler checks the target is even, so setting bit zero
      // is the whole of it.
      upc_target = `UF(uw, NEXT);
      if ((f_seq == rd68011_ucode_pkg::U_SEQ_COND) && cond_true) begin
        upc_target[0] = 1'b1;
      end
    end
  end

  // An external reset holds the sequencer at the reset entry point (UM 5.5).
  //
  // A pending interrupt is taken instead of the next instruction, at the point
  // the microcode would have decoded one -- which is where the machine is in a
  // state the exception frame can be built from. STOP waits here too, for the
  // same signal.
  // Trace, and the order the two are taken in. UM table 6-1 puts trace above
  // interrupt: an instruction that both completes under trace and finds an
  // interrupt waiting is traced first, and the interrupt is taken by the
  // handler's first instruction boundary.
  //
  // UM section 6: "If the trace state is on at the beginning of the execution
  // of an instruction, a trace exception will be generated after the execution
  // of that instruction is completed" -- so the bit is sampled where an
  // instruction starts, not where it ends.
  logic take_irq;
  logic take_trace;

  assign take_irq   = irq_pending &&
                      ((f_seq == rd68011_ucode_pkg::U_SEQ_DECODE) ||
                       `UF(uw, STOP));
  assign take_trace = trace_armed &&
                      (f_seq == rd68011_ucode_pkg::U_SEQ_DECODE);

  assign upc_nxt = !reset_sync_n ? rd68011_ucode_pkg::ENTRY_RESET
                 : !retire       ? upc
                 : take_trace    ? rd68011_ucode_pkg::ENTRY_TRACE
                 : take_irq      ? rd68011_ucode_pkg::ENTRY_INTERRUPT
                 : `UF(uw, STOP) ? upc
                                 : upc_target;

  // ===========================================================================
  // The bus request, built from the microword that comes next
  // ===========================================================================
  logic [rd68011_ucode_pkg::U_BUS_W-1:0]  n_bus;
  logic [rd68011_ucode_pkg::U_ASEL_W-1:0] n_asel;
  logic [rd68011_ucode_pkg::U_FC_W-1:0]   n_fc;
  logic [rd68011_ucode_pkg::U_SIZE_W-1:0] n_size;
  logic [31:0] n_addr;

  // The address register the *next* microword will use, with its own update
  // applied, for the same reason every other request field comes from the next
  // microword: the bus unit latches all of it on the edge that ends this cycle.
  logic [rd68011_ucode_pkg::U_AUPD_W-1:0] n_aupd;
  logic [rd68011_ucode_pkg::U_SIZE_W-1:0] n_easize;
  logic  [2:0] n_ea_reg;
  logic  [3:0] n_ea_areg;
  logic [31:0] n_ea_base, n_ea_inc, n_ea_addr;

  assign n_aupd   = `UF(uw_nxt, AUPD);
  assign n_easize = `UF(uw_nxt, SIZE);

  always_comb begin
    unique case (`UF(uw_nxt, AEASEL))
      rd68011_ucode_pkg::U_AEASEL_DST: n_ea_reg = ir_nxt[11:9];
      rd68011_ucode_pkg::U_AEASEL_SP:  n_ea_reg = 3'b111;
      default:                         n_ea_reg = ir_nxt[2:0];
    endcase
  end

  assign n_ea_areg = {1'b1, n_ea_reg};
  // Bypass: if this edge writes the register the next microword addresses
  // through, the next microword has to see the new value, because the register
  // file will not have it until after the edge.
  //
  // Only when the current microword is actually retiring. Until then uw_nxt is
  // this same microword, and letting the bypass through would hand (An)+ its
  // own incremented value as the address -- addressing An+2 instead of An.
  assign n_ea_base = (reg_we && (wreg_index == n_ea_areg))          ? reg_wdata
                   : (retire && aupd_we && (ea_areg == n_ea_areg))  ? ea_updated
                   : `RDREG(n_ea_areg);

  always_comb begin
    unique case (n_easize)
      rd68011_ucode_pkg::U_SIZE_BYTE: n_ea_inc = (n_ea_areg == 4'd15) ? 32'd2 : 32'd1;
      rd68011_ucode_pkg::U_SIZE_LONG: n_ea_inc = 32'd4;
      default:                        n_ea_inc = 32'd2;
    endcase
  end

  assign n_ea_addr = (n_aupd == rd68011_ucode_pkg::U_AUPD_PRE)
                       ? (n_ea_base - n_ea_inc) : n_ea_base;

  assign n_bus  = `UF(uw_nxt, BUS);
  assign n_asel = `UF(uw_nxt, ASEL);
  assign n_fc   = `UF(uw_nxt, FC);
  assign n_size = `UF(uw_nxt, SIZE);

  always_comb begin
    unique case (n_asel)
      rd68011_ucode_pkg::U_ASEL_PC:       n_addr = pc_nxt;
      rd68011_ucode_pkg::U_ASEL_T0,
      rd68011_ucode_pkg::U_ASEL_T0_INC2:  n_addr = t0_nxt;
      rd68011_ucode_pkg::U_ASEL_T0_PLUS2: n_addr = t0_nxt + 32'd2;
      rd68011_ucode_pkg::U_ASEL_T0_PLUS4: n_addr = t0_nxt + 32'd4;
      rd68011_ucode_pkg::U_ASEL_T0_PLUS6: n_addr = t0_nxt + 32'd6;
      rd68011_ucode_pkg::U_ASEL_T0_DEC2:  n_addr = t0_nxt - 32'd2;
      rd68011_ucode_pkg::U_ASEL_T1:       n_addr = t1_nxt;
      rd68011_ucode_pkg::U_ASEL_EA:       n_addr = n_ea_addr;
      rd68011_ucode_pkg::U_ASEL_EA_PLUS2: n_addr = n_ea_addr + 32'd2;
      rd68011_ucode_pkg::U_ASEL_EA_PLUS4:  n_addr = n_ea_addr + 32'd4;
      rd68011_ucode_pkg::U_ASEL_EA_PLUS6:  n_addr = n_ea_addr + 32'd6;
      rd68011_ucode_pkg::U_ASEL_PC_MINUS2: n_addr = pc_nxt - 32'd2;
      rd68011_ucode_pkg::U_ASEL_EAL_PLUS4: n_addr = ea_latch_nxt + 32'd4;
      rd68011_ucode_pkg::U_ASEL_EAL_PLUS6: n_addr = ea_latch_nxt + 32'd6;
      rd68011_ucode_pkg::U_ASEL_EAL:       n_addr = ea_latch_nxt;
      rd68011_ucode_pkg::U_ASEL_EAL_PLUS2: n_addr = ea_latch_nxt + 32'd2;
      default:                            n_addr = pc_nxt;
    endcase
  end

  // UM table 3-3: program and data space follow the S bit; CPU space is 7.
  //
  // The *next* S bit, for the same reason every other request field comes from
  // the next microword: the bus unit latches the function code on the edge
  // that ends the previous cycle. MOVE to SR is where it shows -- the re-fetch
  // it does afterwards happens in whatever mode the new status register says,
  // which is the entire point of it.
  always_comb begin
    unique case (n_fc)
      rd68011_ucode_pkg::U_FC_DATA: req_fc = sr_nxt[rd68011_pkg::SR_S] ?
                                             rd68011_pkg::FC_SUPER_D :
                                             rd68011_pkg::FC_USER_D;
      rd68011_ucode_pkg::U_FC_CPU:  req_fc = rd68011_pkg::FC_CPU;
      // MOVES reaches the space its own registers name, whatever mode the
      // processor is in (PRM section 6).
      rd68011_ucode_pkg::U_FC_SFC:  req_fc = sfc;
      rd68011_ucode_pkg::U_FC_DFC:  req_fc = dfc;
      default:                      req_fc = sr_nxt[rd68011_pkg::SR_S] ?
                                             rd68011_pkg::FC_SUPER_P :
                                             rd68011_pkg::FC_USER_P;
    endcase
  end

  // UM table 3-1: a byte transfer asserts one strobe, chosen by the address's
  // low bit; a word transfer asserts both. There is no A0 pin, so this is the
  // only thing that carries it.
  always_comb begin
    if (n_size == rd68011_ucode_pkg::U_SIZE_BYTE) begin
      req_uds = !n_addr[0];
      req_lds =  n_addr[0];
    end else begin
      req_uds = 1'b1;
      req_lds = 1'b1;
    end
  end

  assign req_valid = (n_bus != rd68011_ucode_pkg::U_BUS_NONE) && reset_sync_n;
  assign req_kind  = n_bus;
  assign req_addr  = n_addr[23:1];
  // The write data comes from the microword that is issuing the write, not
  // from a microword before it: the bus unit latches it on the falling edge
  // entering S3 (UM 5.1.2 state 3), a clock and a half after the cycle starts,
  // which is long enough for this microword's own ALU result to be there.
  // Loading it a microword early would cost a clock, and the reference gives
  // MOVE.W D0,(A0) two bus cycles and nothing else.
  //
  // UM table 3-1's footnote: on a byte write the processor drives the byte on
  // both halves of the bus, so the strobe alone decides which half lands.
  always_comb begin
    if (f_dst == rd68011_ucode_pkg::U_DST_DBUF) begin
      // This microword both fills the buffer and drives the bus, so the half
      // it sends comes from the value on its way in, not from the register.
      req_wdata = (f_size == rd68011_ucode_pkg::U_SIZE_BYTE)
                    ? {y[7:0], y[7:0]}
                    : (`UF(uw, DHI) ? y[31:16] : y[15:0]);
    end else begin
      req_wdata = `UF(uw, DHI) ? dbuf[31:16] : dbuf[15:0];
    end
  end

  // The RESET instruction's output pulse, started by the microcode and timed
  // by the bus unit (UM 5.5). Double bus fault detection is P6.
  assign reset_req = retire && `UF(uw, RSTREQ);
  assign dbf       = 1'b0;

  // ===========================================================================
  // Registers
  // ===========================================================================
  int unsigned i;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      upc    <= rd68011_ucode_pkg::ENTRY_RESET;
      pc     <= 32'd0;
      ir     <= 16'd0;
      irc    <= 16'd0;
      ir_pc  <= 32'd0;
      irc_pc <= 32'd0;
      t0       <= 32'd0;
      t1       <= 32'd0;
      ea_latch <= 32'd0;
      dbuf     <= 32'd0;
      xw    <= 16'd0;
      sfc      <= 3'd0;
      dfc      <= 3'd0;
      sr_save  <= 16'd0;
      irq_taken   <= 3'd0;
      trace_armed <= 1'b0;
      irq_from_stop <= 1'b0;
      // UM 5.5: the interrupt level is initialised to seven and, on the
      // MC68010, the vector base register is cleared. The supervisor bit is
      // set because reset always leaves the processor in supervisor mode.
      sr       <= 16'h2700;
      vbr      <= 32'd0;
      addr_lsb <= 1'b0;
      for (i = 0; i < 15; i = i + 1) begin
        regs[i] <= 32'd0;
      end
      usp <= 32'd0;
      ssp <= 32'd0;
    end else begin
      upc      <= upc_nxt;
      sr       <= sr_nxt;
      addr_lsb <= n_addr[0];
      pc     <= pc_nxt;
      ir     <= ir_nxt;
      irc    <= irc_nxt;
      ir_pc  <= ir_pc_nxt;
      irc_pc <= irc_pc_nxt;
      t0       <= t0_nxt;
      t1       <= t1_nxt;
      ea_latch <= ea_latch_nxt;
      dbuf   <= dbuf_nxt;
      if (retire) xw <= xw_after;
      // Both ways into exception processing keep the old status register for
      // the frame: the interrupt path raises the mask as well, but it still
      // has to stack what was there before.
      if (retire && ((f_dst == rd68011_ucode_pkg::U_DST_SR_EXC) ||
                     (f_dst == rd68011_ucode_pkg::U_DST_SR_IRQ))) begin
        sr_save <= sr;
      end
      // The level is latched as the interrupt is taken: it has to survive the
      // acknowledge cycle, which is what decides the vector.
      if (retire && take_irq) begin
        irq_taken     <= irq_level;
        irq_from_stop <= `UF(uw, STOP);
      end
      if (retire && (f_seq == rd68011_ucode_pkg::U_SEQ_DECODE)) begin
        trace_armed <= take_trace ? 1'b0 : sr_nxt[rd68011_pkg::SR_T];
      end
      // MOVE An,USP reaches the user stack pointer from supervisor mode, so
      // it cannot go through the ordinary A7 path.
      if (retire && (f_dst == rd68011_ucode_pkg::U_DST_USP)) begin
        usp <= y;
      end
      // MOVEC to a control register. SFC and DFC keep three bits of what is
      // written and read back zero-extended; the other two are whole
      // registers (PRM section 6).
      if (retire && (f_dst == rd68011_ucode_pkg::U_DST_CREG)) begin
        unique case (irc[11:0])
          12'h000: sfc <= y[2:0];
          12'h001: dfc <= y[2:0];
          12'h800: usp <= y;
          12'h801: vbr <= y;
          default: ;   // never reached: the microcode checks first
        endcase
      end
      if (reg_we) begin
        if (wreg_index == 4'd15) begin
          if (sr[rd68011_pkg::SR_S]) ssp <= reg_wdata;
          else                       usp <= reg_wdata;
        end else begin
          regs[wreg_index] <= reg_wdata;
        end
      end
      // The address register update is a separate port. A microword that both
      // writes a register through the ALU and modifies the same one through
      // the address unit is a microcode error; the assembler checks for it.
      if (retire && aupd_we) begin
        if (ea_areg == 4'd15) begin
          if (sr[rd68011_pkg::SR_S]) ssp <= ea_updated;
          else                       usp <= ea_updated;
        end else begin
          regs[ea_areg] <= ea_updated;
        end
      end
    end
  end

  // Inputs the sequencer will consume once exceptions and interrupts exist.
  logic unused_seq;
  // wreg_val's low bits: a byte merge keeps only the top 24 of the old value
  // and a word merge only the top 16, so the bottom byte is never read back.
  assign unused_seq = &{1'b1, req_ack, req_end, ipl_sync_n, halt_sync_n,
                        bus_idle, dec_illegal, vbr, wreg_val[7:0]};

  `undef UF
  `undef RDREG

endmodule
