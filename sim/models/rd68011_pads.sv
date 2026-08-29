// Output pads with settable delays, between a processor and the bus.
//
// WHY THIS EXISTS
//
// The RTL is delay-free: an output changes exactly on the clock edge that
// causes it. Section 10's clock-to-output limits -- specification 6's "Clock
// Low to Address Valid <= 50 ns" and its nine siblings -- are therefore not
// properties of the RTL at all, which invites the conclusion that they cannot
// be simulated: an invented delay that passes proves nothing.
//
// That is true of one invented delay and false of the set of them. Those limits
// are a *budget*: they say what a real implementation is allowed to spend
// between an edge and a pin. What the design fixes is not how much is spent but
// the order the events happen in, and the output-to-output limits -- 11, 11A,
// 13, 14, 15, 17, 20A, 21, 21A, 22, 25, 26, 55 -- then constrain that order
// given any spending within the budget. Whether a legal assignment exists is a
// question with an exact answer; tools/timing/feasible.py computes it.
//
// This module is the other half: it puts a chosen assignment into a simulation,
// so that a prediction made by the solver can be checked by a simulator that
// knows nothing about it. Agreement between the two is worth more than either.
//
// Delays are `parameter real` in nanoseconds, overridable at elaboration
// (iverilog -P, xelab -generic_top) so a corner can be selected without editing
// anything. tools/timing/corners.py emits the command line for a named corner.
//
// GLITCHES
//
// A continuous assign's delay is inertial, which is what filters the delta-cycle
// glitches an event-driven model produces and is why observation happens on this
// side of the pad rather than at the core's pin. Inertial delay will also
// swallow a *legitimate* pulse shorter than the delay, which at these numbers is
// not impossible -- specification 15 allows AS to be negated for as little as
// 50 ns at 20 MHz, and specification 6 allows a 62 ns address delay at 8 MHz. So
// every scalar is watched, and a cancelled transition is reported rather than
// quietly lost. The analyser fails on any GLITCH line.

`timescale 1ns/1ps

module rd68011_pads #(
    // Address and function code.
    parameter real P_A_VALID    = 0.001,
    parameter real P_A_HIZ      = 0.001,
    parameter real P_FC_VALID   = 0.001,
    // Strobes.
    parameter real P_AS_ASSERT  = 0.001,
    parameter real P_AS_NEGATE  = 0.001,
    parameter real P_DS_ASSERT  = 0.001,
    parameter real P_DS_NEGATE  = 0.001,
    // Direction and write data.
    parameter real P_RW_LOW     = 0.001,
    parameter real P_RW_HIGH    = 0.001,
    parameter real P_DOUT_VALID = 0.001,
    parameter real P_DOUT_HIZ   = 0.001,
    // The rest.
    parameter real P_VMA_ASSERT = 0.001,
    parameter real P_VMA_NEGATE = 0.001,
    parameter real P_BG_ASSERT  = 0.001,
    parameter real P_BG_NEGATE  = 0.001,
    parameter real P_E          = 0.001,
    // Report cancelled transitions. On by default; the analyser wants them.
    parameter bit  GLITCH_WATCH = 1'b1
) (
    // From the processor, delay-free.
    input  logic [23:1] a_o,
    input  logic        a_oe,
    input  logic [15:0] d_o,
    input  logic        d_oe,
    input  logic        as_n_o,
    input  logic        as_oe,
    input  logic        rw_o,
    input  logic        rw_oe,
    input  logic        uds_n_o,
    input  logic        lds_n_o,
    input  logic        ds_oe,
    input  logic        vma_n_o,
    input  logic        vma_oe,
    input  logic  [2:0] fc_o,
    input  logic        fc_oe,
    input  logic        bg_n_o,
    input  logic        e_o,

    // The bus, as a slave sees it.
    inout  wire  [23:1] a_pad,
    inout  wire  [15:0] d_pad,
    inout  wire         as_n_pad,
    inout  wire         rw_pad,
    inout  wire         uds_n_pad,
    inout  wire         lds_n_pad,
    inout  wire         vma_n_pad,
    inout  wire   [2:0] fc_pad,
    output wire         bg_n_pad,
    output wire         e_pad
);

  // Three-delay form: rise, fall, turn-off. An active-low strobe falls when it
  // asserts, so the fall delay is the assertion delay and the rise delay the
  // negation one -- which is why the two are separate parameters rather than
  // one per pin. Specification 9 and specification 12 are different numbers.
  assign #(P_A_VALID, P_A_VALID, P_A_HIZ)          a_pad     = a_oe   ? a_o     : 23'bz;
  assign #(P_DOUT_VALID, P_DOUT_VALID, P_DOUT_HIZ) d_pad     = d_oe   ? d_o     : 16'bz;
  assign #(P_AS_NEGATE, P_AS_ASSERT, P_A_HIZ)      as_n_pad  = as_oe  ? as_n_o  : 1'bz;
  assign #(P_RW_HIGH, P_RW_LOW, P_A_HIZ)           rw_pad    = rw_oe  ? rw_o    : 1'bz;
  assign #(P_DS_NEGATE, P_DS_ASSERT, P_A_HIZ)      uds_n_pad = ds_oe  ? uds_n_o : 1'bz;
  assign #(P_DS_NEGATE, P_DS_ASSERT, P_A_HIZ)      lds_n_pad = ds_oe  ? lds_n_o : 1'bz;
  assign #(P_VMA_NEGATE, P_VMA_ASSERT, P_A_HIZ)    vma_n_pad = vma_oe ? vma_n_o : 1'bz;
  assign #(P_FC_VALID, P_FC_VALID, P_A_HIZ)        fc_pad    = fc_oe  ? fc_o    : 3'bz;

  // Never three-stated (doc/pinout.md), so no turn-off delay.
  assign #(P_BG_NEGATE, P_BG_ASSERT) bg_n_pad = bg_n_o;
  assign #(P_E, P_E)                 e_pad    = e_o;

  // -- Cancelled transitions --------------------------------------------------
  //
  // A pulse narrower than the delay it passes through does not come out the
  // other side. Watching for it is a matter of noticing two transitions closer
  // together than the wider of the pin's two delays.
  real t_as, t_uds, t_lds, t_rw, t_vma;
  int  glitches;

  function automatic real wider(input real x, input real y);
    wider = (x > y) ? x : y;
  endfunction

  task automatic watch(input string name, inout real last, input real d);
    real now;
    begin
      now = $realtime;
      if (GLITCH_WATCH && last >= 0.0 && (now - last) < d) begin
        glitches = glitches + 1;
        $display("GLITCH %0.3f %s width %0.3f < delay %0.3f",
                 now, name, now - last, d);
      end
      last = now;
    end
  endtask

  initial begin
    glitches = 0;
    t_as = -1.0; t_uds = -1.0; t_lds = -1.0; t_rw = -1.0; t_vma = -1.0;
  end

  always @(as_n_o)  watch("AS",  t_as,  wider(P_AS_ASSERT, P_AS_NEGATE));
  always @(uds_n_o) watch("UDS", t_uds, wider(P_DS_ASSERT, P_DS_NEGATE));
  always @(lds_n_o) watch("LDS", t_lds, wider(P_DS_ASSERT, P_DS_NEGATE));
  always @(rw_o)    watch("RW",  t_rw,  wider(P_RW_LOW,    P_RW_HIGH));
  always @(vma_n_o) watch("VMA", t_vma, wider(P_VMA_ASSERT, P_VMA_NEGATE));

endmodule
