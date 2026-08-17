| p05_stress -- arithmetic in long chains, for the co-simulation to chew on.
|
| The reference vectors test each instruction exhaustively and in isolation:
| thousands of operand sets per opcode, every one from a fabricated register
| state. What they cannot test is a *chain* -- an X flag carried through eight
| ADDX instructions, a BCD digit corrected and then corrected again, a quotient
| fed straight back in as the next dividend. Each link is checked; the chain is
| not.
|
| So this is a chain, driven by a pseudo-random sequence so the operands are not
| ones anybody chose, and it exists mostly to be run against Musashi by
| `make cosim`, which compares every register after every instruction. The
| checksum at the end is a regression check on top of that: its value came from
| the oracle, so it is the two implementations agreeing written down.

    .include "rd68011.inc"

    .equ    ROUNDS, 300

    VECTORS
    RESULT_BLOCK

    .text
    .globl  _start
_start:
    PROGRAM_BEGIN

    | ------------------------------------------------------------------
    CHECK   1                       | the chain
    | ------------------------------------------------------------------
    move.l  #0x1D872B41,seed
    moveq   #0,%d6                  | the checksum
    move.w  #ROUNDS-1,%d5

round:
    bsr     rand                    | a fresh 32 bits in d0

    | -- the ALU group, at all three sizes, with the flags carried along ---
    move.l  %d0,%d1
    add.b   %d0,%d1
    add.w   %d0,%d1
    add.l   %d0,%d1
    eor.l   %d1,%d6
    sub.b   %d0,%d1
    sub.w   %d0,%d1
    sub.l   %d0,%d1
    and.l   %d0,%d1
    or.w    %d0,%d1
    eor.b   %d0,%d1
    eor.l   %d1,%d6
    not.l   %d1
    neg.w   %d1
    negx.l  %d1                     | ... and NEGX picks up X from the NEG
    eor.l   %d1,%d6

    | -- multi-precision: eight words of it, so X has somewhere to go -----
    lea     acc,%a0
    lea     src,%a1
    move.l  %d0,(%a1)
    move.l  %d0,4(%a1)
    lsr.l   #3,%d0
    move.l  %d0,8(%a1)
    move.l  %d0,12(%a1)
    lea     16(%a0),%a0
    lea     16(%a1),%a1
    moveq   #3,%d2
    andi.w  #0xFFEF,%sr             | X clear to start
1:  subx.l  -(%a1),-(%a0)
    dbf     %d2,1b
    lea     acc,%a0
    move.l  (%a0)+,%d3
    eor.l   %d3,%d6
    move.l  (%a0)+,%d3
    eor.l   %d3,%d6

    | -- decimal, where the corrections chain across bytes ---------------
    | PRM section 4 leaves N and V undefined for all three of these, so the
    | mask after each one stops an undefined bit being carried into the next
    | instruction -- and into the co-simulation, where two implementations are
    | entitled to disagree about it. X, Z and C are defined and are kept.
    lea     bcd_a+4,%a0
    lea     bcd_b+4,%a1
    | Valid BCD digits, because that is what the instruction is for. The
    | behaviour on digits that are not valid BCD is real and is checked --
    | 161 such cases are in the reference vectors and this design matches all
    | of them -- but Musashi does not, so feeding it invalid digits here would
    | be comparing two answers to a question the manual does not ask. See
    | doc/divergences.md.
    move.l  %d0,%d3
    andi.l  #0x99999999,%d3
    move.l  %d3,bcd_a
    move.l  %d1,%d3
    andi.l  #0x77777777,%d3
    move.l  %d3,bcd_b
    moveq   #3,%d2
    andi.w  #0xFFEF,%sr
2:  abcd    -(%a1),-(%a0)
    andi.b  #0x15,%ccr              | keep X, Z and C; N and V are undefined
    dbf     %d2,2b
    move.l  bcd_a,%d3
    eor.l   %d3,%d6
    lea     bcd_a+4,%a0
    lea     bcd_b+4,%a1
    moveq   #3,%d2
3:  sbcd    -(%a1),-(%a0)
    andi.b  #0x15,%ccr
    dbf     %d2,3b
    move.l  bcd_a,%d3
    eor.l   %d3,%d6
    andi.l  #0x99999999,%d3
    nbcd    %d3
    andi.b  #0x15,%ccr
    eor.l   %d3,%d6

    | -- multiply and divide, feeding each other -------------------------
    move.l  %d0,%d2
    andi.l  #0x0000FFFF,%d2
    move.l  %d0,%d3
    swap    %d3
    andi.l  #0x0000FFFF,%d3
    ori.l   #1,%d3                  | never zero
    move.l  %d2,%d4
    mulu.w  %d3,%d4
    eor.l   %d4,%d6
    move.l  %d2,%d4
    muls.w  %d3,%d4
    eor.l   %d4,%d6
    | A dividend that cannot overflow a sixteen-bit quotient: on overflow PRM
    | leaves N and Z undefined, and the exhaustive check of that path is the
    | reference vectors' job rather than this program's.
    move.l  %d0,%d4
    andi.l  #0x0000FFFF,%d4
    divu.w  %d3,%d4
    eor.l   %d4,%d6
    move.l  %d0,%d4
    andi.l  #0x00007FFF,%d4
    divs.w  %d3,%d4
    eor.l   %d4,%d6

    | -- shifts and rotates, at counts taken from the data ---------------
    moveq   #7,%d2
    and.l   %d0,%d2
    addq.l  #1,%d2                  | one to eight
    move.l  %d0,%d4
    asl.l   %d2,%d4
    eor.l   %d4,%d6
    asr.l   %d2,%d4
    lsl.w   %d2,%d4
    lsr.b   %d2,%d4
    eor.l   %d4,%d6
    rol.l   %d2,%d4
    ror.w   %d2,%d4
    roxl.l  %d2,%d4                 | ... and these two carry X through
    roxr.b  %d2,%d4
    eor.l   %d4,%d6

    | -- bits, and the flags they leave ----------------------------------
    moveq   #31,%d2
    and.l   %d0,%d2
    btst    %d2,%d4
    bchg    %d2,%d4
    bclr    %d2,%d4
    bset    %d2,%d4
    eor.l   %d4,%d6
    ext.w   %d4
    ext.l   %d4
    swap    %d4
    eor.l   %d4,%d6

    | -- a memory read-modify-write and a byte walk ----------------------
    lea     acc,%a0
    tas     (%a0)
    move.b  (%a0),%d3
    andi.l  #0xFF,%d3
    eor.l   %d3,%d6
    lea     src,%a0
    lea     src+8,%a1
    cmpm.l  (%a0)+,(%a1)+
    move.w  %ccr,%d3
    andi.l  #0x1F,%d3
    eor.l   %d3,%d6

    | -- and a peripheral-shaped transfer --------------------------------
    lea     port,%a0
    movep.l %d0,0(%a0)
    movep.l 0(%a0),%d3
    eor.l   %d3,%d6

    dbf     %d5,round

    move.l  %d6,checksum
    EXPECT_EQ_L %d6, 0x70845114
    bra     pass

| xorshift32: a fresh 32 bits in d0, and nothing else touched but d1.
rand:
    move.l  seed,%d0
    move.l  %d0,%d1
    lsl.l   #7,%d1
    eor.l   %d1,%d0
    move.l  %d0,%d1
    lsr.l   #7,%d1
    eor.l   %d1,%d0
    move.l  %d0,%d1
    lsl.l   #5,%d1
    eor.l   %d1,%d0
    move.l  %d0,seed
    rts

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
    .bss
    .align  2
seed:     .space  4
checksum: .space  4
acc:      .space  16
src:      .space  16
bcd_a:    .space  8
bcd_b:    .space  8
port:     .space  16
