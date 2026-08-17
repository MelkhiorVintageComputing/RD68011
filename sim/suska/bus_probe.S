| A short program whose bus cycles are the point.
|
| Run on both this design and the Suska WF68K10 so that the two transaction
| lists can be compared -- which addresses, in which order, read or written, in
| which address space. Deliberately plain: no interrupts, no exceptions, no
| loop mode, nothing where Suska is known to go its own way.
|
| doc/suska-crosscheck.md has what came of it.

    .section .vectors,"a"
    .long   0x00000800              | initial supervisor stack pointer
    .long   0x00000100              | initial program counter

    .text
    .globl  _start
_start:
    move.w  #0x1234,%d0             | an immediate, so two program reads
    movea.l #0x00000200,%a0
    move.w  %d0,(%a0)               | a word write
    move.b  #0x5A,2(%a0)            | a byte write with a displacement
    move.l  (%a0),%d1               | a long read, two cycles
    movea.l #0x00000300,%a1
    move.l  %d1,(%a1)+              | a long write, two cycles
    tst.w   (%a0)

    | A block copy: post-increment reads, pre-decrement writes, and enough of
    | them that the two transaction lists have something to disagree about.
    movea.l #0x00000400,%a2
    movea.l #0x00000500,%a3
    move.w  #15,%d2
1:  move.w  (%a2)+,(%a3)+
    dbf     %d2,1b

    movea.l #0x00000600,%a4
    move.w  #7,%d2
2:  move.l  -(%a4),%d3
    add.l   %d3,%d4
    dbf     %d2,2b

    | And the stack, which is a different addressing mode again.
    move.w  #5,%d2
3:  move.l  %d4,-(%sp)
    move.l  (%sp)+,%d5
    dbf     %d2,3b

    bra     .
