// RD68011 - the multiplier for MULU and MULS.
//
// Sixteen bits by sixteen to thirty-two, in one clock rather than in the thirty
// or so the original takes.
//
// WHY IT IS NOT IN THE ALU
//
// It was, and that cost the whole design about ten nanoseconds of clock period.
// The ALU's result feeds the zero flag, the zero flag feeds the micro-address
// of a conditional microword, the micro-address feeds the microcode store, and
// the store's output has to reach the bus request pins on the edge that ends
// the current cycle -- all inside half a clock, because read data arrives on a
// falling edge and the request is latched on a rising one. Putting a
// multiplier in that chain puts a DSP in it, and synthesis has no way to know
// that no multiply ever takes its operands from read data.
//
// So it lives here instead, with registered operands and a registered result,
// exactly as the divider does and for the same reason. The microcode starts it
// on one microword and reads the answer on the next, which costs one clock and
// takes the DSP out of the chain entirely. scripts/rd68011.xdc has the
// measurement.
//
// There is no busy signal: the answer is ready on the next edge, always.

module rd68011_mul (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        start,
    input  logic        is_signed,
    input  logic [15:0] a,
    input  logic [15:0] b,

    output logic [31:0] result
);

  logic [31:0] prod_u;
  logic [31:0] prod_s;

  assign prod_u = {16'd0, b} * {16'd0, a};
  assign prod_s = $signed(b) * $signed(a);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      result <= 32'd0;
    end else if (start) begin
      result <= is_signed ? prod_s : prod_u;
    end
  end

endmodule
