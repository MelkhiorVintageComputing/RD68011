// RD68011 - SystemVerilog MC68010
//
// Top level. Pin list per doc/pinout.md: every three-state or bidirectional pin
// of the original is split into _i / _o / _oe, with _oe active high meaning the
// core drives.
//
// Skeleton: the E ring counter is live; everything else is held inactive until
// the bus interface lands in P1.
//
// Note the fully-scoped rd68011_pkg:: references and the plain-vector ports:
// yosys 0.52 supports neither `import pkg::*` nor user types on ports.
// See doc/coding-standard.md.

module rd68011_top (
    // Clock and hardware reset -----------------------------------------------
    input  logic        clk,      // free-running, both edges used (UM 3.9)
    input  logic        rst_n,    // not an MC68010 pin: async init, see doc/pinout.md

    // Address bus (UM 3.1) ---------------------------------------------------
    output logic [23:1] a_o,
    output logic        a_oe,

    // Data bus (UM 3.2) ------------------------------------------------------
    input  logic [15:0] d_i,
    output logic [15:0] d_o,
    output logic        d_oe,

    // Asynchronous bus control (UM 3.3) --------------------------------------
    output logic        as_n_o,
    output logic        as_oe,
    output logic        rw_o,      // high = read, low = write
    output logic        rw_oe,
    output logic        uds_n_o,
    output logic        lds_n_o,
    output logic        ds_oe,
    input  logic        dtack_n_i,

    // Bus arbitration (UM 3.4) -----------------------------------------------
    input  logic        br_n_i,
    output logic        bg_n_o,    // never three-stated
    input  logic        bgack_n_i,

    // Interrupt control (UM 3.5) ---------------------------------------------
    input  logic  [2:0] ipl_n_i,

    // System control (UM 3.6) ------------------------------------------------
    input  logic        berr_n_i,
    input  logic        reset_n_i,
    output logic        reset_n_o,  // open drain: constant 0
    output logic        reset_n_oe,
    input  logic        halt_n_i,
    output logic        halt_n_o,   // open drain: constant 0
    output logic        halt_n_oe,

    // M6800 peripheral control (UM 3.7) --------------------------------------
    output logic        e_o,        // never three-stated
    input  logic        vpa_n_i,
    output logic        vma_n_o,
    output logic        vma_oe,

    // Processor status (UM 3.8) ----------------------------------------------
    output logic  [2:0] fc_o,
    output logic        fc_oe
);

  // ---------------------------------------------------------------------------
  // M6800 enable clock (UM 3.7, figure 10-6).
  //
  // Ten clock periods: six low then four high, free-running and unrelated to
  // the bus cycle. Specification 41 measures the transition from clock LOW, so
  // the counter and the output both live in the negative-edge domain.
  //
  // The real part's ring counter "may come up in any state"; ours starts from a
  // defined reset state, which is a divergence recorded in doc/divergences.md.
  // ---------------------------------------------------------------------------
  logic [3:0] e_cnt;

  always_ff @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
      e_cnt <= 4'd0;
      e_o   <= 1'b0;
    end else begin
      if (e_cnt == rd68011_pkg::E_PERIOD_CLKS - 4'd1) begin
        e_cnt <= 4'd0;
      end else begin
        e_cnt <= e_cnt + 4'd1;
      end
      // Next state's level: low for the first six clocks, high for the last four.
      e_o <= (e_cnt >= rd68011_pkg::E_LOW_CLKS - 4'd1) &&
             (e_cnt != rd68011_pkg::E_PERIOD_CLKS - 4'd1);
    end
  end

  // ---------------------------------------------------------------------------
  // Everything else: inactive. Replaced by the bus interface in P1.
  // ---------------------------------------------------------------------------
  assign a_o        = '0;
  assign a_oe       = 1'b0;
  assign d_o        = '0;
  assign d_oe       = 1'b0;
  assign as_n_o     = 1'b1;
  assign as_oe      = 1'b0;
  assign rw_o       = 1'b1;
  assign rw_oe      = 1'b0;
  assign uds_n_o    = 1'b1;
  assign lds_n_o    = 1'b1;
  assign ds_oe      = 1'b0;
  assign bg_n_o     = 1'b1;
  assign reset_n_o  = 1'b0;   // open drain, only ever pulls low
  assign reset_n_oe = 1'b0;
  assign halt_n_o   = 1'b0;   // open drain, only ever pulls low
  assign halt_n_oe  = 1'b0;
  assign vma_n_o    = 1'b1;
  assign vma_oe     = 1'b0;
  assign fc_o       = rd68011_pkg::FC_SUPER_P;
  assign fc_oe      = 1'b0;

  // Inputs not consumed yet. Kept visible so the list shrinks as the design
  // fills in, rather than being silenced wholesale.
  logic unused_inputs;
  assign unused_inputs = &{1'b1, d_i, dtack_n_i, br_n_i, bgack_n_i, ipl_n_i,
                           berr_n_i, reset_n_i, halt_n_i, vpa_n_i};

endmodule
