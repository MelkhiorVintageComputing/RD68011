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
}

# Conditions selectable when seq is COND. Targets must be an even/odd pair.
COND = {
    'NEVER': 0,    # makes seq=COND behave as NEXT; useful as a placeholder
    'CC':    1,    # the Bcc condition in ir[11:8], against the CCR
    'SUPER': 2,    # the S bit of SR
}

# Sources onto the A and B buses. Everything is 32 bits wide by the time it
# gets there; the _SX names sign-extend on the way.
SRC = {
    'ZERO':     0,
    'ONE':      1,
    'TWO':      2,
    'FOUR':     3,
    'PC':       4,
    'IR_PC':    5,   # address of the opcode word
    'IRC_PC':   6,   # address of the word in irc -- the displacement base
    'IRC':      7,   # the extension word, zero-extended
    'IRC_SX':   8,   # the extension word, sign-extended
    'IR_SXB':   9,   # the low byte of the opcode, sign-extended: Bcc.B
    'T0':      10,
    'T1':      11,
    'RDATA':   12,   # the word just read, zero-extended
    'RDATA_SX': 13,  # the word just read, sign-extended
    'REG':     14,   # the register file, selected by rsel
}

ALU = {
    'A':   0,   # pass the A bus
    'B':   1,   # pass the B bus
    'ADD': 2,
    'SUB': 3,   # A - B
}

DST = {
    'NONE':  0,
    'PC':    1,
    'T0':    2,
    'T1':    3,
    'T0_SHW': 4,  # T0 <- {T0[15:0], result[15:0]}: assembling a long from words
    'T1_SHW': 5,
    'REG':   6,   # the register file, selected by rsel
    'SR':    7,
    # The data output buffer, which is what a write cycle puts on the bus. A
    # write is always preceded by a microword that loads this, because the bus
    # unit latches the write data at the start of the cycle -- one microword
    # too early for that microword's own ALU result to reach it.
    'DBUF':  8,
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
    'PC':      0,
    'T0':      1,
    'T1':      2,
    'T0_INC2': 3,
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

# Register file selection. Fixed registers only for now; selecting from the
# opcode's register fields arrives with the addressing modes in P3.
RSEL = {
    'NONE': 0,
    'A7':   1,
}

# Transfer size for a bus cycle.
SIZE = {
    'WORD': 0,
    'BYTE_U': 1,   # upper byte: UDS only
    'BYTE_L': 2,   # lower byte: LDS only
}

# --------------------------------------------------------------------------
# The microword layout. Order here is the bit order, least significant first.
# --------------------------------------------------------------------------
UADDR_BITS = 8

FIELDS = [
    ('next', UADDR_BITS, None),
    ('seq',  2,  SEQ),
    ('cond', 2,  COND),
    ('asrc', 4,  SRC),
    ('bsrc', 4,  SRC),
    ('alu',  2,  ALU),
    ('dst',  4,  DST),
    ('bus',  3,  BUS),
    ('asel', 2,  ASEL),
    ('fc',   2,  FC),
    ('pf',   2,  PF),
    ('rsel', 2,  RSEL),
    ('size', 2,  SIZE),
]

# Defaults for a microword that does nothing but move to the next address.
DEFAULTS = {
    'next': 0,
    'seq':  SEQ['NEXT'],
    'cond': COND['NEVER'],
    'asrc': SRC['ZERO'],
    'bsrc': SRC['ZERO'],
    'alu':  ALU['A'],
    'dst':  DST['NONE'],
    'bus':  BUS['NONE'],
    'asel': ASEL['PC'],
    'fc':   FC['PROG'],
    'pf':   PF['NONE'],
    'rsel': RSEL['NONE'],
    'size': SIZE['WORD'],
}


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
