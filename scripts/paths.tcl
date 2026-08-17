# What actually limits this design's frequency?
#
#   vivado -mode batch -source scripts/paths.tcl -tclargs <repo-root>
#
# `make impl` reports the worst path static timing analysis can find. For this
# design that path is one the microcode cannot take: it needs a single microword
# to issue a bus cycle, feed read data into the ALU, *and* branch on a flag the
# ALU computed, and no microword does all three. doc/implementation.md sets out
# the counting.
#
# Static timing analysis has no way to know that, so the reported number answers
# a question nobody asked. This script asks the other one: with the routes the
# microcode cannot take excluded, what is left?
#
# The exclusions below are *reporting* aids and are deliberately not in
# scripts/rd68011.xdc. They are functional exclusions -- they depend on which
# microwords exist, not on how the logic is wired -- and a constraint file has
# no way to say that. Written into the build they would also disable the flag
# branches that are real. Here they only shape a report.
#
# Runs on the checkpoint `make impl` leaves behind, so it costs a minute rather
# than an hour. Run `make impl` first if there is no checkpoint or the RTL has
# moved on.

set root [lindex $argv 0]
set dcp  $root/build/rd68011_top_impl.dcp

if {![file exists $dcp]} {
    puts "RD68011: no $dcp -- run `make impl` first"
    exit 1
}

open_checkpoint $dcp

set period [get_property PERIOD [get_clocks clk]]

proc mhz {period slack} {
    return [format %.2f [expr {1000.0 / ($period - $slack)}]]
}

# ---------------------------------------------------------------------------
# The exclusions, each with the microcode fact that justifies it.
#
# Every one is a *pair* of -through points, so it cuts only the concatenation
# and not either half. Branching on an ALU flag is real and has to meet timing;
# so does read data reaching the next bus request. It is doing both in one
# microword that never happens.
# ---------------------------------------------------------------------------
# The request preview is reached from the ALU by exactly one route -- the
# condition multiplexer -- and only by three of its seventeen conditions:
# ZERO and N read the flags, CNT reads the result bus as `y[15:0] == 16'hFFFF`.
# Counting build/ucode.lst, the conditions that ever share a microword with a
# bus cycle are MASK 56, XWDR 21, FMT0 1, FMT8 1 and VERSION 1; none of those
# three is among them. Everything else the ALU reaches in the request goes
# through n_addr, not through the preview, so pairing the two ends cuts the
# concatenation and nothing else.
#
# Both ends name *module pins*, not the nets between them. Nets get merged:
# `n_flag` is a multiplexer over `n_flag_alu` and the shifter's, and synthesis
# folds that multiplexer into the logic downstream, so a route can reach the
# request without the net `u_seq/n_flag` existing anywhere on it; and `rq_nxt`
# stopped existing as a net at all once it became a multiplexer rather than a
# store output. Hierarchical pins survive, because scripts/synth.tcl passes
# -flatten_hierarchy none. Naming nets is how this script got a wrong answer
# twice.
#
# `req_kind` is the witness, rather than the whole request. It says which kind
# of bus cycle happens, and it is built from the preview and from nothing else
# -- unlike `req_addr`, which the ALU legitimately reaches through the address
# unit, and unlike `req_valid`, which depends on the address error computed from
# it. Every bit of the preview is selected by the same signal, so if the ALU
# cannot reach `req_kind` it is not in the preview's fan-in at all.
set exclusions {
    {alu-to-request
     "no microword both branches on an ALU result or flag and issues a bus cycle"
     {u_seq/u_alu/y[*] u_seq/u_alu/n_out u_seq/u_alu/z_out
      u_seq/u_shifter/dout[*]}
     {u_biu/req_kind[*]}}
}

# ---------------------------------------------------------------------------
# Baseline
# ---------------------------------------------------------------------------
proc worst {} {
    set tp [get_timing_paths -delay_type max -max_paths 1]
    return [list [get_property SLACK $tp] \
                 [get_property STARTPOINT_PIN $tp] \
                 [get_property ENDPOINT_PIN $tp]]
}

set base [worst]
puts "RD68011-PATHS: baseline slack [lindex $base 0] ns\
      ([mhz $period [lindex $base 0]] MHz)"
puts "RD68011-PATHS: baseline worst [lindex $base 1] -> [lindex $base 2]"

report_timing -delay_type max -max_paths 400 -unique_pins -nworst 1 \
    -file paths_baseline.rpt

# ---------------------------------------------------------------------------
# Apply the exclusions, checking that each one names something real. A -through
# that matches nothing excludes nothing, and would look exactly like a design
# that had no such path.
# ---------------------------------------------------------------------------
foreach e $exclusions {
    lassign $e name why frm to

    set fobj [get_pins -quiet $frm]
    set tobj [get_pins -quiet $to]
    if {[llength $fobj] == 0 || [llength $tobj] == 0} {
        puts "RD68011-PATHS: exclusion $name names nothing\
              ([llength $fobj] and [llength $tobj] pins) -- ABORT"
        exit 1
    }

    # Whether it cuts anything is the interesting part. A route that is not
    # there is the stronger result -- it means the design no longer contains
    # the structure the exclusion was written to describe, and the reported
    # number needs no exception to be believed.
    set before [get_timing_paths -delay_type max -max_paths 1 \
                    -through $fobj -through $tobj]
    if {[llength $before] == 0} {
        puts "RD68011-PATHS: $name is not in the design at all -- $why,\
              and now nothing wires it either"
        continue
    }
    puts "RD68011-PATHS: $name cuts a path of slack\
          [get_property SLACK $before] ns; $why"

    set_false_path -through $fobj -through $tobj
}

# ---------------------------------------------------------------------------
# What is left
# ---------------------------------------------------------------------------
set real [worst]
puts "RD68011-PATHS: activatable slack [lindex $real 0] ns\
      ([mhz $period [lindex $real 0]] MHz)"
puts "RD68011-PATHS: activatable worst [lindex $real 1] -> [lindex $real 2]"
puts "RD68011-PATHS: the exclusions are worth\
      [format %.3f [expr {[lindex $real 0] - [lindex $base 0]}]] ns"

report_timing -delay_type max -max_paths 400 -unique_pins -nworst 1 \
    -file paths_activatable.rpt

# ---------------------------------------------------------------------------
# Headroom
#
# Cutting everything that decides the kind of the next bus cycle says what
# would be left if choosing the request cost nothing at all. It is an upper
# bound and not a promise: a real fix replaces a lookup with a multiplexer, not
# with nothing.
# ---------------------------------------------------------------------------
set_false_path -through [get_pins u_biu/req_kind[*]]

set head [worst]
puts "RD68011-PATHS: headroom slack [lindex $head 0] ns\
      ([mhz $period [lindex $head 0]] MHz) -- an upper bound, see the comment"
puts "RD68011-PATHS: headroom worst [lindex $head 1] -> [lindex $head 2]"

report_timing -delay_type max -max_paths 400 -unique_pins -nworst 1 \
    -file paths_headroom.rpt

exit 0
