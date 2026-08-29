"""The RD68011 microword: fields, encodings, and the datapath they control.

This file is the single definition of the microcode format. The assembler emits
the field positions and encodings into rtl/gen/rd68011_ucode_pkg.sv, so the RTL
and the microcode can never drift apart -- change a width here and both sides
move together.

THE DATAPATH

Two source buses feed an ALU whose result goes to one destination:

        asrc ---->|
                  | alu |----> dst
        bsrc ---->|

alongside a bus request whose address comes from `asel` and whose function code
comes from `fc`, and a prefetch operation in `pf`.

A microword occupies one clock, except when it asks for a bus cycle, in which
case it occupies the cycle: the sequencer stalls until the bus unit
acknowledges, and the destination write and prefetch operation happen on the
edge that retires it. That is what makes a bus-cycle microword cost four clocks
and an internal one cost a single clock, which is where the instruction timings
come from.

THE PREFETCH PIPE

  ir      the opcode word being executed        (vector prefetch[0])
  irc     the next word, already fetched        (vector prefetch[1])
  pc      the next fetch address
  ir_pc   the address ir was fetched from
  irc_pc  the address irc was fetched from

At an instruction boundary at address A: ir = [A], irc = [A+2], pc = A+4,
ir_pc = A, irc_pc = A+2. tools/harte/model_check.py verifies this against
thousands of reference vectors per opcode.

irc_pc is the base for every displacement the manual measures "from the
extension word": a branch displacement and a (d16,PC) address alike, because in
both cases the word being consumed out of irc is the one the displacement is
relative to.

EFFECTIVE ADDRESSES

The addressing modes are microcode subroutines, one per (mode, size), reached
through a dispatch table indexed by the mode and register fields of whichever
half of the opcode `easel` selects. A subroutine leaves the effective address
in T0 and returns; the caller then reads or writes through T0.

Register-direct modes have no address, so the *caller* is generated in two
shapes -- one that goes through memory and one that goes straight to the
register file. The decoder picks between them by opcode pattern, which keeps
the choice out of the microcode and off the cycle count.
"""

# --------------------------------------------------------------------------
# Field encodings. Each is {name: value}; the assembler emits every one of
# them as a localparam named U_<FIELD>_<NAME>.
# --------------------------------------------------------------------------

# How the next micro-address is chosen.
SEQ = {
    'NEXT':   0,   # the `next` field
    'DECODE': 1,   # the opcode decoder's entry point: end of instruction
    'COND':   2,   # `next`, with bit 0 set if the selected condition holds
    'EACALL': 3,   # call the addressing-mode subroutine; `next` is the return
    'RET':    4,   # return to the saved address
    # Resume a faulted instruction: the micro-address comes from the frame RTE
    # has just reloaded, not from this microword (UM 6.4).
    'RESUME': 5,
}

# Conditions selectable when seq is COND. Targets must be an even/odd pair.
COND = {
    'NEVER': 0,    # makes seq=COND behave as NEXT; useful as a placeholder
    'CC':    1,    # the condition in ir[11:8], against the CCR
    'SUPER': 2,    # the S bit of SR
    # The loop counter of DBcc has run out: the low word of the value being
    # written is all ones, which is what -1 looks like after the decrement.
    'CNT':   3,
    'V':     4,   # the overflow flag alone: TRAPV
    'FMT0':  5,   # the word just read is a format $0 frame header
    'N':     6,   # the negative flag: CHK's two bounds tests
    'RSTB':  7,   # the RESET instruction's output pulse is still running
    'ZERO':  8,   # the value on the way out of the ALU is zero at its size
    'DIVB':  9,   # the divider is still working
    'DIVV': 10,   # the division overflowed
    # MOVEM's register mask still names a register after this microword's
    # `mop`. One condition serves both ends of the loop: entering it at all,
    # and going round again.
    'MASK': 11,
    # MOVEC's extension word names a control register this part has.
    'CRVALID': 12,
    # MOVES's direction bit, which is in its extension word rather than in the
    # opcode, so the microcode has to branch on it (PRM section 6).
    'XWDR': 13,
    'LOOP': 16,   # loop mode is running
    # RTE's two checks on a long frame (UM 6.4): the format code, and the
    # version number stamped in the first of the sixteen internal words.
    'FMT8': 14,
    'VERSION': 15,
}

# Sources onto the A and B buses. Everything is 32 bits wide by the time it
# gets there; the _SX names sign-extend on the way.
SRC = {
    'ZERO':      0,
    'ONE':       1,
    'TWO':       2,
    'FOUR':      3,
    'PC':        4,
    'IR_PC':     5,   # address of the opcode word
    'IRC_PC':    6,   # address of the word in irc -- the displacement base
    'IRC':       7,   # the extension word, zero-extended
    'IRC_SX':    8,   # the extension word, sign-extended
    'IR_SXB':    9,   # the low byte of the opcode, sign-extended: Bcc.B
    'T0':       10,
    'T1':       11,
    'RDATA':    12,   # the word just read, zero-extended
    'RDATA_SX': 13,   # the word just read, sign-extended
    'REG':      14,   # the register file, selected by rsel
    'RDATA_B':  15,   # the byte just read, picked by the address's low bit
    # The index register of a brief extension word (PRM section 2): bit 15
    # picks data or address, bits 14-12 the number, and bit 11 whether the
    # whole register is used or only its sign-extended low word.
    'INDEX':    16,
    'IRC_SXB':  17,   # the displacement byte of a brief extension word
    'DBUF':     18,   # the data output buffer, read back
    # The register in bits 11:9, read alongside the one the mode names:
    # a two-operand instruction needs both in the same microword.
    'REG2':     19,
    # The quick operand of ADDQ/SUBQ: bits 11:9, with zero meaning eight
    # (PRM section 4).
    'QUICK':    20,
    # The shift count: bits 11:9 as an immediate one to eight, or the low six
    # bits of the register those bits name (PRM section 4).
    'SHCNT':    21,
    # A single-bit mask, from the bit number the instruction names: bits 11:9
    # name a register for the dynamic forms, and the extension word carries it
    # for the static ones. The number is taken modulo 32 for a register
    # destination and modulo 8 for a memory one (PRM section 4).
    'BITMASK':  22,
    'SCC':      23,   # all ones if the condition in bits 11:8 holds, else zero
    'BIT7':     24,   # 0x80, the bit TAS sets
    'EAL':      25,   # the address output buffer, read back: LINK needs it
    'SRSAVE':   26,   # the status register as it was when the exception began
    'VBR':      27,
    'VECOFF':   28,   # the vector number times four
    'FMTVEC':   29,   # the frame's format and vector-offset word
    'SR':       30,   # the whole status register
    'CCRVAL':   31,   # its low byte, zero-extended
    'USP':      32,   # the user stack pointer, for MOVE USP
    'IRQVEC':   33,   # the interrupt vector: from the bus, or the autovector
    # The program counter an exception taken at an instruction boundary
    # stacks. Normally the instruction that was about to run, but one taken out
    # of a STOP stacks the instruction after the STOP -- which the pipe never
    # advanced to, because STOP does no prefetch at all. Both the interrupt and
    # the trace path use it, since both can be taken from a stopped processor.
    'IRQPC':    34,
    'DIVRES':   35,   # {remainder, quotient}, as PRM section 4 places them
    # The control register MOVEC's extension word names: SFC, DFC, USP or VBR
    # (PRM section 6). The four-way decode is hardware, so the microcode does
    # not need a branch per register.
    'CREG':     36,
    # The fault machinery. These are what the format $8 frame is built out of,
    # and what RTE reads back to continue a faulted instruction.
    'IR':       37,   # the opcode word, which the frame keeps internally
    'XW':       38,   # the extension-word latch
    'UPC':      39,   # the micro-address the fault interrupted
    'SSW':      40,   # the special status word, UM figure 6-9
    'FAULT':    41,   # the address the faulted access used
    'DIB':      42,   # the data input buffer
    'VERWORD':  43,   # our version number, in bits 10-13, and nothing else
    'FMTVEC8':  44,   # 1000 and the vector offset: the long frame's header
    'FRAMESZ':  45,   # 58, the long frame's size in bytes
    'FRAMEVER': 46,   # 26, the offset of the version word within it
    'MULRES':   47,   # the product, one clock after the microword that started it
    # The address output buffer as it was when the fault happened, which is
    # not what `EAL` holds by the time the frame records it: every word of the
    # frame is written through an `aupd` on the stack pointer, and an `aupd`
    # is what loads `EAL`. So the fault takes a copy and the frame writes
    # that. See `ea_save` in rd68011_seq.sv.
    'EALSAVE':  50,
    # Loop mode (UM appendix A).
    'LOOPIR':   48,   # the one-word instruction the loop is executing
    'LOOPST':   49,   # whether loop mode is running, and which half is next
}

ALU = {
    'A':   0,   # pass the A bus
    'B':   1,   # pass the B bus
    'ADD': 2,   # B + A
    'SUB': 3,   # B - A
    'AND': 4,
    'OR':  5,
    'EOR': 6,
    'NOT': 7,
    # {a[15:0], b[15:0]}: an absolute long address or a long immediate, built
    # from the extension word already in irc and the one being read in this
    # same cycle. Doing it in one step is what keeps the bus cycle order right.
    'CAT': 8,
    'SXW': 9,   # sign-extend the low word to 32 bits: MOVEA.W, EXT.L, ADDA.W
    'SXB': 10,  # sign-extend the low byte to 32 bits: EXT.W
    'SWAP': 11, # exchange the halves of a long: SWAP
    'NOTX': 12, # ones complement, but of the B bus
    # These do not produce a result here: a microword carrying one starts
    # rd68011_mul with whatever is on the two buses, and the microword after it
    # reads MULRES. Keeping the multiplier out of the ALU is worth about ten
    # nanoseconds of clock period -- see rd68011_mul.sv.
    'MULU': 19,  # start b[15:0] * a[15:0], unsigned, to 32 bits
    'MULS': 20,  # the same, signed
    'ABCD': 17,  # decimal b + a + X
    'SBCD': 18,  # decimal b - a - X
    'SHIFT': 13, # the shifter's result; `sh` says which of the eight
    'ANDN': 14,  # b & ~a: BCLR
    'ADDX': 15,  # b + a + X
    'SUBX': 16,  # b - a - X
    # MOVEP assembles a register out of bytes read at alternate addresses,
    # high-order byte first, and takes one apart the same way (PRM section 4).
    'CAT8':  21,  # {b[23:0], a[7:0]}: shift a byte in at the bottom
    'SHR8':  22,  # a >> 8, so the byte wanted lands where a byte write reads
    'SHR16': 23,
    'SHR24': 24,
}

DST = {
    'NONE':    0,
    'PC':      1,
    'T0':      2,
    'T1':      3,
    'T0_SHW':  4,  # T0 <- {T0[15:0], result[15:0]}: a long from two words
    'T1_SHW':  5,
    'REG':     6,  # the register file, merged at the operation's size
    'SR':      7,
    # The data output buffer, which is what a write cycle puts on the bus. A
    # write is always preceded by a microword that loads this, because the bus
    # unit latches the write data at the start of the cycle -- one microword
    # too early for that microword's own ALU result to reach it.
    'DBUF':    8,  # loads all 32 bits; `dhi` picks the half that goes out
    'DBUF_SHW': 11,  # shift a word into the buffer's low half
    'REG_L':  10,  # write the register full width whatever the size says
    'CCR':    12,  # the low byte of the status register only
    # Enter exception processing: keep the old status register where the frame
    # can find it, set the supervisor bit and clear the trace bit, all in one
    # step so that nothing runs in between (UM section 6).
    'SR_EXC': 13,
    'SR_ALL': 14,   # the whole status register, mode bits and all
    # Entering an interrupt: supervisor on, trace off, and the mask raised to
    # the level being serviced (UM section 6).
    'SR_IRQ': 15,
    'USP':    16,   # the user stack pointer, written from supervisor mode
    # Shift a word into the *high* half, for the operands that arrive low word
    # first: a pre-decremented long is read at An-2 before An-4.
    'T0_HIW': 17,
    'T1_HIW': 18,
    'SETV':   19,   # set the overflow flag and change nothing else: DIVU/DIVS
    # The high half of a register, for the operands that arrive a word at a
    # time: MOVEM.L to registers reads the high word first.
    'REG_HIW': 20,
    'CREG':    21,   # the control register MOVEC's extension word names
    # The register at the operation's size if it is a data register, and
    # sign-extended to all 32 bits if it is an address register -- which is
    # what PRM section 6 specifies for MOVES, in those words.
    'REG_AD':  22,
    # The fault machinery's write side: everything the format $8 frame puts
    # back. Each is a register the checkpoint set names -- doc/checkpoint.md.
    'EAL':     23,
    # RTE restores the address output buffer into the same holding register
    # the fault saved it in, not into `EAL` itself: the walk up the frame is
    # made of post-increments on the stack pointer, and every one of them
    # would overwrite `EAL` again before the walk was over. RESUME moves it
    # across at the end.
    'EALSAVE': 37,
    'IR':      24,
    'IRC':     25,
    'IR_PC':   26,
    'IRC_PC':  27,
    'XW':      28,
    'UPCSAVE': 29,   # where RESUME will go
    'DIB':     30,
    'SSW':     31,   # only the rerun flag is kept; the rest is for software
    'SRSAVE':  32,   # RTE's staging for the status register it will restore
    # Drive the bus from this microword's ALU result without writing anything.
    # The frame build needs it: every word it writes comes from a different
    # register, and going through the data output buffer would destroy the one
    # word of it the frame itself has to record.
    'WDATA':   33,
    # Loop mode. LOOPBACK is the whole of what a DBcc does when it goes round
    # again: the looped instruction goes back into ir, and ir_pc back to the
    # address it came from, with nothing fetched (UM appendix A).
    'LOOPBACK': 34,
    'LOOPIR':   35,   # RTE putting a suspended loop back
    'LOOPST':   36,
}

# What a microword does about loop mode -- UM appendix A.
#
# Entering is a two-part decision that the DBcc's own microcode makes as it
# goes: the displacement has to be minus four, which is known where the branch
# target is computed, and the instruction at the target has to be a one-word
# loop mode instruction, which is only known once it has been fetched.
LP = {
    'NONE':  0,
    'CHK':   1,   # remember whether the displacement was minus four
    'ENTER': 2,   # ... and if the instruction just fetched qualifies, loop
    'EXIT':  3,   # stop looping: the microwords after this one prefetch again
}

# The extension-word latch.
#
# An instruction whose extension word outlives the prefetch that replaces irc
# needs somewhere to keep it. MOVEM's register mask is the demanding case --
# it is consumed a register at a time across the whole instruction -- and
# MOVEC and MOVES need theirs to survive one prefetch each.
MOP = {
    'NONE': 0,
    'LOAD': 1,   # from irc, which is where an extension word always is
    'STEP': 2,   # MOVEM: drop the register just transferred
}

# Bus request kinds. These are the values rd68011_pkg::cycle_kind_e uses, so
# the sequencer can pass them straight through to the bus unit.
BUS = {
    'NONE':  7,   # not a cycle_kind_e value: means "no request"
    'READ':  0,
    'WRITE': 1,
    'RMW':   2,
    'IACK':  3,
    'BKPT':  4,
}

# Where the bus address comes from. The _INC2 forms post-increment their
# register by two when the cycle retires, which is what makes a long-word
# transfer two microwords instead of four: the address unit has its own
# incrementer, so the ALU stays free to move the data.
ASEL = {
    'PC':        0,
    'T0':        1,
    'T1':        2,
    'T0_INC2':   3,   # T0, then T0 += 2: the reset sequence's walk
    'T0_PLUS2':  4,   # T0 + 2, unchanged: the second word of a long
    'EA':        5,   # the address register the mode names, with `aupd`
    'EA_PLUS2':  6,   # that register + 2: the second word of a long
    'EAL':       7,   # the latched address of the last `aupd` microword
    'EAL_PLUS2': 8,
    'EA_PLUS4':  9,   # the third word of a six-byte pop: RTR
    'EAL_PLUS4': 10,  # the four-word exception frame is written from the top
    'EAL_PLUS6': 11,
    'EA_PLUS6':  12,  # the fourth word of an eight-byte pop: RTE
    'PC_MINUS2': 13,  # the word already in irc, re-read: MOVE to SR and CCR
    'T0_PLUS4':  14,  # MOVEP walks alternate bytes: T0, T0+2, T0+4, T0+6
    'T0_PLUS6':  15,
    # MOVEM to -(An) walks downward: the address used is T0-2 and T0 follows
    # it, so a long is two of these and lands the register four bytes lower.
    'T0_DEC2':   16,
}

# What a microword does to the address register the mode names.
#
# This is a second write port on the register file, separate from the ALU
# destination, because (An)+ and -(An) have to update the register in the same
# microword that uses it -- the reference vectors give MOVE.W (A0)+,D0 eight
# cycles, which is two bus cycles and nothing else, so there is no spare clock
# to do the update in.
#
# PRE also changes the address used: -(An) addresses An-inc, not An.
#
# The amount is the microword's size, except that a byte access through A7
# moves it by two, because the stack pointer stays even (PRM section 2).
AUPD = {
    'NONE':  0,
    'POST':  1,
    'PRE':   2,
    'POST6': 4,   # advance by six: RTR pops a status word and a long
    'PRE8':  5,   # back by eight: room for a four-word exception frame
    'POST8': 6,   # and forward by eight again: RTE
    # Compute the address and put it in the output buffer without touching the
    # register. Plain (An) needs this: a read-modify-write prefetches between
    # the read and the write, so the register field naming the address is gone
    # by the time the write happens, and nothing else would have latched it.
    'LATCH': 3,
}

# Which address space. PROG and DATA pick up the S bit of SR at the pin.
#
# SFC and DFC are the MC68010's own function code registers, which MOVES uses
# to reach an address space of the program's choosing (PRM section 6): a read
# goes to the space SFC names and a write to the one DFC names.
FC = {
    'PROG': 0,
    'DATA': 1,
    'CPU':  2,
    'SFC':  3,
    'DFC':  4,
}

# The prefetch pipe operation performed as the microword retires.
PF = {
    'NONE':     0,
    'FETCH':    1,   # irc <- read data; irc_pc <- pc; pc <- pc + 2
    'ADV':      2,   # ir <- irc; ir_pc <- irc_pc
    'ADVFETCH': 3,   # both, with ir taking the *old* irc
}

# Register file selection.
#
# EA_* use the mode and register fields of whichever half of the opcode `easel`
# picks; IR9_* use bits 11:9, the "other" register of a register-and-EA
# instruction. EA_ANY is the register the mode itself names: a data register
# for mode 000, an address register for everything else.
RSEL = {
    'NONE':   0,
    'A7':     1,
    'EA_ANY': 2,
    'EA_D':   3,   # force a data register
    'EA_A':   4,   # force an address register
    'IR9_D':  5,
    'IR9_A':  6,
    'MNEXT':  7,   # the register MOVEM's mask names next
    # The register named by the extension word held in the latch: bit 15 picks
    # data or address and bits 14-12 the number. MOVEC and MOVES both put it
    # there, because both consume the word before they use it.
    'XW':     8,
    # The register named by irc itself, for the instructions whose extension
    # word is still there when it is needed: MOVEC never prefetches before it
    # makes its transfer.
    'IRC_X':  9,
}

# Which register a microword *writes*, when that is not the one it reads.
#
# MOVE needs both at once: the source register named by the mode and register
# fields, and the destination register in bits 11:9. SAME means the write goes
# wherever rsel points, which is the common case.
WSEL = {
    'SAME':   0,
    'A7':     1,
    'EA_ANY': 2,
    'EA_D':   3,
    'EA_A':   4,
    'IR9_D':  5,
    'IR9_A':  6,
    'MNEXT':  7,
    'XW':     8,
    'IRC_X':  9,
}

# Which half of the opcode carries the mode and register fields.
#
# MOVE is the awkward one: its destination is bits 11:6 with the two fields
# *swapped*, register in 11:9 and mode in 8:6 (PRM section 4).
EASEL = {
    'SRC': 0,   # ir[5:3] mode, ir[2:0] register
    'DST': 1,   # ir[8:6] mode, ir[11:9] register
}

# The same choice again, for the *address* side. MOVE Dn,(An) needs both at
# once: the source register out of the low half and the destination address
# register out of the high half, in one microword, because the reference gives
# it two bus cycles and no internal ones.
AEASEL = {
    'SRC':  0,
    'DST':  1,
    'SP':   2,   # A7, whatever the opcode says: PEA, LINK, and the stacking
                 # every exception does
}

# Transfer size. BYTE picks its data strobe from the address's low bit rather
# than being told which (UM table 3-1); the microcode never has to know whether
# an address turned out even or odd.
SIZE = {
    'BYTE': 0,
    'WORD': 1,
    'LONG': 2,
}

# Which condition codes a microword updates, and by what rule.
#
# PRM section 4 gives these per instruction; they collapse to a handful of
# rules. X is separate from C throughout: most operations leave it alone.
CCR = {
    'NONE':  0,
    'LOGIC': 1,   # N and Z from the result, V and C cleared, X untouched
    'ARITH': 2,   # N Z V C from the operation, X <- C
    'CMP':   3,   # N Z V C from the operation, X untouched
    'SHIFT': 4,   # N and Z from the result, C and V from the shifter, and X
                  # from C only where the operation writes X at all
    'BIT':   5,   # Z alone, from the bit that was tested, and nothing else
    # As ARITH, but Z is only ever cleared, never set: the extended
    # operations leave it alone when their result is zero so that a
    # multi-precision result reads as zero only if every part of it was
    # (PRM section 4, under ADDX/SUBX/NEGX).
    'ARITHX': 6,
    # N and Z from the A bus rather than from the result. TAS needs it: its
    # flags describe the operand as it was read, and the result it writes back
    # always has bit 7 set (PRM section 4).
    'LOGIC_A': 7,
}

# --------------------------------------------------------------------------
# The microword layout. Order here is the bit order, least significant first.
# --------------------------------------------------------------------------
UADDR_BITS = 13

FIELDS = [
    ('next',  UADDR_BITS, None),
    ('seq',   3,  SEQ),
    ('cond',  5,  COND),
    ('asrc',  6,  SRC),
    ('bsrc',  6,  SRC),
    ('alu',   5,  ALU),
    ('dst',   6,  DST),
    ('bus',   3,  BUS),
    ('asel',  5,  ASEL),
    ('aupd',  3,  AUPD),
    ('fc',    3,  FC),
    ('pf',    2,  PF),
    ('rsel',  4,  RSEL),
    ('wsel',  4,  WSEL),
    ('easel', 1,  EASEL),
    ('aeasel', 2, AEASEL),
    ('dhi',   1,  None),   # drive the high half of the data output buffer
    ('size',  2,  SIZE),
    ('ccr',   3,  CCR),
    ('rstreq', 1, None),   # start the RESET instruction's output pulse
    ('stop',   1, None),   # stop until an interrupt arrives
    ('divst',  1, None),   # start the divider
    ('divsg',  1, None),   # ... signed
    ('vec',   8,  None),   # a constant vector number
    ('vsel',  2,  None),   # 0 constant, 1 TRAP's own number, 2 the interrupt
    ('sh',    3,  None),   # {shift kind, left}: see rd68011_shifter
    ('bitimm', 1, None),   # the bit number is in the extension word
    ('shone', 1,  None),   # shift by one, not by the opcode's count: the
                           # memory forms, whose count bits are the addressing
                           # mode
    ('mop',   2,  MOP),
    ('mdown', 1,  None),   # MOVEM to -(An) takes the mask the other way round:
                           # bit 0 is A7 rather than D0 (PRM section 4)
    ('hb',    1,  None),   # the special status word's high-byte flag: this
                           # transfer is the high byte of its half of the
                           # register, which only MOVEP ever produces
    ('g0',    1,  None),   # enter group 0 processing: a fault from here on is
                           # a double bus fault. RTE sets it once it has
                           # committed to reloading a long frame (UM 6.4).
    ('notrace', 1, None), # this exception is one the instruction did not
                           # survive: illegal, unimplemented or privileged. UM
                           # 6.3.8 says a trace exception does not follow those,
                           # because the instruction was never executed.
    ('lp',    2,  LP),     # loop mode: what this microword does about it
]

# Defaults for a microword that does nothing but move to the next address.
DEFAULTS = {
    'next':  0,
    'seq':   SEQ['NEXT'],
    'cond':  COND['NEVER'],
    'asrc':  SRC['ZERO'],
    'bsrc':  SRC['ZERO'],
    'alu':   ALU['A'],
    'dst':   DST['NONE'],
    'bus':   BUS['NONE'],
    'asel':  ASEL['PC'],
    'aupd':  AUPD['NONE'],
    'fc':    FC['PROG'],
    'pf':    PF['NONE'],
    'rsel':  RSEL['NONE'],
    'wsel':  WSEL['SAME'],
    'easel': EASEL['SRC'],
    'aeasel': AEASEL['SRC'],
    'dhi':   0,
    'size':  SIZE['WORD'],
    'ccr':   CCR['NONE'],
    'rstreq': 0,
    'stop':  0,
    'divst': 0,
    'divsg': 0,
    'vec':   0,
    'vsel':  0,
    'sh':    0,
    'bitimm': 0,
    'shone': 0,
    'mop':   MOP['NONE'],
    'mdown': 0,
    'hb':    0,
    'g0':    0,
    'notrace': 0,
    'lp':    LP['NONE'],
}

# The addressing-mode dispatch index: the mode field, except that mode 7 uses
# its register field to pick between five sub-modes (PRM section 2).
EA_MODES = [
    ('DN',      0),   # Dn
    ('AN',      1),   # An
    ('AIND',    2),   # (An)
    ('APOST',   3),   # (An)+
    ('APRE',    4),   # -(An)
    ('ADISP',   5),   # (d16,An)
    ('AIDX',    6),   # (d8,An,Xn)
    ('ABSW',    8),   # (xxx).W        mode 7 reg 0
    ('ABSL',    9),   # (xxx).L        mode 7 reg 1
    ('PCDISP', 10),   # (d16,PC)       mode 7 reg 2
    ('PCIDX',  11),   # (d8,PC,Xn)     mode 7 reg 3
    ('IMM',    12),   # #imm           mode 7 reg 4
]
EA_INDEX_BITS = 4


def width():
    return sum(w for _, w, _ in FIELDS)


def lsb(name):
    p = 0
    for n, w, _ in FIELDS:
        if n == name:
            return p
        p += w
    raise KeyError(name)


def field_width(name):
    for n, w, _ in FIELDS:
        if n == name:
            return w
    raise KeyError(name)


# --------------------------------------------------------------------------
# The request preview
#
# The bus request the processor presents has to come from the microword that
# will be current *after* the coming edge, because the bus unit latches it on
# the edge that ends the current cycle. That means reading the microcode store
# at an address the sequencer has only just computed -- and with a conditional
# microword, that address depends on the ALU, which depends on read data. The
# whole chain is inside half a clock, and it is what limits this design's
# frequency.
#
# So the second read is of a store of its own, holding only the fields a
# request is built from: a fifth of the width, and a fifth of the logic. Two of
# its bits are not fields at all but answers computed here, because what the
# request needs from them is one bit each rather than the six the field holds.
#
# The order here is the bit order, least significant first, as with FIELDS.
REQ_FIELDS = [
    ('bus',    3, BUS),
    ('asel',   5, ASEL),
    ('fc',     3, FC),
    ('size',   2, SIZE),
    ('aupd',   3, AUPD),
    ('aeasel', 2, AEASEL),
    ('hb',     1, None),   # the special status word's high-byte flag
    # Derived: does the microword consume the data this cycle reads, and does
    # it load the instruction input buffer? The special status word's DF and IF
    # bits, which are otherwise twelve and two bits of source and prefetch
    # encoding that nothing else here would look at.
    ('rdsrc',  1, None),
    ('pffet',  1, None),
]


def req_width():
    return sum(w for _, w, _ in REQ_FIELDS)


# The successors' previews, carried in the microword itself.
#
# The bus request has to be presented from the microword that will be current
# after the coming edge, and the sequencer only knows which that is at the end
# of the current one -- when the bus cycle terminates, the condition resolves
# and any fault is known. Reading a store at an address computed from all that
# is the obvious arrangement, and doc/critical-path.md measures what it costs.
#
# But the *candidates* are all known a whole clock in advance. A microword has
# at most two successors of its own -- `next`, and `next|1` when the condition
# holds -- so it can simply carry both of their previews. What is left for the
# late signals is choosing between answers already in hand.
#
# Appended here rather than written into FIELDS above because the width is
# req_width(), which is not known until REQ_FIELDS has been read.
FIELDS += [
    ('rq0', req_width(), None),   # the preview of `next`
    ('rq1', req_width(), None),   # ... and of `next|1`, for a COND microword
]
DEFAULTS['rq0'] = 0
DEFAULTS['rq1'] = 0

# Which conditions can decide what the bus does next.
#
# A conditional microword only steers the bus if its two successors present
# *different* requests. Comparing them across the whole microprogram, exactly
# one condition ever does: MOVEM's register mask, which decides whether there
# is another transfer to make. Every other conditional branch -- including all
# forty-six that branch on an ALU flag -- has both arms presenting the same
# request, so the condition cannot reach the bus through them at all.
#
# That is why rd68011_seq.sv selects the preview on the mask test rather than
# on `cond_true`, and it is what keeps the ALU, the shifter, the divider and
# the multiplier out of the bus request's fan-in. `xw_after` is built from the
# `xw` and `irc` registers and nothing else.
#
# This list is what the RTL implements. assemble.py compares it against what
# the microprogram actually needs and fails the build if they disagree, because
# the two have to be changed together: a microword that needs some other
# condition to steer a request would otherwise present the wrong address on the
# pins, silently.
BUS_STEERING_CONDS = ('MASK',)


def req_lsb(name):
    p = 0
    for n, w, _ in REQ_FIELDS:
        if n == name:
            return p
        p += w
    raise KeyError(name)


def req_word(fields):
    """The request preview of one microword, from its fields."""
    val = 0
    for name, w, _ in REQ_FIELDS:
        if name == 'rdsrc':
            v = int(fields.get('asrc', DEFAULTS['asrc']) in RDATA_SOURCES or
                    fields.get('bsrc', DEFAULTS['bsrc']) in RDATA_SOURCES)
        elif name == 'pffet':
            v = int(fields.get('pf', DEFAULTS['pf']) in
                    (PF['FETCH'], PF['ADVFETCH']))
        else:
            v = fields.get(name, DEFAULTS[name])
        if v >= (1 << w):
            raise ValueError('request field %s = %d does not fit %d bits'
                             % (name, v, w))
        val |= v << req_lsb(name)
    return val


RDATA_SOURCES = (SRC['RDATA'], SRC['RDATA_SX'], SRC['RDATA_B'])


def check():
    """Every encoding has to fit the field it lives in."""
    for name, w, enc in FIELDS:
        if enc is None:
            continue
        for k, v in enc.items():
            if v >= (1 << w):
                raise ValueError('%s.%s = %d does not fit %d bits'
                                 % (name, k, v, w))
    # The request preview copies its fields, so its widths have to match.
    for name, w, _ in REQ_FIELDS:
        if name in ('rdsrc', 'pffet'):
            continue
        if field_width(name) != w:
            raise ValueError('request field %s is %d bits and the microword '
                             'has %d' % (name, w, field_width(name)))
