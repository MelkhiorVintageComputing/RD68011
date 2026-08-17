| p01_flow -- control flow, the stack, and the calling sequences a compiler
| actually emits.
|
| Everything the reference vectors check, they check one instruction at a time
| from a fabricated register state. Nothing until now has run a *sequence*: a
| return address that has to survive three nested calls, a frame pointer that
| has to still be a frame pointer after the callee saved and restored eight
| registers, a loop counter that has to reach exactly minus one.
|
| So this program is deliberately uninteresting arithmetic wrapped in the
| structures that carry it around.

    .include "rd68011.inc"

    VECTORS
    RESULT_BLOCK

    .text
    .globl  _start
_start:
    | ------------------------------------------------------------------
    CHECK   1                       | MOVEQ sign-extends; MOVE.W does not
    | ------------------------------------------------------------------
    moveq   #-1,%d0
    EXPECT_EQ_L %d0, 0xFFFFFFFF
    move.l  #0x11223344,%d1
    move.w  #0x5566,%d1
    EXPECT_EQ_L %d1, 0x11225566

    | ------------------------------------------------------------------
    CHECK   2                       | BSR and RTS, and what survives them
    | ------------------------------------------------------------------
    move.l  #0x0BADF00D,%d0
    movea.l %sp,%a5                 | remember where the stack was
    bsr     add_one
    EXPECT_EQ_L %d0, 0x0BADF00E
    cmpa.l  %a5,%sp
    bne     fail                    | RTS left the stack where it found it

    | ------------------------------------------------------------------
    CHECK   3                       | three deep, and back
    | ------------------------------------------------------------------
    moveq   #0,%d0
    movea.l %sp,%a5
    bsr     depth3
    EXPECT_EQ_L %d0, 3
    cmpa.l  %a5,%sp
    bne     fail

    | ------------------------------------------------------------------
    CHECK   4                       | LINK and UNLK, with locals
    | ------------------------------------------------------------------
    movea.l %sp,%a5
    move.l  #0x1234ABCD,%d0
    bsr     frame_user
    EXPECT_EQ_L %d0, 0x1234ABCE
    cmpa.l  %a5,%sp
    bne     fail

    | ------------------------------------------------------------------
    CHECK   5                       | MOVEM saves and restores across a callee
    | ------------------------------------------------------------------
    move.l  #0x0000AAAA,%d2
    move.l  #0x0000BBBB,%d3
    move.l  #0x0000CCCC,%d4
    move.l  #0x0000DDDD,%d5
    move.l  #0x0000EEEE,%d6
    movea.l #0x00001111,%a2
    movea.l #0x00002222,%a3
    movea.l #0x00003333,%a4
    bsr     clobber_all
    EXPECT_EQ_L %d2, 0x0000AAAA
    EXPECT_EQ_L %d3, 0x0000BBBB
    EXPECT_EQ_L %d4, 0x0000CCCC
    EXPECT_EQ_L %d5, 0x0000DDDD
    EXPECT_EQ_L %d6, 0x0000EEEE
    move.l  %a2,%d0
    EXPECT_EQ_L %d0, 0x00001111
    move.l  %a3,%d0
    EXPECT_EQ_L %d0, 0x00002222
    move.l  %a4,%d0
    EXPECT_EQ_L %d0, 0x00003333

    | ------------------------------------------------------------------
    CHECK   6                       | RTD, which drops arguments on the way out
    | ------------------------------------------------------------------
    movea.l %sp,%a5
    move.l  #7,-(%sp)
    move.l  #35,-(%sp)
    bsr     sum_two_rtd             | takes eight bytes of arguments with it
    EXPECT_EQ_L %d0, 42
    cmpa.l  %a5,%sp
    bne     fail

    | ------------------------------------------------------------------
    CHECK   7                       | a DBcc loop that has to end on -1
    | ------------------------------------------------------------------
    lea     numbers,%a0
    moveq   #0,%d0
    move.w  #9,%d1                  | ten of them
1:  add.l   (%a0)+,%d0
    dbf     %d1,1b
    EXPECT_EQ_L %d0, 55             | 1 + 2 + ... + 10
    EXPECT_EQ_W %d1, 0xFFFF

    | ------------------------------------------------------------------
    CHECK   8                       | a jump table, built out of a lea and a shift
    | ------------------------------------------------------------------
    moveq   #2,%d0                  | pick the third entry
    bsr     dispatch
    EXPECT_EQ_L %d0, 0x00000303

    | ------------------------------------------------------------------
    CHECK   9                       | recursion: the stack as working memory
    | ------------------------------------------------------------------
    movea.l %sp,%a5
    moveq   #10,%d0
    bsr     fib
    EXPECT_EQ_L %d0, 55             | fib(10)
    cmpa.l  %a5,%sp
    bne     fail

    | ------------------------------------------------------------------
    CHECK   10                      | a block copy, sixteen bytes at a time
    | ------------------------------------------------------------------
    lea     numbers,%a0
    lea     scratch,%a1
    move.w  #4,%d1                  | five passes of two longs
2:  movem.l (%a0)+,%d2-%d3
    movem.l %d2-%d3,(%a1)
    lea     8(%a1),%a1
    dbf     %d1,2b
    lea     numbers,%a0
    lea     scratch,%a1
    move.w  #9,%d1
3:  move.l  (%a0)+,%d0
    cmp.l   (%a1)+,%d0
    bne     fail
    dbf     %d1,3b

    | ------------------------------------------------------------------
    CHECK   11                      | condition codes across a call
    | ------------------------------------------------------------------
    moveq   #5,%d0
    sub.l   #5,%d0                  | Z set
    bsr     no_flags                | ... and the callee must not disturb it
    beq     4f
    bra     fail
4:

    bra     pass

| ---------------------------------------------------------------------------
| Subroutines
| ---------------------------------------------------------------------------
add_one:
    addq.l  #1,%d0
    rts

depth3:
    addq.l  #1,%d0
    bsr     depth2
    rts
depth2:
    addq.l  #1,%d0
    bsr     depth1
    rts
depth1:
    addq.l  #1,%d0
    rts

| A frame with two longs of locals, used and then given back.
frame_user:
    link    %a6,#-8
    move.l  %d0,-4(%a6)
    move.l  #1,-8(%a6)
    move.l  -4(%a6),%d0
    add.l   -8(%a6),%d0
    unlk    %a6
    rts

| Writes rubbish everywhere, having promised not to.
clobber_all:
    movem.l %d2-%d6/%a2-%a4,-(%sp)
    moveq   #-1,%d2
    moveq   #-1,%d3
    moveq   #-1,%d4
    moveq   #-1,%d5
    moveq   #-1,%d6
    movea.l #0xDEADBEEF,%a2
    movea.l %a2,%a3
    movea.l %a2,%a4
    movem.l (%sp)+,%d2-%d6/%a2-%a4
    rts

| Two long arguments above the return address; RTD takes them away.
sum_two_rtd:
    move.l  4(%sp),%d0
    add.l   8(%sp),%d0
    rtd     #8

| d0 selects an entry; each returns a different value.
dispatch:
    lea     jump_table,%a0
    lsl.l   #2,%d0
    movea.l (%a0,%d0.l),%a1
    jmp     (%a1)
entry0:
    move.l  #0x00000101,%d0
    rts
entry1:
    move.l  #0x00000202,%d0
    rts
entry2:
    move.l  #0x00000303,%d0
    rts

| fib(n) in d0, the slow way, so that the stack does the remembering.
fib:
    cmpi.l  #2,%d0
    bge     1f
    rts                             | fib(0)=0, fib(1)=1
1:  move.l  %d0,-(%sp)
    subq.l  #1,%d0
    bsr     fib                     | fib(n-1)
    move.l  (%sp),%d1
    move.l  %d0,(%sp)               | keep it where n was
    move.l  %d1,%d0
    subq.l  #2,%d0
    bsr     fib                     | fib(n-2)
    add.l   (%sp)+,%d0
    rts

| Touches nothing that carries a condition code out.
no_flags:
    movea.l %sp,%a0
    movea.l %a0,%a1
    rts

| ---------------------------------------------------------------------------
| Handlers: none of these should ever run.
| ---------------------------------------------------------------------------
    UNEXPECTED_HANDLER
    .globl  v_bus, v_addr, v_illegal, v_divzero, v_chk, v_trapv
    .globl  v_priv, v_trace, v_linea, v_linef, v_format, v_trap, v_irq
v_bus     = v_unexpected
v_addr    = v_unexpected
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
    .data
    .align  2
jump_table:
    .long   entry0, entry1, entry2
numbers:
    .long   1, 2, 3, 4, 5, 6, 7, 8, 9, 10

    .bss
    .align  2
scratch:
    .space  64
