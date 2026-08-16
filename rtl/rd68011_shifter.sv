// RD68011 - shifter for ASL/ASR, LSL/LSR, ROL/ROR and ROXL/ROXR.
//
// PRM section 4 defines eight operations that differ only in what is shifted
// in and what the condition codes take from the operation. This does all of
// them in one step rather than one bit per clock as the original does: the
// architectural state and the bus behaviour are identical either way, and only
// the cycle count differs -- which doc/timing-divergences.md records.
//
// C is "the last bit shifted out of the operand" in every case, and a count of
// zero clears it -- except for ROXL/ROXR, where a count of zero leaves C equal
// to X. The plain shifts get that for free by placing the operand in a 64-bit
// word with room on the side the bits leave from, so the bit that left last is
// still there to be read afterwards.
//
// V is set only by ASL, and only when the sign changed at any point during the
// shift, which is to say when the top count+1 bits were not all the same.
//
// X follows C wherever the operation writes X at all; `x_upd` says whether it
// does. ROL and ROR never do, and neither does any operation with a zero count.

module rd68011_shifter (
    input  logic  [2:0] sh,      // {kind[1:0], left}: 0 AS, 1 LS, 2 ROX, 3 RO
    input  logic  [1:0] size,    // 0 byte, 1 word, 2 long
    input  logic  [5:0] count,
    input  logic [31:0] din,
    input  logic        x_in,
    output logic [31:0] dout,
    output logic        c_out,
    output logic        v_out,
    output logic        x_upd
);

  localparam logic [1:0] K_AS  = 2'd0;
  localparam logic [1:0] K_LS  = 2'd1;
  localparam logic [1:0] K_ROX = 2'd2;
  localparam logic [1:0] K_RO  = 2'd3;

  logic [1:0] kind;
  logic       left;
  assign kind = sh[2:1];
  assign left = sh[0];

  // -- The operand at its own width -------------------------------------------
  logic [5:0]  w;
  logic [31:0] mask;
  logic [31:0] v;         // zero-extended to 32 bits
  logic [31:0] vs;        // sign-extended to 32 bits
  logic        sign;

  always_comb begin
    unique case (size)
      2'd0:    begin w = 6'd8;  mask = 32'h0000_00FF; end
      2'd1:    begin w = 6'd16; mask = 32'h0000_FFFF; end
      default: begin w = 6'd32; mask = 32'hFFFF_FFFF; end
    endcase
  end

  // The operand's top bit, as a five-bit index: a 32-bit width wraps to 31,
  // which is exactly the position wanted.
  logic [4:0] topbit;
  assign topbit = w[4:0] - 5'd1;

  assign v    = din & mask;
  assign sign = v[topbit];
  assign vs   = sign ? (v | ~mask) : v;

  // -- Plain shifts -----------------------------------------------------------
  // Left: the operand sits in the low half, so a bit leaving the top of the
  // field lands at position w and survives to be read as the carry.
  // Right: the operand sits in the high half, so a bit leaving the bottom
  // lands at position 31. ASR shifts arithmetically, filling with the sign.
  logic [63:0] lsh, rsh_l, rsh_a;

  assign lsh   = {32'd0, v} << count;
  assign rsh_l = {v,  32'd0} >> count;
  assign rsh_a = $signed({vs, 32'd0}) >>> count;

  // -- Rotates ----------------------------------------------------------------
  // Doubling the operand turns a rotate into a shift: rotating w bits right by
  // k takes bits [k+w-1 : k] of the doubled value, and rotating left by k is
  // the same as rotating right by w-k.
  logic [63:0] dd;
  logic  [5:0] rk, rsh_amt;
  logic [63:0] rot;

  always_comb begin
    unique case (size)
      2'd0:    dd = {48'd0, v[7:0],  v[7:0]};
      2'd1:    dd = {32'd0, v[15:0], v[15:0]};
      default: dd = {v, v};
    endcase
    rk      = (count % w);
    rsh_amt = left ? (w - rk) : rk;
    rot     = dd >> rsh_amt;
  end

  // -- Rotate through the extend bit -----------------------------------------
  // Here the operand is w+1 bits wide, X being the extra one, so the count
  // reduces modulo w+1 and the doubled value is 2(w+1) bits.
  logic [32:0]  xext;
  logic [71:0]  xdd;
  logic  [5:0]  xk, xsh_amt;
  logic [71:0]  xrot;
  logic [32:0]  xtaken;

  // X sits immediately above the operand, at bit w -- not at bit 32. For a
  // byte operand the rotated value is nine bits, not thirty-three.
  assign xext = ({32'd0, x_in} << w) | {1'b0, v};

  always_comb begin
    xdd     = {39'd0, xext} | ({39'd0, xext} << (w + 6'd1));
    xk      = count % (w + 6'd1);
    xsh_amt = left ? ((w + 6'd1) - xk) : xk;
    xrot    = xdd >> xsh_amt;
    xtaken  = xrot[32:0];
  end

  // -- The overflow flag of an arithmetic left shift --------------------------
  // Set when the sign changed at any point during the shift, which is to say
  // when the top count+1 bits of the operand were not all equal. A mask of
  // those bits says so without a loop -- and without a loop variable, which
  // yosys turns into a latch.
  logic [31:0] vmask;
  logic [31:0] vbits;

  always_comb begin
    if (count >= w) vmask = mask;
    else            vmask = mask & ~((32'd1 << (w - count - 6'd1)) - 32'd1);
    vbits = v & vmask;
  end

  // -- Result and flags -------------------------------------------------------
  logic [31:0] res;
  logic        c, vf, xu;

  always_comb begin
    res = v;
    c   = 1'b0;
    vf  = 1'b0;
    xu  = 1'b0;

    unique case (kind)
      K_AS: begin
        if (left) begin
          res = lsh[31:0] & mask;
          c   = lsh[w];
          // The sign changed at some point unless the top count+1 bits of the
          // operand were all equal to it.
          if (count != 6'd0) begin
            vf = (vbits != 32'd0) && (vbits != vmask);
          end
        end else begin
          res = rsh_a[63:32] & mask;
          c   = rsh_a[31];
        end
        xu = (count != 6'd0);
      end

      K_LS: begin
        if (left) begin
          res = lsh[31:0] & mask;
          c   = lsh[w];
        end else begin
          res = rsh_l[63:32] & mask;
          c   = rsh_l[31];
        end
        xu = (count != 6'd0);
      end

      K_RO: begin
        res = rot[31:0] & mask;
        if (count == 6'd0) begin
          res = v;
          c   = 1'b0;
        end else begin
          // The last bit out of a left rotate is the one that wrapped into
          // bit 0; of a right rotate, the one that wrapped into the top.
          c = left ? res[0] : res[topbit];
        end
      end

      K_ROX: begin
        res = xtaken[31:0] & mask;
        if (count == 6'd0) begin
          res = v;
          c   = x_in;          // C takes X, and X itself is left alone
        end else begin
          c  = xtaken[w];
          xu = 1'b1;
        end
      end

      default: begin
        res = v;
      end
    endcase
  end

  // The wide intermediates exist for the one bit each contributes: the plain
  // shifts read the bit that fell off the end of the operand, and the rotates
  // read only the word the doubled value was reduced to.
  logic unused;
  assign unused = &{1'b1, rsh_l[30:0], rsh_a[30:0], rot[63:32], xrot[71:33]};

  assign dout  = res;
  assign c_out = c;
  assign v_out = vf;
  assign x_upd = xu;

endmodule
