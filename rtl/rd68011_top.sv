// RD68011 - SystemVerilog MC68010
//
// Top level. Pin list per doc/pinout.md: every three-state or bidirectional pin
// of the original is split into _i / _o / _oe, with _oe active high meaning the
// core drives.
//
// P2: the bus interface unit and the micro-sequencer are both here and wired
// together. The core runs its reset sequence out of the vector table and then
// executes whatever the microcode covers -- which is not yet much.
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

  // Bus unit to sequencer.
  logic        req_valid;
  logic  [2:0] req_kind;
  logic  [2:0] req_fc;
  logic [23:1] req_addr;
  logic        req_uds;
  logic        req_lds;
  logic [15:0] req_wdata;
  logic        req_ack;
  logic        req_last;
  logic [15:0] req_rdata;
  logic  [2:0] req_end;
  logic        reset_req;
  logic        reset_busy;
  logic  [2:0] ipl_sync_n;
  logic        reset_sync_n;
  logic        halt_sync_n;
  logic        bus_idle;
  logic        dbf;

  rd68011_seq u_seq (
      .clk          (clk),
      .rst_n        (rst_n),
      .req_valid    (req_valid),
      .req_kind     (req_kind),
      .req_fc       (req_fc),
      .req_addr     (req_addr),
      .req_uds      (req_uds),
      .req_lds      (req_lds),
      .req_wdata    (req_wdata),
      .req_ack      (req_ack),
      .req_last     (req_last),
      .req_rdata    (req_rdata),
      .req_end      (req_end),
      .ipl_sync_n   (ipl_sync_n),
      .reset_sync_n (reset_sync_n),
      .halt_sync_n  (halt_sync_n),
      .bus_idle     (bus_idle),
      .reset_req    (reset_req),
      .reset_busy   (reset_busy),
      .dbf          (dbf)
  );

  rd68011_biu u_biu (
      .clk        (clk),
      .rst_n      (rst_n),

      .req_valid  (req_valid),
      .req_kind   (req_kind),
      .req_fc     (req_fc),
      .req_addr   (req_addr),
      .req_uds    (req_uds),
      .req_lds    (req_lds),
      .req_wdata  (req_wdata),
      .req_ack    (req_ack),
      .req_last   (req_last),
      .req_rdata  (req_rdata),
      .req_end    (req_end),

      .reset_req  (reset_req),
      .reset_busy (reset_busy),

      .ipl_sync_n   (ipl_sync_n),
      .reset_sync_n (reset_sync_n),
      .halt_sync_n  (halt_sync_n),
      .bus_idle     (bus_idle),
      .dbf          (dbf),

      .a_o        (a_o),        .a_oe       (a_oe),
      .d_i        (d_i),        .d_o        (d_o),        .d_oe (d_oe),
      .as_n_o     (as_n_o),     .as_oe      (as_oe),
      .rw_o       (rw_o),       .rw_oe      (rw_oe),
      .uds_n_o    (uds_n_o),    .lds_n_o    (lds_n_o),    .ds_oe (ds_oe),
      .dtack_n_i  (dtack_n_i),
      .br_n_i     (br_n_i),     .bg_n_o     (bg_n_o),     .bgack_n_i (bgack_n_i),
      .ipl_n_i    (ipl_n_i),
      .berr_n_i   (berr_n_i),
      .reset_n_i  (reset_n_i),  .reset_n_o  (reset_n_o),  .reset_n_oe (reset_n_oe),
      .halt_n_i   (halt_n_i),   .halt_n_o   (halt_n_o),   .halt_n_oe  (halt_n_oe),
      .e_o        (e_o),        .vpa_n_i    (vpa_n_i),
      .vma_n_o    (vma_n_o),    .vma_oe     (vma_oe),
      .fc_o       (fc_o),       .fc_oe      (fc_oe)
  );

  // reset_busy tells the sequencer when the RESET instruction's output pulse
  // has finished; nothing issues one until that instruction exists.
  logic unused_biu;
  assign unused_biu = 1'b1;

endmodule
