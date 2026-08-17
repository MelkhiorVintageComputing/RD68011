# RD68011 timing constraints.
#
# CLK_PERIOD_NS is the target, not the original part's 125 ns (8 MHz). An FPGA
# build is expected to run the core faster than the original; the number here
# is what `make synth` reports slack against.
#
# 48 ns is where the design closes on the Artix-7 part with margin -- 20.8 MHz,
# against the fastest original MC68010's 12.5. The number has moved as the
# design grew: 20 ns with a bus interface and a 17-word microcode store, 40 ns
# with MOVE, 44 ns with the whole integer set, 52 ns with control flow and
# exceptions, 68 ns with the rest of the instruction set, then 60 ns, and 48
# once what was really limiting it had been measured. 46 ns also closes, at
# 0.277 ns, which is inside the run-to-run variation.
#
# What limits it is measured rather than read off `make impl`, because for most
# of this design's life the worst path static timing analysis could find was one
# the microcode could not take. `make paths` does the measuring and
# doc/critical-path.md has the result. That path is now gone -- not excluded,
# gone: the bus request is selected on MOVEM's mask test alone, so the ALU is
# not in its fan-in at all, and the exclusion `make paths` applies finds nothing
# left to cut.
#
# Both edges of clk are used (one bus state per half period), so a single
# create_clock covers the design and Vivado times the negative-edge paths
# against the half period automatically. Keep the duty cycle at exactly 50 %:
# UM 3.9 requires a square wave, and the half period is a real timing budget
# here, not a convention.

# To find where the design actually closes rather than extrapolating from slack
# -- which for this design would be wrong anyway, since the critical paths run
# from one edge to the next and their budget is half the period, so both halves
# shrink together -- edit this and re-run `make impl`.
#
# Do not make it conditional on the environment. That was tried: `read_xdc`
# accepted an `if` around this line without complaint and then created no clock
# at all, so the design placed and routed unconstrained and only failed at the
# very end, when impl.tcl asked a clock that did not exist for its slack.
set clk_period_ns 48.000

create_clock -period $clk_period_ns -name clk -waveform "0.000 [expr {$clk_period_ns / 2.0}]" [get_ports clk]

# rst_n is an asynchronous initialisation input, not a functional MC68010 pin.
set_false_path -from [get_ports rst_n]

# The write data has three half clocks, not one.
#
# `d_o` is loaded on the falling edge entering S3 (UM 5.1.2, specification 23,
# "Clock Low to Data-Out Valid"). The microword that supplies the data became
# current on the rising edge that started S0, and the states in between alternate
# edges unconditionally -- S0 to S1 falling, S1 to S2 rising, S2 to S3 falling,
# see st_p_nxt and st_n_nxt in rd68011_biu.sv. Nothing in the sequencer moves in
# between, because `retire` waits for the bus unit to reach the last state of the
# cycle, which is S6 at the earliest.
#
# So the data is stable a full clock before analysis assumes it has to be. A
# rising-edge launch and a falling-edge capture are half a period apart, and
# moving the capture edge one period later is exactly the three half clocks the
# state machine gives it.
#
# This is the one exception here whose failure mode is silent, so it is measured
# as well as argued: rd68011_core_harness.svh records how long the captured value
# had already been stable at every load, across every core testbench, the five
# programs and the reference vectors, and fails if it is ever less than three
# half clocks. `make sim` prints the number.
#
# Only the data. The enable is `ENTER_N(ST_S3) && cyc_is_write`, which is decided
# by bus states that change every half clock, and it is not excluded here.
set_multicycle_path 2 -setup -to [get_pins u_biu/d_o_reg[*]/D]
set_multicycle_path 1 -hold  -to [get_pins u_biu/d_o_reg[*]/D]

# Every other pin is asynchronous to clk from the core's point of view: the
# MC68010 samples DTACK/BERR/VPA/BR/BGACK/IPL/RESET/HALT with its own
# synchronisers (specification 47, "Asynchronous Input Setup Time"). Board-level
# input and output delays belong in the wrapper's constraints, not here.
