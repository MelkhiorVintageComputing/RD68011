| p07_loops -- loops of every shape the loop buffer can and cannot take.
|
| The buffer is a fetch optimisation and nothing else: with LOOP_BUF_WORDS set
| the processor must compute exactly what it computes without it, and only the
| bus should differ. So this program says nothing about the buffer at all. It
| is a set of loops with answers, and the whole test is that the answers do not
| move -- `make loopbuf` runs it both ways and compares the checks and the
| clocks.
|
| The shapes are chosen for what they do to the window rather than for what
| they compute: a body with an extension word in it, which loop mode proper can
| never hold; a body several instructions long, which it can never hold either;
| a Bcc closing the loop instead of a DBcc; a branch inside the body; loops
| nested two deep; a loop that writes into its own window; and one long enough
| that no window will hold it.

    .include "rd68011.inc"

    .equ    N, 32                   | words in the arrays

    VECTORS
    RESULT_BLOCK

    .text
    .globl  _start
_start:
    PROGRAM_BEGIN

    bsr     init                    | src[i] = 0x1100 + i

    | ------------------------------------------------------------------
    CHECK   1                       | three instructions, one with an
    | ------------------------------------------------------------------
    |                               | extension word
    lea     src,%a0
    lea     dst,%a1
    moveq   #0,%d2
    move.w  #N-1,%d0
1:  move.w  (%a0)+,%d1
    addi.w  #1,%d1                  | two words: the immediate is in the window
    add.w   %d1,%d2
    move.w  %d1,(%a1)+
    dbf     %d0,1b
    EXPECT_EQ_W %d2, 0x2210         | sum of 0x1101..0x1120
    move.w  dst,%d3
    EXPECT_EQ_W %d3, 0x1101
    move.w  dst+2*(N-1),%d3
    EXPECT_EQ_W %d3, 0x1120

    | ------------------------------------------------------------------
    CHECK   2                       | indexed addressing inside the loop
    | ------------------------------------------------------------------
    lea     src,%a0
    moveq   #0,%d2
    moveq   #0,%d3
    move.w  #N-1,%d0
2:  move.w  0(%a0,%d3.w),%d1        | a full extension word, every trip
    add.w   %d1,%d2
    addq.w  #2,%d3
    dbf     %d0,2b
    EXPECT_EQ_W %d2, 0x21F0         | sum of 0x1100..0x111F

    | ------------------------------------------------------------------
    CHECK   3                       | a Bcc closes the loop, not a DBcc
    | ------------------------------------------------------------------
    lea     src,%a0
    moveq   #0,%d2
    move.w  #N,%d0
3:  move.w  (%a0)+,%d1
    add.w   %d1,%d2
    subq.w  #1,%d0
    bne     3b
    EXPECT_EQ_W %d2, 0x21F0

    | ------------------------------------------------------------------
    CHECK   4                       | a branch inside the body
    | ------------------------------------------------------------------
    lea     src,%a0
    moveq   #0,%d2
    move.w  #N-1,%d0
24:  move.w  (%a0)+,%d1
    btst    #0,%d1                  | odd words counted twice, even words once
    beq     25f
    add.w   %d1,%d2
25:  add.w   %d1,%d2
    dbf     %d0,24b
    EXPECT_EQ_W %d2, 0x32F0

    | ------------------------------------------------------------------
    CHECK   5                       | nested two deep
    | ------------------------------------------------------------------
    moveq   #0,%d2
    move.w  #7,%d0
26:  move.w  #3,%d1
27:  addq.w  #1,%d2
    dbf     %d1,27b
    dbf     %d0,26b
    EXPECT_EQ_W %d2, 32             | 8 outer, 4 inner

    | ------------------------------------------------------------------
    CHECK   6                       | the loop writes inside its own window
    | ------------------------------------------------------------------
    | `hole` sits in the middle of the code, a few words past the loop, so
    | every store lands in whatever window the loop armed. Nothing about the
    | instructions changes; the processor cannot know that.
    lea     hole,%a1
    moveq   #0,%d2
    move.w  #7,%d0
28:  move.w  %d0,(%a1)
    add.w   %d0,%d2
    dbf     %d0,28b
    EXPECT_EQ_W %d2, 28             | 7+6+...+0
    move.w  hole,%d3
    EXPECT_EQ_W %d3, 0
    bra     past_hole
hole:
    .space  16
past_hole:

    | ------------------------------------------------------------------
    CHECK   7                       | supervisor and back, twice a trip
    | ------------------------------------------------------------------
    | A TRAP in the body changes the S bit going in and coming out, and the
    | address space a program fetch is made in with it, so the window is
    | emptied twice every trip. The answer must not care.
    moveq   #0,%d2
    move.w  #7,%d0
29:  addq.w  #1,%d2
    trap    #3
    add.w   %d0,%d2
    dbf     %d0,29b
    EXPECT_EQ_W %d2, 36             | 8 + (7+6+...+0)

    | ------------------------------------------------------------------
    CHECK   8                       | too long for any window we build
    | ------------------------------------------------------------------
    lea     src,%a0
    moveq   #0,%d2
    move.w  #7,%d0
30: move.w  (%a0)+,%d1
    .rept   40
    nop
    .endr
    add.w   %d1,%d2
    dbf     %d0,30b
    EXPECT_EQ_W %d2, 0x881C         | sum of 0x1100..0x1107

    bra     pass

| ---------------------------------------------------------------------------
| src[i] = 0x1100 + i, and dst cleared.
| ---------------------------------------------------------------------------
init:
    lea     src,%a0
    lea     dst,%a1
    move.w  #0x1100,%d1
    move.w  #N-1,%d0
1:  move.w  %d1,(%a0)+
    addq.w  #1,%d1
    clr.w   (%a1)+
    dbf     %d0,1b
    rts

| ---------------------------------------------------------------------------
| Handlers. TRAP #3 is the only one check 9 wants; the rest fail the run.
| ---------------------------------------------------------------------------
    .globl  v_trap
v_trap:
    rte

    UNEXPECTED_HANDLER
    .globl  v_bus, v_addr, v_illegal, v_divzero, v_chk, v_trapv
    .globl  v_priv, v_trace, v_linea, v_linef, v_format, v_irq
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
v_irq     = v_unexpected

    PROGRAM_END

| ---------------------------------------------------------------------------
    .bss
    .align  2
src:
    .space  2*N
dst:
    .space  2*N
