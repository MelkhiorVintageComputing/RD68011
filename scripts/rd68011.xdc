# RD68011 timing constraints.
#
# CLK_PERIOD_NS is the target, not the original part's 125 ns (8 MHz). An FPGA
# build is expected to run the core faster than the original; the number here
# is what `make synth` reports slack against.
#
# 44 ns is where the design closes today on the Artix-7 part, with 1.4 ns to
# spare -- 22.7 MHz, nearly three times the original's 8 MHz. The number has
# moved as the design grew: 20 ns with a bus interface and a 17-word microcode
# store, 40 ns with MOVE, 44 ns with the whole integer set.
#
# The long path is the microcode store, which is read twice combinationally in
# series -- the current microword, then the next one, whose bus request has to
# reach the pins on the edge that ends the current cycle. At 4849 microwords of
# 70 bits that is now most of the design's logic. Making it a block RAM, or
# splitting the handful of request fields into a narrow second store that can
# be read ahead, is P8's problem and not a correctness one; see
# doc/bus-timing-compliance.md.
#
# Both edges of clk are used (one bus state per half period), so a single
# create_clock covers the design and Vivado times the negative-edge paths
# against the half period automatically. Keep the duty cycle at exactly 50 %:
# UM 3.9 requires a square wave, and the half period is a real timing budget
# here, not a convention.

set clk_period_ns 44.000

create_clock -period $clk_period_ns -name clk -waveform "0.000 [expr {$clk_period_ns / 2.0}]" [get_ports clk]

# rst_n is an asynchronous initialisation input, not a functional MC68010 pin.
set_false_path -from [get_ports rst_n]

# Every other pin is asynchronous to clk from the core's point of view: the
# MC68010 samples DTACK/BERR/VPA/BR/BGACK/IPL/RESET/HALT with its own
# synchronisers (specification 47, "Asynchronous Input Setup Time"). Board-level
# input and output delays belong in the wrapper's constraints, not here.
