# RD68011 timing constraints.
#
# CLK_PERIOD_NS is the target, not the original part's 125 ns (8 MHz). An FPGA
# build is expected to run the core far faster than the 1979 part; the number
# here is what `make synth` reports slack against, so raise it as the design
# fills in and the reported Fmax settles.
#
# Both edges of clk are used (one bus state per half period), so a single
# create_clock covers the design and Vivado times the negative-edge paths
# against the half period automatically. Keep the duty cycle at exactly 50 %:
# UM 3.9 requires a square wave, and the half period is a real timing budget
# here, not a convention.

set clk_period_ns 20.000

create_clock -period $clk_period_ns -name clk -waveform "0.000 [expr {$clk_period_ns / 2.0}]" [get_ports clk]

# rst_n is an asynchronous initialisation input, not a functional MC68010 pin.
set_false_path -from [get_ports rst_n]

# Every other pin is asynchronous to clk from the core's point of view: the
# MC68010 samples DTACK/BERR/VPA/BR/BGACK/IPL/RESET/HALT with its own
# synchronisers (specification 47, "Asynchronous Input Setup Time"). Board-level
# input and output delays belong in the wrapper's constraints, not here.
