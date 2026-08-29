# RD68011 timing constraints.
#
# CLK_PERIOD_NS is the target, not the original part's 125 ns (8 MHz). An FPGA
# build is expected to run the core faster than the original; the number here
# is what `make synth` reports slack against.
#
# 48 ns -- 20.8 MHz, against the fastest original MC68010's 12.5 -- is the
# number every published figure is measured against, and it is kept there so
# they stay comparable. It is not the limit: the design closes at 40 ns, and
# doc/size-and-speed.md has the search.
#
# What limits it is measured rather than read off `make impl`, because static
# timing analysis can find worst paths the microcode cannot take. `make paths`
# does the measuring and doc/critical-path.md has the result. No such path is
# left: the bus request is selected on MOVEM's mask test alone, so the ALU is
# not in its fan-in at all, and the exclusion `make paths` applies finds nothing
# to cut.
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
# Do not make it conditional on the environment. `read_xdc` accepts an `if`
# around this line without complaint and then creates no clock at all, so the
# design places and routes unconstrained and fails only at the very end, when
# impl.tcl asks a clock that does not exist for its slack.
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
