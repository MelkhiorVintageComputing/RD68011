| p02_excep -- exceptions as a program actually uses them.
|
| The sweep skips every vector whose reference took an exception, because an
| MC68000's frame is three words where an MC68010's is four. The directed
| testbenches check the frame itself. What neither does is *use* one: a handler
| that runs real code, adjusts the frame, and returns into the program, over
| and over, with the program noticing whether it came back to the right place
| in the right mode with the right flags.

    .include "rd68011.inc"

    VECTORS
    RESULT_BLOCK

    .text
    .globl  _start
_start:
    PROGRAM_BEGIN
    | ------------------------------------------------------------------
    CHECK   1                       | TRAP #n, four of them, each its own
    | ------------------------------------------------------------------
    clr.l   trap_log
    trap    #0
    trap    #1
    trap    #2
    trap    #3
    | each handler shifts a nibble in, so the order is checked as well
    move.l  trap_log,%d0
    EXPECT_EQ_L %d0, 0x00001234

    | ------------------------------------------------------------------
    CHECK   2                       | divide by zero, and carrying on after it
    | ------------------------------------------------------------------
    clr.w   excep_count
    move.l  #100,%d0
    moveq   #0,%d1
    divu.w  %d1,%d0                 | vector 5
    move.w  excep_count,%d2
    EXPECT_EQ_W %d2, 1
    | the handler returned to the instruction after the divide
    moveq   #55,%d3
    EXPECT_EQ_L %d3, 55

    | ------------------------------------------------------------------
    CHECK   3                       | CHK, in bounds and out
    | ------------------------------------------------------------------
    clr.w   excep_count
    move.w  #10,%d0
    chk.w   #20,%d0                 | inside: nothing happens
    move.w  excep_count,%d2
    EXPECT_EQ_W %d2, 0
    move.w  #30,%d0
    chk.w   #20,%d0                 | outside: vector 6
    move.w  excep_count,%d2
    EXPECT_EQ_W %d2, 1

    | ------------------------------------------------------------------
    CHECK   4                       | TRAPV, only when V is set
    | ------------------------------------------------------------------
    clr.w   excep_count
    moveq   #1,%d0
    add.l   #1,%d0                  | no overflow
    trapv
    move.w  excep_count,%d2
    EXPECT_EQ_W %d2, 0
    move.w  #0x7FFF,%d0
    addi.w  #1,%d0                  | overflow
    trapv                           | vector 7
    move.w  excep_count,%d2
    EXPECT_EQ_W %d2, 1

    | ------------------------------------------------------------------
    CHECK   5                       | ILLEGAL, line A, line F: the handler
    |                               | has to step over each of them itself
    | ------------------------------------------------------------------
    clr.w   excep_count
    illegal                         | vector 4
    .word   0xA123                  | vector 10
    .word   0xF456                  | vector 11
    move.w  excep_count,%d2
    EXPECT_EQ_W %d2, 3

    | ------------------------------------------------------------------
    CHECK   6                       | user mode, and what it may not do
    | ------------------------------------------------------------------
    | MOVE from SR is privileged on the MC68010 and was not on the MC68000,
    | which is one of the differences the whole project turns on.
    clr.w   excep_count
    movea.l #__stack_top-0x400,%a0
    move.l  %a0,%usp
    move.w  #0x0000,%sr             | drop to user mode, mask zero
    move.w  %sr,%d0                 | vector 8; the handler brings us back
    | back in supervisor mode, having skipped the instruction
    move.w  %sr,%d0
    andi.w  #0x2000,%d0
    EXPECT_EQ_W %d0, 0x2000
    move.w  excep_count,%d2
    EXPECT_EQ_W %d2, 1

    | ------------------------------------------------------------------
    CHECK   7                       | trace: one exception per instruction
    | ------------------------------------------------------------------
    clr.w   excep_count
    move.w  #3,trace_left           | three instructions, then turn it off
    move.w  #0xA700,%sr             | supervisor, trace on
    nop                             | 1
    nop                             | 2
    nop                             | 3
    move.w  excep_count,%d2
    EXPECT_EQ_W %d2, 3

    | ------------------------------------------------------------------
    CHECK   8                       | the vector base register moves the table
    | ------------------------------------------------------------------
    | Build a second table at alt_vectors with one entry changed, point VBR at
    | it, and check that the changed handler is the one that runs.
    clr.w   excep_count
    lea     alt_vectors,%a0
    move.l  #0x000000FF,%d0         | 256 longs, minus one
1:  move.l  #v_unexpected,(%a0)+
    subq.l  #1,%d0
    bne     1b
    lea     alt_vectors,%a0
    move.l  #v_alt_trap,128(%a0)    | vector 32: TRAP #0
    movec   %a0,%vbr
    trap    #0
    movec   %vbr,%d0
    move.l  %a0,%d1
    cmp.l   %d1,%d0
    bne     fail
    moveq   #0,%d0
    movec   %d0,%vbr                | put it back before anything else traps
    move.w  excep_count,%d2
    EXPECT_EQ_W %d2, 0x00AA         | only the alternate handler could do that

    | ------------------------------------------------------------------
    CHECK   9                       | RTE puts the condition codes back
    | ------------------------------------------------------------------
    moveq   #0,%d0
    addq.l  #1,%d0                  | Z clear, N clear
    move.w  #0x001F,%d0             | ... now set every flag by hand
    move.w  %d0,%ccr
    trap    #4                      | a handler that scribbles on the flags
    move.w  %sr,%d0
    andi.w  #0x001F,%d0
    EXPECT_EQ_W %d0, 0x001F

    | ------------------------------------------------------------------
    CHECK   10                      | MOVES reaches another address space
    | ------------------------------------------------------------------
    | Nothing in this testbench decodes the function code differently, so what
    | is checked is that the transfer happens and the registers survive it.
    moveq   #1,%d0
    movec   %d0,%sfc
    moveq   #5,%d0
    movec   %d0,%dfc
    lea     scratch,%a0
    move.l  #0xFEEDFACE,%d1
    moves.l %d1,(%a0)
    moveq   #0,%d2
    moves.l (%a0),%d2
    EXPECT_EQ_L %d2, 0xFEEDFACE
    movec   %sfc,%d3
    EXPECT_EQ_L %d3, 1
    movec   %dfc,%d3
    EXPECT_EQ_L %d3, 5

    bra     pass

| ---------------------------------------------------------------------------
| Handlers
| ---------------------------------------------------------------------------

| TRAP #0..#3 shift their number into a log; #4 scribbles on the flags to see
| whether RTE puts them back. The vector offset in the frame says which.
    .globl  v_trap
v_trap:
    move.w  6(%sp),%d0
    andi.w  #0x0FFF,%d0
    subi.w  #128,%d0                | vector 32 is TRAP #0
    lsr.w   #2,%d0                  | ... four bytes per vector
    cmpi.w  #4,%d0
    beq     1f
    addq.w  #1,%d0                  | log 1..4 rather than 0..3
    move.l  trap_log,%d1
    lsl.l   #4,%d1
    or.w    %d0,%d1
    move.l  %d1,trap_log
    rte
1:  | TRAP #4: leave the flags in a mess, which RTE has to undo
    moveq   #0,%d0
    move.w  #0x0000,%ccr
    rte

    .globl  v_alt_trap
v_alt_trap:
    move.w  #0x00AA,excep_count
    rte

| The exceptions that stack the following instruction: just count and return.
    .globl  v_divzero, v_chk, v_trapv
v_divzero:
v_chk:
v_trapv:
    addq.w  #1,excep_count
    rte

| The exceptions that stack their own instruction: count, step over it, return.
| ILLEGAL, line A and line F are all one word here.
    .globl  v_illegal, v_linea, v_linef
v_illegal:
v_linea:
v_linef:
    addq.w  #1,excep_count
    addq.l  #2,2(%sp)               | past the instruction that caused it
    rte

| A privilege violation, from user mode. Step over the instruction and set the
| supervisor bit in the frame, so the program comes back where it can carry on.
    .globl  v_priv
v_priv:
    addq.w  #1,excep_count
    addq.l  #2,2(%sp)
    ori.w   #0x2000,(%sp)
    rte

| Trace: count, and turn tracing off in the frame once enough have gone by.
    .globl  v_trace
v_trace:
    addq.w  #1,excep_count
    subq.w  #1,trace_left
    bne     1f
    andi.w  #0x7FFF,(%sp)           | clear T in the status register we return to
1:  rte

| Nothing else should happen.
    UNEXPECTED_HANDLER
    .globl  v_bus, v_addr, v_format, v_irq
v_bus    = v_unexpected
v_addr   = v_unexpected
v_format = v_unexpected
v_irq    = v_unexpected

    PROGRAM_END

| ---------------------------------------------------------------------------
    .bss
    .align  2
trap_log:    .space  4
excep_count: .space  2
trace_left:  .space  2
scratch:     .space  16
    .align  2
alt_vectors: .space  1024
