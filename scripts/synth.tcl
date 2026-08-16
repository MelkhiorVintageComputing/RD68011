# Vivado out-of-context synthesis for RD68011.
#
#   vivado -mode batch -source scripts/synth.tcl -tclargs <part> <top> <repo-root>
#
# Invoked from the Makefile with cwd = build/. Out of context because this is a
# core, not a board design: no I/O buffers are inserted and the pins stay pins.

set part [lindex $argv 0]
set top  [lindex $argv 1]
set root [lindex $argv 2]

puts "RD68011: synthesising $top for $part"

# The file list, in dependency order, comes from the Makefile: packages have to
# be read before their users and there is no reason for two places to know that.
set f [open $root/build/rtl.f r]
set rtl [split [string trim [read $f]] "\n"]
close $f

read_verilog -sv $rtl
read_xdc $root/scripts/rd68011.xdc

synth_design -top $top -part $part -mode out_of_context -flatten_hierarchy none

report_utilization  -file utilization.rpt
report_timing_summary -delay_type max -max_paths 10 -file timing.rpt
write_checkpoint -force ${top}_synth.dcp

# Pull the headline numbers back out for the console, so `make synth` says
# something useful without opening the reports.
set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set luts [get_property CELL_COUNT [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]]
puts "RD68011: worst negative slack = $wns ns"
puts "RD68011: cells: LUT [llength [get_cells -hier -filter {PRIMITIVE_GROUP == LUT}]] \
     FF [llength [get_cells -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]"

if {$wns < 0} {
    puts "RD68011: TIMING NOT MET"
    exit 1
}
puts "RD68011: synthesis ok"
exit 0
