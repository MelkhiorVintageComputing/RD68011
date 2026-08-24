# RD68011 timing constraints, for Quartus.
#
# The Altera twin of scripts/rd68011.xdc, and it exists to say the same thing to
# a different timing engine rather than to say something new. Both are SDC in
# origin, so create_clock and set_false_path are identical; what differs is
# where the multicycle exception has to point, because the two tools name
# registers differently, and derive_clock_uncertainty, which Vivado has no
# equivalent for.
#
# Keep clk_period_ns equal to the .xdc's. It is the number both flows report
# slack against, so a MAX 10 result and an Artix-7 result are only comparable
# while they share it. doc/implementation.md prints both.
set clk_period_ns 48.000

create_clock -period $clk_period_ns -name clk -waveform "0.000 [expr {$clk_period_ns / 2.0}]" [get_ports clk]

# Quartus does not add clock uncertainty unless asked; Vivado's default already
# includes it. Without this the MAX 10 number would be optimistic against the
# Artix-7 one for a reason that has nothing to do with either device.
derive_clock_uncertainty

# rst_n is an asynchronous initialisation input, not a functional MC68010 pin.
set_false_path -from [get_ports rst_n]

# The write data has three half clocks, not one. The .xdc has the argument in
# full; in short, `d_o` is loaded on the falling edge entering S3 while the
# microword that supplies it became current on the rising edge that started S0,
# and the states in between alternate edges unconditionally.
#
# The Vivado form is `-to [get_pins u_biu/d_o_reg[*]/D]`. Quartus names the
# instance `rd68011_biu:u_biu` and the register `d_o[*]`, and a multicycle takes
# registers rather than their data pins.
#
# A pattern that matches nothing is silent in Quartus beyond one warning, and an
# unapplied multicycle makes the result pessimistic for the wrong reason -- so
# scripts/quartus.tcl counts what this matched and fails if it is zero, rather
# than trusting the pattern.
set_multicycle_path 2 -setup -to [get_registers {*rd68011_biu:u_biu|d_o[*]}]
set_multicycle_path 1 -hold  -to [get_registers {*rd68011_biu:u_biu|d_o[*]}]

# Every other pin is asynchronous to clk from the core's point of view: the
# MC68010 samples DTACK/BERR/VPA/BR/BGACK/IPL/RESET/HALT with its own
# synchronisers (specification 47, "Asynchronous Input Setup Time"). Board-level
# input and output delays belong in the wrapper's constraints, not here.
#
# Saying so explicitly is what makes this an out-of-context result, comparable
# with the Artix-7 one. Vivado gets there by having no input or output delay in
# the .xdc, which leaves those paths unconstrained and out of the worst-case
# number; Quartus instead times them against a default of zero and they swamp
# everything. Cutting them leaves the register-to-register paths, which are the
# ones that belong to the core rather than to somebody's board.
set_false_path -from [remove_from_collection [all_inputs] [get_ports clk]]
set_false_path -to   [all_outputs]
