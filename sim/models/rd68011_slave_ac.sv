// A bus slave whose answers are timed in nanoseconds, not in clock edges.
//
// WHY THIS EXISTS
//
// sim/models/rd68011_slave.sv answers on the rising edge of the processor
// clock, which is what UM 5.6 tells a system designer to do and is the right
// default for every other testbench here. It cannot ask the question this one
// is for.
//
// Section 10's input limits -- 27 (data setup), 28 (DTACK hold), 29 (data
// hold), 31 (DTACK to data), 47 (asynchronous input setup) -- are demands on
// the *system*, in nanoseconds, and a slave that only ever moves on clock edges
// can never present an input at the limit of one. So nothing in this project
// has ever established where its own sampling instants actually are; the
// existing tests establish only which edge the state machine acts on, which is
// a different fact and a weaker one.
//
// This model presents every input at a settable time relative to the strobes,
// so that the processor's real requirement can be measured by bisection and
// compared against what the specification allows. Because the measurement is in
// nanoseconds it also applies unchanged to a processor with a different state
// machine -- which is what lets the Suska core be measured on the same scale.
//
// HOW THE KNOBS ARE SET
//
// As `real` variables, assigned hierarchically by the testbench:
//
//     u_slave.dtack_assert_ns = 42.0;
//
// rather than as ports, because a real-valued port is the sort of thing the
// four simulators disagree about and there is no need to find out.
//
// WHY THERE IS NO CLOCK-ALIGNED MODE
//
// An earlier shape of this model carried a `mode` input that reproduced
// rd68011_slave exactly, as its own regression. That would have meant a second
// copy of the wait-state machine living beside the first. The regression it was
// there for is done better from outside: run one program through this slave and
// through rd68011_slave and require the two transaction lists to be identical.
// That checks the whole model against the one already trusted, rather than
// checking one branch of it against another branch of itself.

`timescale 1ns/1ps

module rd68011_slave_ac #(
    parameter int   ADDR_BITS   = 12,
    parameter logic [23:1] BASE = 23'h000000,
    parameter logic [23:1] MASK = 23'h7FF000
) (
    input  logic [23:1] a,
    input  logic        as_n,
    input  logic        uds_n,
    input  logic        lds_n,
    input  logic        rw,
    input  logic  [2:0] fc,

    input  logic [15:0] d_in,
    output logic [15:0] d_out,
    output logic        d_oe,

    output logic        dtack_n,
    output logic        vpa_n,
    output logic        berr_n
);

  logic [15:0] mem [0:(1<<ADDR_BITS)-1];

  // -- The knobs. Every one is nanoseconds from the event named; a negative
  //    value means "never", so a test turns a behaviour off by disabling it
  //    rather than by choosing a time so large it looks like a hang.
  real dtack_assert_ns;   // from AS asserted
  real dtack_negate_ns;   // from AS negated
  real data_valid_ns;     // from AS asserted   (specifications 27, 31)
  real data_invalid_ns;   // from AS negated    (specification 29)
  real data_hiz_ns;       // from AS negated    (specification 29A)
  real vpa_assert_ns;     // from AS asserted, instead of DTACK
  real berr_assert_ns;    // from AS asserted
  real berr_after_ns;     // from DTACK asserted (specifications 48*, 27A)
  real berr_negate_ns;    // from AS negated    (specification 30)

  // The number of the cycle in progress. Every scheduled action re-reads it
  // before acting, so an answer meant for a cycle that has already ended is
  // dropped instead of corrupting the next one.
  int  epoch;
  logic selected;

  assign selected = !as_n && ((a & MASK) == (BASE & MASK));

  initial begin
    dtack_assert_ns =  20.0;
    dtack_negate_ns =   0.0;
    data_valid_ns   =  30.0;
    data_invalid_ns =   0.0;
    data_hiz_ns     =  10.0;
    vpa_assert_ns   =  -1.0;
    berr_assert_ns  =  -1.0;
    berr_after_ns   =  -1.0;
    berr_negate_ns  =   0.0;
    epoch           =   0;
    dtack_n         = 1'b1;
    vpa_n           = 1'b1;
    berr_n          = 1'b1;
    d_oe            = 1'b0;
    d_out           = 16'd0;
  end

  // ONE BLOCK OWNS EACH EDGE.
  //
  // Every scheduled answer has to know which cycle it belongs to, so that one
  // meant for a cycle already over is dropped rather than landing on the next.
  // The obvious arrangement -- a block that advances `epoch` and separate
  // blocks that read it -- does not work: those blocks are sensitive to the
  // same edge, and the order two always blocks run in at the same instant is
  // undefined. Half the time the readers see the new epoch and half the time
  // the old one, and a slave that answers only half the time stalls the
  // processor on its first cycle. (It did.)
  //
  // So each edge has exactly one block. It advances the epoch with a blocking
  // assignment, takes its own copy, and forks the timed answers off; every fork
  // compares against the copy it was given. The offsets are all sub-cycle by
  // construction, being section 10 timings, so the forks are always finished
  // long before the edge comes round again.

  always @(negedge as_n) begin : cycle_start
    int my;
    if ((a & MASK) == (BASE & MASK)) begin
      epoch = epoch + 1;
      my    = epoch;

      // Read data: specifications 27 and 31 measure from here.
      if (rw) fork
        begin
          if (data_valid_ns > 0.0) #(data_valid_ns);
          if (epoch == my) begin
            d_out = mem[a[ADDR_BITS:1]];
            d_oe  = 1'b1;
          end
        end
      join_none

      // DTACK, or VPA for an M6800 region.
      fork
        begin
          if (vpa_assert_ns >= 0.0) begin
            #(vpa_assert_ns);
            if (epoch == my) vpa_n = 1'b0;
          end else if (dtack_assert_ns >= 0.0) begin
            #(dtack_assert_ns);
            if (epoch == my) begin
              dtack_n = 1'b0;
              // The MC68010's late bus error: specification 48* measures from
              // DTACK asserted to BERR asserted, and it is the only line in
              // the whole table that names this part alone (UM 5.4.1).
              if (berr_after_ns >= 0.0) begin
                #(berr_after_ns);
                if (epoch == my) berr_n = 1'b0;
              end
            end
          end
        end
      join_none

      // A bus error keyed to the address rather than to DTACK.
      if (berr_assert_ns >= 0.0) fork
        begin
          #(berr_assert_ns);
          if (epoch == my) berr_n = 1'b0;
        end
      join_none
    end
  end

  always @(posedge as_n) begin : cycle_end
    int my;
    my = epoch;

    // Writes are taken as the strobes negate, which is the last instant the
    // processor guarantees the data: specification 25 puts the earliest
    // removal after this edge, not before it.
    if (!rw && ((a & MASK) == (BASE & MASK))) begin
      if (uds_n === 1'b0) mem[a[ADDR_BITS:1]][15:8] = d_in[15:8];
      if (lds_n === 1'b0) mem[a[ADDR_BITS:1]][ 7:0] = d_in[ 7:0];
    end

    // Read data comes off: specification 29 is the hold, 29A the turn-off.
    fork
      begin
        if (data_invalid_ns > 0.0) #(data_invalid_ns);
        if (epoch == my) d_out = 16'hxxxx;
        if (data_hiz_ns > data_invalid_ns) #(data_hiz_ns - data_invalid_ns);
        if (epoch == my) d_oe = 1'b0;
      end
    join_none

    fork
      begin
        if (dtack_negate_ns > 0.0) #(dtack_negate_ns);
        if (epoch == my) begin
          dtack_n = 1'b1;
          vpa_n   = 1'b1;
        end
      end
    join_none

    fork
      begin
        if (berr_negate_ns > 0.0) #(berr_negate_ns);
        if (epoch == my) berr_n = 1'b1;
      end
    join_none
  end

  // -- Loading and inspection, the same API rd68011_slave offers --------------
  function automatic void poke(input logic [23:1] addr, input logic [15:0] val);
    mem[addr[ADDR_BITS:1]] = val;
  endfunction

  function automatic logic [15:0] peek(input logic [23:1] addr);
    peek = mem[addr[ADDR_BITS:1]];
  endfunction

  task automatic clear();
    for (int unsigned k = 0; k < (1 << ADDR_BITS); k = k + 1) mem[k] = 16'd0;
  endtask

  logic unused;
  assign unused = &{1'b1, fc};

endmodule
