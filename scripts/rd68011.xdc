# RD68011 timing constraints.
#
# CLK_PERIOD_NS is the target, not the original part's 125 ns (8 MHz). An FPGA
# build is expected to run the core faster than the original; the number here
# is what `make synth` reports slack against.
#
# 40 ns is where the design closes today on the Artix-7 part, with 1.7 ns to
# spare -- 25 MHz, three times the original's 8 MHz. It closed at 20 ns while
# the core was only a bus interface and a small microcode store; the long path
# now is the microcode store itself, which is read twice combinationally in
# series (the current microword, then the next one, whose bus request has to
# reach the pins on the same edge). Making that a block RAM or splitting the
# request fields into a narrower second store is P8's problem, not a
# correctness one -- see doc/bus-timing-compliance.md.
#
# Both edges of clk are used (one bus state per half period), so a single
# create_clock covers the design and Vivado times the negative-edge paths
# against the half period automatically. Keep the duty cycle at exactly 50 %:
# UM 3.9 requires a square wave, and the half period is a real timing budget
# here, not a convention.

set clk_period_ns 40.000

create_clock -period $clk_period_ns -name clk -waveform "0.000 [expr {$clk_period_ns / 2.0}]" [get_ports clk]

# rst_n is an asynchronous initialisation input, not a functional MC68010 pin.
set_false_path -from [get_ports rst_n]

# Every other pin is asynchronous to clk from the core's point of view: the
# MC68010 samples DTACK/BERR/VPA/BR/BGACK/IPL/RESET/HALT with its own
# synchronisers (specification 47, "Asynchronous Input Setup Time"). Board-level
# input and output delays belong in the wrapper's constraints, not here.
