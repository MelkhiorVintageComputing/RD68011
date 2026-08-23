# Timing numbers for the fitted RD68011, and the check that the constraints
# actually landed on something.
#
#   quartus_sta -t scripts/quartus_sta.tcl
#
# Invoked from the Makefile with cwd = build/quartus/, after scripts/quartus.tcl
# has fitted the design. Prints RD68011: lines for the console, and leaves the
# Fmax summary in rd68011.sta.rpt.
#
# The multicycle check is the reason this is a script rather than a grep. A
# Quartus exception whose pattern matches nothing is close to silent, and an
# unapplied multicycle on the write-data register would cost the design a whole
# clock of budget on a path that really has three half clocks -- making the MAX
# 10 result pessimistic for a reason that has nothing to do with the MAX 10.
# scripts/rd68011.sdc says the pattern; this counts what it caught.

project_open rd68011

create_timing_netlist -model slow
read_sdc
update_timing_netlist

set d_o [get_registers {*rd68011_biu:u_biu|d_o[*]}]
set n   [get_collection_size $d_o]
puts "RD68011: the write-data multicycle matched $n registers"
if {$n == 0} {
    puts "RD68011: the multicycle in scripts/rd68011.sdc matched nothing"
    qexit -error
}

report_clock_fmax_summary -panel_name "Fmax Summary"

set period [get_clock_info -period [get_clocks clk]]

set wns 1e9
foreach_in_collection p [get_timing_paths -setup -npaths 1 -detail summary] {
    set wns [get_path_info $p -slack]
}
set whs 1e9
foreach_in_collection p [get_timing_paths -hold -npaths 1 -detail summary] {
    set whs [get_path_info $p -slack]
}

puts "RD68011: routed worst negative slack = $wns ns (hold $whs ns)"
puts [format "RD68011: at a period of %.3f ns, so the design runs at %.2f MHz" \
      $period [expr {1000.0 / ($period - $wns)}]]

delete_timing_netlist
project_close

if {$wns < 0 || $whs < 0} {
    puts "RD68011: TIMING NOT MET"
    qexit -error
}
puts "RD68011: implementation ok"
qexit -success
