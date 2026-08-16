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
}

# Conditions selectable when seq is COND. Targets must be an even/odd pair.
COND = {
    'NEVER': 0,    # makes seq=COND behave as NEXT; useful as a placeholder
    'CC':    1,    # the condition in ir[11:8], against the CCR
    'SUPER': 2,    # the S bit of SR
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
    'SHIFT': 13, # the shifter's result; `sh` says which of the eight
    'ANDN': 14,  # b & ~a: BCLR
    'ADDX': 15,  # b + a + X
    'SUBX': 16,  # b - a - X
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
    # Compute the address and put it in the output buffer without touching the
    # register. Plain (An) needs this: a read-modify-write prefetches between
    # the read and the write, so the register field naming the address is gone
    # by the time the write happens, and nothing else would have latched it.
    'LATCH': 3,
}

# Which address space. PROG and DATA pick up the S bit of SR at the pin.
FC = {
    'PROG': 0,
    'DATA': 1,
    'CPU':  2,
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
    ('cond',  2,  COND),
    ('asrc',  5,  SRC),
    ('bsrc',  5,  SRC),
    ('alu',   5,  ALU),
    ('dst',   4,  DST),
    ('bus',   3,  BUS),
    ('asel',  4,  ASEL),
    ('aupd',  2,  AUPD),
    ('fc',    2,  FC),
    ('pf',    2,  PF),
    ('rsel',  3,  RSEL),
    ('wsel',  3,  WSEL),
    ('easel', 1,  EASEL),
    ('aeasel', 2, AEASEL),
    ('dhi',   1,  None),   # drive the high half of the data output buffer
    ('size',  2,  SIZE),
    ('ccr',   3,  CCR),
    ('sh',    3,  None),   # {shift kind, left}: see rd68011_shifter
    ('bitimm', 1, None),   # the bit number is in the extension word
    ('shone', 1,  None),   # shift by one, not by the opcode's count: the
                           # memory forms, whose count bits are the addressing
                           # mode
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
    'sh':    0,
    'bitimm': 0,
    'shone': 0,
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


def check():
    """Every encoding has to fit the field it lives in."""
    for name, w, enc in FIELDS:
        if enc is None:
            continue
        for k, v in enc.items():
            if v >= (1 << w):
                raise ValueError('%s.%s = %d does not fit %d bits'
                                 % (name, k, v, w))
