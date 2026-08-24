# Timing for the fitted RD68011, and the checks that are checks.
#
#   quartus_sta -t scripts/quartus_sta.tcl
#
# Invoked from the Makefile with cwd = build/quartus/, after scripts/quartus.tcl
# has fitted the design. Prints RD68011: lines for the console and writes
# fmax.rpt, which tools/quartus_report.py reads.
#
# What is a hard failure here and what is not:
#
#   * the multicycle matching nothing IS. A Quartus exception whose pattern
#     selects no node is close to silent, and an unapplied multicycle on the
#     write-data register would cost a whole clock of budget on a path that
#     really has three half clocks. scripts/rd68011.sdc says the pattern; this
#     counts what it caught.
#   * a hold violation IS. Hold does not improve with a slower clock, so it is
#     wrong at any frequency.
#   * setup slack against the 48 ns in scripts/rd68011.sdc is NOT, and that is
#     deliberate. 48 ns is the Artix-7 target, kept here so both flows report
#     against the same period; this part comes within a couple of nanoseconds
#     of it and does not quite make it. The Makefile gates on measured Fmax
#     instead, which is a regression test rather than an aspiration -- and
#     Quartus's Fmax is the better number anyway, because it scales both clock
#     edges together, which is what this design's edge-to-edge paths need and
#     what doc/critical-path.md says Vivado's slack extrapolation does not do.

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

report_clock_fmax_summary -panel_name "Fmax" -file fmax.rpt

set period [get_clock_info -period [get_clocks clk]]

set wns 1e9
foreach_in_collection p [get_timing_paths -setup -npaths 1 -detail summary] {
    set wns [get_path_info $p -slack]
    # -from and -to give node ids, not names; get_node_info turns them back.
    puts "RD68011: the worst setup path is\
          [get_node_info -name [get_path_info $p -from]] to\
          [get_node_info -name [get_path_info $p -to]],\
          [get_path_info $p -num_logic_levels] logic levels"
}
set whs 1e9
foreach_in_collection p [get_timing_paths -hold -npaths 1 -detail summary] {
    set whs [get_path_info $p -slack]
}

puts "RD68011: routed setup slack = $wns ns against $period ns (hold $whs ns)"

delete_timing_netlist
project_close

if {$whs < 0} {
    puts "RD68011: HOLD NOT MET, which no clock period fixes"
    qexit -error
}
puts "RD68011: fit measured"
qexit -success
