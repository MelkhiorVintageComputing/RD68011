# Quartus analysis, fit and timing for RD68011.
#
#   quartus_sh -t scripts/quartus.tcl <family> <device> <top> <repo-root> <stage>
#
# Invoked from the Makefile with cwd = build/quartus/. `stage` is `map` for
# analysis and synthesis alone -- which is what `make lint-quartus` wants, a
# fifth front-end reading the RTL -- or `fit` for the whole flow down to a
# routed design and a frequency, which is `make quartus`.
#
# The Altera twin of scripts/synth.tcl and scripts/impl.tcl, and it is written
# to be comparable with them rather than merely to work:
#
#   * the same file list, build/rtl.f, in the same dependency order, because
#     packages have to be read before their users and there is no reason for
#     two places to know that;
#   * the same clock period, from scripts/rd68011.sdc, which mirrors the .xdc;
#   * out of context, as Vivado's `-mode out_of_context` is. Quartus has no such
#     switch, so every port but clk becomes a virtual pin: the fit then measures
#     the core and not the pad ring. Without this the two frequency numbers
#     would be measuring different things.

package require ::quartus::project
package require ::quartus::flow

set family [lindex $argv 0]
set device [lindex $argv 1]
set top    [lindex $argv 2]
set root   [lindex $argv 3]
set stage  [lindex $argv 4]

puts "RD68011: quartus $stage, $top on $device ($family)"

project_new rd68011 -overwrite

set_global_assignment -name FAMILY $family
set_global_assignment -name DEVICE $device
set_global_assignment -name TOP_LEVEL_ENTITY $top

set f [open $root/build/rtl.f r]
set rtl [split [string trim [read $f]] "\n"]
close $f
foreach v $rtl {
    set_global_assignment -name SYSTEMVERILOG_FILE $v
}

set_global_assignment -name SDC_FILE $root/scripts/rd68011.sdc

# Said explicitly rather than left to the fitter's own count: it warns when it
# is not set, and on a shared machine taking every core is not a kindness. The
# Makefile's AJOBS chooses it.
set_global_assignment -name NUM_PARALLEL_PROCESSORS [lindex $argv 5]

# Real pins, not virtual ones. `VIRTUAL_PIN ON -to *` with an `OFF -to clk` after
# it was tried and is a trap: the wildcard wins, clk becomes virtual too, its
# clock network becomes ordinary routing across a three-quarters-full device,
# and the fit comes back at -191 ns of slack on a 48 ns clock. The fit report
# says "Total pins 0 / 360", which is the tell.
#
# So the out-of-context part is done in the SDC instead, where scripts/rd68011.sdc
# cuts every path to and from a pin. That is what Vivado's -mode out_of_context
# amounts to here anyway -- it inserts no buffers and the .xdc gives no input or
# output delays, so those paths are unconstrained and out of the worst-case
# number. Quartus would otherwise time them against a default of zero.

export_assignments

if {[catch {execute_module -tool map} result]} {
    puts "RD68011: analysis and synthesis failed: $result"
    exit 1
}

if {$stage eq "map"} {
    puts "RD68011: analysis and synthesis ok"
    project_close
    exit 0
}

if {[catch {execute_module -tool fit} result]} {
    puts "RD68011: fit failed: $result"
    exit 1
}
project_close
puts "RD68011: fit ok"
exit 0
