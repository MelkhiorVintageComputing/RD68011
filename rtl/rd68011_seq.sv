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
  logic [15:0] dbuf;      // data output buffer
  logic [15:0] sr;
  logic [31:0] vbr;
  logic [31:0] regs [0:15];

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
  logic [rd68011_ucode_pkg::U_PF_W-1:0]   f_pf;
  logic [rd68011_ucode_pkg::U_RSEL_W-1:0] f_rsel;

  assign f_seq  = `UF(uw, SEQ);
  assign f_cond = `UF(uw, COND);
  assign f_asrc = `UF(uw, ASRC);
  assign f_bsrc = `UF(uw, BSRC);
  assign f_alu  = `UF(uw, ALU);
  assign f_dst  = `UF(uw, DST);
  assign f_bus  = `UF(uw, BUS);
  assign f_asel = `UF(uw, ASEL);
  assign f_pf   = `UF(uw, PF);
  assign f_rsel = `UF(uw, RSEL);

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

  // Register selection. Only fixed registers for now; selecting from the
  // opcode's register fields arrives with the addressing modes.
  logic [3:0] reg_index;
  always_comb begin
    unique case (f_rsel)
      rd68011_ucode_pkg::U_RSEL_A7: reg_index = 4'd15;
      default:                      reg_index = 4'd15;
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
      rd68011_ucode_pkg::U_ASRC_REG:      a_bus = regs[reg_index];
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
      rd68011_ucode_pkg::U_BSRC_REG:      b_bus = regs[reg_index];
      default:                            b_bus = 32'd0;
    endcase
  end

  rd68011_alu u_alu (.op (f_alu), .a (a_bus), .b (b_bus), .y (y));

  // ===========================================================================
  // Next values of every register the bus address can come from
  //
  // These exist because the request presented to the bus unit has to use the
  // values the registers will have after this edge, not the ones they have now.
  // Registering them is then a plain assignment, which is also why there is one
  // place to look for what a microword does to the datapath.
  // ===========================================================================
  logic [31:0] pc_nxt, t0_nxt, t1_nxt;
  logic [15:0] dbuf_nxt;
  logic [31:0] reg_wdata;
  logic        reg_we;

  always_comb begin
    pc_nxt    = pc;
    t0_nxt    = t0;
    t1_nxt    = t1;
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

      unique case (f_dst)
        rd68011_ucode_pkg::U_DST_PC:     pc_nxt   = y;
        rd68011_ucode_pkg::U_DST_T0:     t0_nxt   = y;
        rd68011_ucode_pkg::U_DST_T1:     t1_nxt   = y;
        rd68011_ucode_pkg::U_DST_T0_SHW: t0_nxt   = {t0[15:0], y[15:0]};
        rd68011_ucode_pkg::U_DST_T1_SHW: t1_nxt   = {t1[15:0], y[15:0]};
        rd68011_ucode_pkg::U_DST_DBUF:   dbuf_nxt = y[15:0];
        rd68011_ucode_pkg::U_DST_REG:    reg_we   = 1'b1;
        default: ;   // NONE and SR, which is not written from here yet
      endcase
    end
  end

  // ===========================================================================
  // Micro-address
  // ===========================================================================
  logic cond_true;

  always_comb begin
    unique case (f_cond)
      rd68011_ucode_pkg::U_COND_SUPER: cond_true = sr[rd68011_pkg::SR_S];
      // The Bcc condition test arrives with the condition codes.
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
  assign upc_nxt = !reset_sync_n ? rd68011_ucode_pkg::ENTRY_RESET
                                 : (retire ? upc_target : upc);

  // ===========================================================================
  // The bus request, built from the microword that comes next
  // ===========================================================================
  logic [rd68011_ucode_pkg::U_BUS_W-1:0]  n_bus;
  logic [rd68011_ucode_pkg::U_ASEL_W-1:0] n_asel;
  logic [rd68011_ucode_pkg::U_FC_W-1:0]   n_fc;
  logic [rd68011_ucode_pkg::U_SIZE_W-1:0] n_size;
  logic [31:0] n_addr;

  assign n_bus  = `UF(uw_nxt, BUS);
  assign n_asel = `UF(uw_nxt, ASEL);
  assign n_fc   = `UF(uw_nxt, FC);
  assign n_size = `UF(uw_nxt, SIZE);

  always_comb begin
    unique case (n_asel)
      rd68011_ucode_pkg::U_ASEL_PC:      n_addr = pc_nxt;
      rd68011_ucode_pkg::U_ASEL_T0,
      rd68011_ucode_pkg::U_ASEL_T0_INC2: n_addr = t0_nxt;
      rd68011_ucode_pkg::U_ASEL_T1:      n_addr = t1_nxt;
      default:                           n_addr = pc_nxt;
    endcase
  end

  // UM table 3-3: program and data space follow the S bit; CPU space is 7.
  always_comb begin
    unique case (n_fc)
      rd68011_ucode_pkg::U_FC_DATA: req_fc = sr[rd68011_pkg::SR_S] ?
                                             rd68011_pkg::FC_SUPER_D :
                                             rd68011_pkg::FC_USER_D;
      rd68011_ucode_pkg::U_FC_CPU:  req_fc = rd68011_pkg::FC_CPU;
      default:                      req_fc = sr[rd68011_pkg::SR_S] ?
                                             rd68011_pkg::FC_SUPER_P :
                                             rd68011_pkg::FC_USER_P;
    endcase
  end

  always_comb begin
    unique case (n_size)
      rd68011_ucode_pkg::U_SIZE_BYTE_U: begin req_uds = 1'b1; req_lds = 1'b0; end
      rd68011_ucode_pkg::U_SIZE_BYTE_L: begin req_uds = 1'b0; req_lds = 1'b1; end
      default:                          begin req_uds = 1'b1; req_lds = 1'b1; end
    endcase
  end

  assign req_valid = (n_bus != rd68011_ucode_pkg::U_BUS_NONE) && reset_sync_n;
  assign req_kind  = n_bus;
  assign req_addr  = n_addr[23:1];
  assign req_wdata = dbuf_nxt;

  // Not driven yet: the RESET instruction and double bus fault detection.
  assign reset_req = 1'b0;
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
      t0     <= 32'd0;
      t1     <= 32'd0;
      dbuf   <= 16'd0;
      // UM 5.5: the interrupt level is initialised to seven and, on the
      // MC68010, the vector base register is cleared. The supervisor bit is
      // set because reset always leaves the processor in supervisor mode.
      sr     <= 16'h2700;
      vbr    <= 32'd0;
      for (i = 0; i < 16; i = i + 1) begin
        regs[i] <= 32'd0;
      end
    end else begin
      upc    <= upc_nxt;
      pc     <= pc_nxt;
      ir     <= ir_nxt;
      irc    <= irc_nxt;
      ir_pc  <= ir_pc_nxt;
      irc_pc <= irc_pc_nxt;
      t0     <= t0_nxt;
      t1     <= t1_nxt;
      dbuf   <= dbuf_nxt;
      if (reg_we) begin
        regs[reg_index] <= reg_wdata;
      end
    end
  end

  // Inputs the sequencer will consume once exceptions and interrupts exist.
  logic unused_seq;
  assign unused_seq = &{1'b1, req_ack, req_end, ipl_sync_n, halt_sync_n,
                        bus_idle, dec_illegal, vbr};

  `undef UF

endmodule
