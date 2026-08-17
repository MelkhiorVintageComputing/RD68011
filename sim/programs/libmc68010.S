| libmc68010 -- the arithmetic gcc assumes somebody else has written.
|
| An MC68010 multiplies 16 by 16 and divides 32 by 16, and that is all. Every
| 32-by-32 multiply and 32-by-32 divide in a C program is a call to one of
| these, and the compiler emits the call whether or not anything defines it.
|
| The libgcc that ships with m68k-linux-gnu cannot be used here: there is no
| 68010 multilib, so the only libgcc is built for a 68020 and contains
| instructions this part does not have. Linking it produced BSR.L -- opcode
| $61FF, which on an MC68010 is a byte branch of minus one and therefore an
| address error, which is exactly what the core reported. So the handful of
| helpers a freestanding program needs are written out here instead, in
| instructions the part actually has.
|
| The calling convention is gcc's: arguments on the stack, result in d0, and
| d0/d1/a0/a1 free for the callee to use.

    .text

| ---------------------------------------------------------------------------
| __mulsi3(a, b) -- 32 by 32 into 32
|
| (ah:al) * (bh:bl), keeping 32 bits, is al*bl plus the low half of
| (ah*bl + al*bh) shifted up by sixteen. The high halves never meet, because
| their product is entirely above the result.
| ---------------------------------------------------------------------------
    .globl  __mulsi3
__mulsi3:
    movem.l %d2-%d4,-(%sp)
    move.l  16(%sp),%d0             | a
    move.l  20(%sp),%d1             | b
    move.l  %d0,%d2
    swap    %d2                     | d2.w = ah
    move.l  %d1,%d3
    swap    %d3                     | d3.w = bh
    move.w  %d0,%d4
    mulu.w  %d1,%d4                 | al * bl, all 32 bits of it
    mulu.w  %d1,%d2                 | ah * bl
    mulu.w  %d0,%d3                 | al * bh
    add.w   %d3,%d2                 | only the low half survives the shift
    swap    %d2
    clr.w   %d2                     | ... which is what this is
    add.l   %d2,%d4
    move.l  %d4,%d0
    movem.l (%sp)+,%d2-%d4
    rts

| ---------------------------------------------------------------------------
| The unsigned divide everything else is built on.
|
| In:  d0 dividend, d1 divisor.  Out: d0 quotient, d2 remainder.
| Shift and subtract, thirty-two times, with the dividend and the quotient
| sharing a register: each shift moves a dividend bit out of the top and a
| quotient bit into the bottom.
| ---------------------------------------------------------------------------
udivmod:
    moveq   #0,%d2                  | remainder
    moveq   #31,%d3
1:  add.l   %d0,%d0                 | dividend left; the bit that leaves is X
    addx.l  %d2,%d2                 | ... and arrives at the bottom of the
                                    |     remainder
    cmp.l   %d1,%d2
    bcs     2f                      | it did not fit
    sub.l   %d1,%d2
    addq.l  #1,%d0                  | ... so the quotient bit is a one
2:  dbf     %d3,1b
    rts

    .globl  __udivsi3
__udivsi3:
    movem.l %d2-%d3,-(%sp)
    move.l  12(%sp),%d0
    move.l  16(%sp),%d1
    bsr     udivmod
    movem.l (%sp)+,%d2-%d3
    rts

    .globl  __umodsi3
__umodsi3:
    movem.l %d2-%d3,-(%sp)
    move.l  12(%sp),%d0
    move.l  16(%sp),%d1
    bsr     udivmod
    move.l  %d2,%d0
    movem.l (%sp)+,%d2-%d3
    rts

| ---------------------------------------------------------------------------
| The signed forms. C requires the quotient to truncate toward zero and the
| remainder to take the dividend's sign, which is the same rule DIVS itself
| follows (PRM section 4) -- so: divide the magnitudes and put the signs back.
| ---------------------------------------------------------------------------
    .globl  __divsi3
__divsi3:
    movem.l %d2-%d4,-(%sp)
    move.l  16(%sp),%d0
    move.l  20(%sp),%d1
    moveq   #0,%d4                  | 0 while the result is positive, -1 not
    tst.l   %d0
    bpl     1f
    neg.l   %d0
    not.l   %d4
1:  tst.l   %d1
    bpl     2f
    neg.l   %d1
    not.l   %d4
2:  bsr     udivmod
    tst.l   %d4
    beq     3f
    neg.l   %d0
3:  movem.l (%sp)+,%d2-%d4
    rts

    .globl  __modsi3
__modsi3:
    movem.l %d2-%d4,-(%sp)
    move.l  16(%sp),%d0
    move.l  20(%sp),%d1
    moveq   #0,%d4                  | the remainder follows the dividend alone
    tst.l   %d0
    bpl     1f
    neg.l   %d0
    not.l   %d4
1:  tst.l   %d1
    bpl     2f
    neg.l   %d1
2:  bsr     udivmod
    move.l  %d2,%d0
    tst.l   %d4
    beq     3f
    neg.l   %d0
3:  movem.l (%sp)+,%d2-%d4
    rts
