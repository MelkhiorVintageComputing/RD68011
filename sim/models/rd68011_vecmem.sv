// Sparse memory for the reference-vector testbench.
//
// The vectors place their operands at random 24-bit addresses, so a flat
// memory would be 8M words. Each test touches a handful, so this is a small
// fully-associative table with a linear lookup: correct, no aliasing, and it
// fails loudly rather than quietly if a test needs more room than it has.
//
// Bus behaviour is the same as rd68011_slave: DTACK on the rising edge, keyed
// off AS, no wait states.

`timescale 1ns/1ps

module rd68011_vecmem #(
    parameter int ENTRIES = 128
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [23:1] a,
    input  logic        as_n,
    input  logic        uds_n,
    input  logic        lds_n,
    input  logic        rw,

    input  logic [15:0] d_in,
    output logic [15:0] d_out,
    output logic        d_oe,

    output logic        dtack_n,
    output logic        overflow      // a test needed more entries than exist
);

  logic [22:0] tag  [0:ENTRIES-1];
  logic [15:0] val  [0:ENTRIES-1];
  logic        used [0:ENTRIES-1];
  int          n;

  logic        selected;
  logic        answered;
  int          hit;
  int          i;

  assign selected = !as_n;

  // Linear lookup. `hit` is the entry index, or -1.
  always_comb begin
    hit = -1;
    for (i = 0; i < ENTRIES; i = i + 1) begin
      if (used[i] && (tag[i] == a)) hit = i;
    end
  end

  always_comb begin
    d_oe  = selected && rw;
    d_out = (hit >= 0) ? val[hit] : 16'h0000;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dtack_n  <= 1'b1;
      answered <= 1'b0;
    end else if (!selected) begin
      dtack_n  <= 1'b1;
      answered <= 1'b0;
    end else if (!answered) begin
      answered <= 1'b1;
      dtack_n  <= 1'b0;
    end
  end

  // Writes land as the data strobes negate, which is the last moment the data
  // is guaranteed valid.
  always_ff @(negedge clk) begin
    if (rst_n && selected && !rw) begin
      if (hit >= 0) begin
        if (!uds_n) val[hit][15:8] <= d_in[15:8];
        if (!lds_n) val[hit][ 7:0] <= d_in[ 7:0];
      end else if (n < ENTRIES) begin
        tag[n]  <= a;
        used[n] <= 1'b1;
        val[n]  <= {!uds_n ? d_in[15:8] : 8'h00,
                    !lds_n ? d_in[ 7:0] : 8'h00};
        n       <= n + 1;
      end else begin
        overflow <= 1'b1;
      end
    end
  end

  // Loading and inspection from the testbench.
  task automatic clear();
    int k;
    begin
      for (k = 0; k < ENTRIES; k = k + 1) begin
        used[k] = 1'b0;
        tag[k]  = '0;
        val[k]  = '0;
      end
      n        = 0;
      overflow = 1'b0;
    end
  endtask

  task automatic poke(input logic [23:1] addr, input logic [15:0] v);
    int k;
    int found;
    begin
      found = -1;
      for (k = 0; k < ENTRIES; k = k + 1) begin
        if (used[k] && (tag[k] == addr)) found = k;
      end
      if (found >= 0) begin
        val[found] = v;
      end else if (n < ENTRIES) begin
        tag[n]  = addr;
        val[n]  = v;
        used[n] = 1'b1;
        n       = n + 1;
      end else begin
        overflow = 1'b1;
      end
    end
  endtask

  function automatic logic [15:0] peek(input logic [23:1] addr);
    int k;
    begin
      peek = 16'h0000;
      for (k = 0; k < ENTRIES; k = k + 1) begin
        if (used[k] && (tag[k] == addr)) peek = val[k];
      end
    end
  endfunction

endmodule
