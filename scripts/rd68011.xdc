# RD68011 timing constraints.
#
# CLK_PERIOD_NS is the target, not the original part's 125 ns (8 MHz). An FPGA
# build is expected to run the core faster than the original; the number here
# is what `make synth` reports slack against.
#
# 68 ns is where the design closes today on the Artix-7 part, with 0.95 ns to
# spare and 12396 LUTs and 1148 flip-flops -- 14.7 MHz, against the fastest
# original MC68010's 12.5 MHz. The number has moved as the
# design grew: 20 ns with a bus interface and a 17-word microcode store, 40 ns
# with MOVE, 44 ns with the whole integer set, 52 ns with control flow and
# exceptions, and 68 ns with the rest of the instruction set.
#
# THE PATH, as of P5, measured (build/timing.rpt):
#
#   req_rdata (falling edge of S6)
#     -> the A and B source multiplexers
#     -> the ALU, through the DSP the multiplier maps to
#     -> the zero flag
#     -> the micro-address, because a conditional microword branches on it
#     -> the *next* microword, read out of a 6528 x 97 store
#     -> the bus request address, which must be at the pins on the rising edge
#        that ends S7
#
# 31.2 ns of it, against a budget of half a clock, because it starts at a
# falling-edge flop and ends at a rising-edge one. It was 35.2 ns until the
# multiplier moved into rd68011_mul: a DSP used to sit between the read data
# and the ALU result, because synthesis has no way to know that no multiply
# ever takes its operands from read data. Registering its operands and result
# was worth 4.0 ns, less than the 5.4 the DSP itself costs, because two thirds
# of this path is routing.
#
# The narrow second copy is done -- rd68011_ureq_rom holds the twenty-one bits
# a request is built from rather than all hundred and three -- and so are the
# two other things that were on this path. What is left is the shape of the
# design itself: an ALU result choosing the next microword, and that microword
# presenting the next bus request, inside half a clock. doc/implementation.md
# sets out what it would cost to go further, and why 16.9 MHz is where this
# stops.
#
# Both edges of clk are used (one bus state per half period), so a single
# create_clock covers the design and Vivado times the negative-edge paths
# against the half period automatically. Keep the duty cycle at exactly 50 %:
# UM 3.9 requires a square wave, and the half period is a real timing budget
# here, not a convention.

set clk_period_ns 60.000

create_clock -period $clk_period_ns -name clk -waveform "0.000 [expr {$clk_period_ns / 2.0}]" [get_ports clk]

# rst_n is an asynchronous initialisation input, not a functional MC68010 pin.
set_false_path -from [get_ports rst_n]

# Every other pin is asynchronous to clk from the core's point of view: the
# MC68010 samples DTACK/BERR/VPA/BR/BGACK/IPL/RESET/HALT with its own
# synchronisers (specification 47, "Asynchronous Input Setup Time"). Board-level
# input and output delays belong in the wrapper's constraints, not here.
