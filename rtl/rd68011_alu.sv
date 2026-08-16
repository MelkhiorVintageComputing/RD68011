// RD68011 - arithmetic and logic unit, with the condition codes.
//
// The operation and flag-rule encodings come from rd68011_ucode_pkg, which is
// generated from tools/ucode/isa.py, so adding an operation means adding it
// there and regenerating.
//
// SIZE
//
// The 68000 is a 32-bit machine with byte, word and long operations, and the
// condition codes are taken from the operated-on width, not from the full 32
// bits: a byte operation's N flag is bit 7 and its Z flag covers bits 7-0
// (PRM section 3). The result written back is likewise only as wide as the
// operation -- the upper bits of a data register survive a byte MOVE -- which
// is handled by the destination merge, not here.
//
// V AND C
//
// PRM's definitions, per operation:
//   ADD  V = Sm.Dm.!Rm + !Sm.!Dm.Rm      C = Sm.Dm + !Rm.Dm + Sm.!Rm
//   SUB  V = !Sm.Dm.!Rm + Sm.!Dm.Rm      C = Sm.!Dm + Rm.!Dm + Sm.Rm
// where S is the source, D the destination and R the result, m the most
// significant bit of the operation's size. CMP uses SUB's rules. The logical
// operations clear both.

module rd68011_alu (
    input  logic [rd68011_ucode_pkg::U_ALU_W-1:0]  op,
    input  logic [rd68011_ucode_pkg::U_SIZE_W-1:0] size,
    input  logic                            [31:0] a,      // source
    input  logic                            [31:0] b,      // destination
    input  logic                                   x_in,   // the X flag
    output logic                            [31:0] y,
    output logic                                   n_out,
    output logic                                   z_out,
    output logic                                   v_out,
    output logic                                   c_out
);

  logic [32:0] sum;
  logic [32:0] dif;
  logic        is_byte, is_word;
  logic        sm, dm, rm;          // sign bits at the operation's width
  logic        carry;

  assign is_byte = (size == rd68011_ucode_pkg::U_SIZE_BYTE);
  assign is_word = (size == rd68011_ucode_pkg::U_SIZE_WORD);

  // The adders are always 32 bits wide; the flags are taken at the width the
  // operation actually used.
  assign sum = {1'b0, b} + {1'b0, a};
  assign dif = {1'b0, b} - {1'b0, a};

  // The extended forms carry X in and out, for multi-precision arithmetic.
  logic [32:0] sumx, difx;
  assign sumx = {1'b0, b} + {1'b0, a} + {32'd0, x_in};
  assign difx = {1'b0, b} - {1'b0, a} - {32'd0, x_in};

  always_comb begin
    unique case (op)
      rd68011_ucode_pkg::U_ALU_A:   y = a;
      rd68011_ucode_pkg::U_ALU_B:   y = b;
      rd68011_ucode_pkg::U_ALU_ADD: y = sum[31:0];
      rd68011_ucode_pkg::U_ALU_SUB: y = dif[31:0];
      rd68011_ucode_pkg::U_ALU_AND: y = a & b;
      rd68011_ucode_pkg::U_ALU_OR:  y = a | b;
      rd68011_ucode_pkg::U_ALU_EOR: y = a ^ b;
      rd68011_ucode_pkg::U_ALU_NOT: y = ~a;
      rd68011_ucode_pkg::U_ALU_CAT:  y = {a[15:0], b[15:0]};
      rd68011_ucode_pkg::U_ALU_SXW:  y = {{16{a[15]}}, a[15:0]};
      rd68011_ucode_pkg::U_ALU_SXB:  y = {{24{a[7]}},  a[7:0]};
      rd68011_ucode_pkg::U_ALU_SWAP: y = {a[15:0], a[31:16]};
      rd68011_ucode_pkg::U_ALU_NOTX: y = ~b;
      rd68011_ucode_pkg::U_ALU_ANDN: y = b & ~a;
      rd68011_ucode_pkg::U_ALU_ADDX: y = sumx[31:0];
      rd68011_ucode_pkg::U_ALU_SUBX: y = difx[31:0];
      default:                      y = a;
    endcase
  end

  // Sign bits, and the carry out, at the operation's width. The carry is the
  // bit that falls off the top of the operation, which for a subtraction is
  // the borrow -- so both come out of one extra bit above the width, not out
  // of a comparison.
  logic  [8:0] sum_b, dif_b, sumx_b, difx_b;
  logic [16:0] sum_w, dif_w, sumx_w, difx_w;
  logic        xb;

  assign xb     = x_in;
  assign sum_b  = {1'b0, b[7:0]}  + {1'b0, a[7:0]};
  assign dif_b  = {1'b0, b[7:0]}  - {1'b0, a[7:0]};
  assign sumx_b = {1'b0, b[7:0]}  + {1'b0, a[7:0]}  + {8'd0, xb};
  assign difx_b = {1'b0, b[7:0]}  - {1'b0, a[7:0]}  - {8'd0, xb};
  assign sum_w  = {1'b0, b[15:0]} + {1'b0, a[15:0]};
  assign dif_w  = {1'b0, b[15:0]} - {1'b0, a[15:0]};
  assign sumx_w = {1'b0, b[15:0]} + {1'b0, a[15:0]} + {16'd0, xb};
  assign difx_w = {1'b0, b[15:0]} - {1'b0, a[15:0]} - {16'd0, xb};

  always_comb begin
    if (is_byte) begin
      sm    = a[7];
      dm    = b[7];
      rm    = y[7];
      unique case (op)
        rd68011_ucode_pkg::U_ALU_SUB:  carry = dif_b[8];
        rd68011_ucode_pkg::U_ALU_ADDX: carry = sumx_b[8];
        rd68011_ucode_pkg::U_ALU_SUBX: carry = difx_b[8];
        default:                       carry = sum_b[8];
      endcase
    end else if (is_word) begin
      sm    = a[15];
      dm    = b[15];
      rm    = y[15];
      unique case (op)
        rd68011_ucode_pkg::U_ALU_SUB:  carry = dif_w[16];
        rd68011_ucode_pkg::U_ALU_ADDX: carry = sumx_w[16];
        rd68011_ucode_pkg::U_ALU_SUBX: carry = difx_w[16];
        default:                       carry = sum_w[16];
      endcase
    end else begin
      sm    = a[31];
      dm    = b[31];
      rm    = y[31];
      unique case (op)
        rd68011_ucode_pkg::U_ALU_SUB:  carry = dif[32];
        rd68011_ucode_pkg::U_ALU_ADDX: carry = sumx[32];
        rd68011_ucode_pkg::U_ALU_SUBX: carry = difx[32];
        default:                       carry = sum[32];
      endcase
    end
  end

  assign n_out = rm;

  always_comb begin
    if (is_byte)      z_out = (y[7:0]  == 8'd0);
    else if (is_word) z_out = (y[15:0] == 16'd0);
    else              z_out = (y       == 32'd0);
  end

  always_comb begin
    unique case (op)
      rd68011_ucode_pkg::U_ALU_ADD,
      rd68011_ucode_pkg::U_ALU_ADDX: begin
        v_out = (sm && dm && !rm) || (!sm && !dm && rm);
        c_out = carry;
      end
      rd68011_ucode_pkg::U_ALU_SUBX,
      rd68011_ucode_pkg::U_ALU_SUB: begin
        v_out = (!sm && dm && !rm) || (sm && !dm && rm);
        c_out = carry;
      end
      default: begin
        // The logical operations and the plain moves clear both (PRM
        // section 4, under each instruction's condition codes).
        v_out = 1'b0;
        c_out = 1'b0;
      end
    endcase
  end

  // X takes its value from C where an operation sets it at all; which
  // operations those are is the microcode's decision, through the flag rule.
  // The low bits of the narrow adders are not used: the result comes from the
  // 32-bit adders, and these exist only for the bit that falls off the top.
  // X takes its value from C where an operation sets it at all; which
  // operations those are is the microcode's decision, through the flag rule.
  logic unused;
  assign unused = &{1'b1, sum_b[7:0], dif_b[7:0], sum_w[15:0], dif_w[15:0],
                    sumx_b[7:0], difx_b[7:0], sumx_w[15:0], difx_w[15:0]};

endmodule
