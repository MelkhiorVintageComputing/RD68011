# Vivado place and route for RD68011, for the numbers that mean something.
#
#   vivado -mode batch -source scripts/impl.tcl -tclargs <part> <top> <repo-root>
#
# `make synth` reports post-synthesis timing, which is an estimate: two thirds
# of this design's critical path is routing, and before placement the router's
# contribution is a guess. This runs the real thing, so doc/implementation.md
# can quote a number that survives contact with the fabric.
#
# Out of context, like the synthesis: this is a core, not a board design.

set part [lindex $argv 0]
set top  [lindex $argv 1]
set root [lindex $argv 2]

puts "RD68011: implementing $top for $part"

set f [open $root/build/rtl.f r]
set rtl [split [string trim [read $f]] "\n"]
close $f

read_verilog -sv $rtl
read_xdc $root/scripts/rd68011.xdc

synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy none
opt_design
place_design
phys_opt_design
route_design

report_utilization       -file impl_utilization.rpt
report_timing_summary -delay_type max -max_paths 20 -file impl_timing.rpt
report_clock_utilization -file impl_clocks.rpt
write_checkpoint -force ${top}_impl.dcp

set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]
set period [get_property PERIOD [get_clocks clk]]

puts "RD68011: routed worst negative slack = $wns ns (hold $whs ns)"
puts "RD68011: at a period of $period ns, so the design runs at\
     [format %.2f [expr {1000.0 / ($period - $wns)}]] MHz"
puts "RD68011: cells: LUT [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]] \
     FF [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]] \
     CARRY [llength [get_cells -hier -filter {PRIMITIVE_GROUP == CARRY}]] \
     DSP [llength [get_cells -hier -filter {REF_NAME =~ DSP*}]] \
     BRAM [llength [get_cells -hier -filter {PRIMITIVE_GROUP == BLOCKRAM}]]"

if {$wns < 0 || $whs < 0} {
    puts "RD68011: TIMING NOT MET"
    exit 1
}
puts "RD68011: implementation ok"
exit 0
