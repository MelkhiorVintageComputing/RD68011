| rte_probe -- does RTE come back from a format $8 frame at all?
|
| A companion probe to sim/programs/p03_fault.S, written to separate two
| questions that p03 asks at once:
|
|   (a) does the processor accept a format $8 frame on RTE, restore SR and PC
|       from it and carry on?  (this probe's checks 1 and 2)
|   (b) does it honour RR = 1 -- "software has already completed the access,
|       do not redo it" -- and take the operand from the data input buffer
|       image?  (this probe's check 3, which only observes and never fails)
|
| p03_fault.S needs both.  The fault window it runs against never goes away,
| so a processor that lacks (b) reruns the access, faults again and loops --
| which looks exactly like (a) being broken.  Here the fault is armed once at
| a time by a write to ARM_ADDR, so a rerun succeeds and (a) can be measured
| on its own.
|
| A diagnostic rather than a conformance test.  It needs a harness that can
| arm a fault once, which sim/suska/wf68k10_rte_probe_tb.vhd has and the
| RD68011 core harness does not, so it runs on the Suska core only; our own
| RR handling is covered by p03_fault.S, which needs no such thing because it
| passes.  `make suska-rte` runs it.

    .include "rd68011.inc"

    .equ    HOLE,       0x2000      | the address the harness faults on
    .equ    ARM_ADDR,   0x2200      | writing here arms exactly one fault
    .equ    SUPPLIED,   0xC0DE      | what the handler offers when RR is set

    VECTORS
    RESULT_BLOCK
    .section .result,"aw"
observed:   .word   0               | 0x040A -- what check 3 actually saw

    .text
    .globl  _start
_start:
    PROGRAM_BEGIN
    | ------------------------------------------------------------------
    CHECK   1                       | a read, faulted once, then rerun
    | ------------------------------------------------------------------
    | RR is left clear, so the processor is asked to redo the access.  The
    | harness answers the second attempt, so this passes on any processor
    | whose RTE accepts a format $8 frame -- whether or not it implements
    | instruction continuation.
    clr.w   fault_count
    clr.w   rr_mode
    move.w  #0x1234,HOLE
    move.w  #1,ARM_ADDR
    movea.l #HOLE,%a0
    move.w  (%a0),%d1
    EXPECT_EQ_W %d1, 0x1234
    move.w  fault_count,%d2
    EXPECT_EQ_W %d2, 1

    | ------------------------------------------------------------------
    CHECK   2                       | a write, faulted once, then rerun
    | ------------------------------------------------------------------
    clr.w   fault_count
    clr.w   rr_mode
    move.w  #0,HOLE
    move.w  #1,ARM_ADDR
    movea.l #HOLE,%a0
    move.w  #0x5A5A,(%a0)
    move.w  fault_count,%d2
    EXPECT_EQ_W %d2, 1
    move.w  HOLE,%d0
    EXPECT_EQ_W %d0, 0x5A5A

    | ------------------------------------------------------------------
    CHECK   3                       | RR = 1: is the access taken as done?
    | ------------------------------------------------------------------
    | The handler sets RR and puts SUPPLIED in the data input buffer image.
    | An MC68010 does not redo the cycle and the instruction takes SUPPLIED.
    | A processor that ignores RR reruns the access and takes what memory
    | holds, which is deliberately a different value.  Both are recorded and
    | neither fails, because this check exists to report, not to judge.
    clr.w   fault_count
    move.w  #0x1234,HOLE
    move.w  #1,rr_mode
    move.w  #1,ARM_ADDR
    movea.l #HOLE,%a0
    move.w  (%a0),%d1
    move.w  %d1,observed
    clr.w   rr_mode

    bra     pass

| ---------------------------------------------------------------------------
| The handler
| ---------------------------------------------------------------------------
    .globl  v_bus, v_addr
v_bus:
v_addr:
    movem.l %d0-%d1,-(%sp)          | the frame is eight bytes further up now
    addq.w  #1,fault_count
    tst.w   rr_mode
    beq     1f
    move.w  8+8(%sp),%d0            | the special status word
    ori.w   #0x8000,%d0             | RR: do not rerun the cycle
    move.w  %d0,8+8(%sp)
    move.w  #SUPPLIED,20+8(%sp)     | the data input buffer image
1:  movem.l (%sp)+,%d0-%d1
    rte

    UNEXPECTED_HANDLER
    .globl  v_illegal, v_divzero, v_chk, v_trapv, v_priv, v_trace
    .globl  v_linea, v_linef, v_format, v_trap, v_irq
v_illegal = v_unexpected
v_divzero = v_unexpected
v_chk     = v_unexpected
v_trapv   = v_unexpected
v_priv    = v_unexpected
v_trace   = v_unexpected
v_linea   = v_unexpected
v_linef   = v_unexpected
v_format  = v_unexpected
v_trap    = v_unexpected
v_irq     = v_unexpected

    PROGRAM_END

| ---------------------------------------------------------------------------
    .bss
    .align  2
fault_count: .space 2
rr_mode:     .space 2
