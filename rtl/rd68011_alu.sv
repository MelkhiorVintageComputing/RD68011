// RD68011 - arithmetic and logic unit.
//
// P2 skeleton: the operations the reset sequence and the branches need. The
// condition codes, the BCD and shift paths and the multiply/divide sequencer
// arrive with the instructions that use them.
//
// The operation encodings come from rd68011_ucode_pkg, which is generated from
// tools/ucode/isa.py, so adding an operation means adding it there.

module rd68011_alu (
    input  logic [rd68011_ucode_pkg::U_ALU_W-1:0] op,
    input  logic                           [31:0] a,
    input  logic                           [31:0] b,
    output logic                           [31:0] y
);

  always_comb begin
    unique case (op)
      rd68011_ucode_pkg::U_ALU_A:   y = a;
      rd68011_ucode_pkg::U_ALU_B:   y = b;
      rd68011_ucode_pkg::U_ALU_ADD: y = a + b;
      rd68011_ucode_pkg::U_ALU_SUB: y = a - b;
      default:                      y = a;
    endcase
  end

endmodule
