"""The RD68011 microcode program, and the opcode patterns that enter it.

Read this alongside isa.py, which defines the fields each line sets.

Cycle counts fall out of the structure: a microword with no bus request costs
one clock, one with a bus request costs the whole bus cycle. So the reference
NOP at four cycles is a single prefetch microword, and Bcc taken at ten cycles
is two internal microwords and two prefetches.
"""

from isa import SEQ, COND, SRC, ALU, DST, BUS, ASEL, FC, PF, RSEL, SIZE

# --------------------------------------------------------------------------
# Assembler state
# --------------------------------------------------------------------------
words = []       # list of (dict-of-fields, source comment)
labels = {}      # name -> micro-address
fixups = []      # (index, field, label)
patterns = []    # (bitpattern, label, mnemonic)
fallthrough = set()   # indices whose next address is simply the one after


def label(name, align_even=False):
    if align_even and len(words) % 2:
        u(comment='padding, so the conditional pair below is aligned')
    if name in labels:
        raise ValueError('duplicate label %s' % name)
    labels[name] = len(words)


def u(comment='', **kw):
    """Emit one microword. Unset fields take their defaults."""
    for k in kw:
        if k not in ('next', 'seq', 'cond', 'asrc', 'bsrc', 'alu', 'dst',
                     'bus', 'asel', 'fc', 'pf', 'rsel', 'size', 'goto'):
            raise KeyError('no microword field %r' % k)
    goto = kw.pop('goto', None)
    if goto is not None:
        fixups.append((len(words), 'next', goto))
    elif 'next' not in kw:
        # No target given: fall through. Making this the default keeps a
        # straight-line sequence readable and stops an unset `next` from
        # silently meaning micro-address zero, which is the reset entry.
        fallthrough.add(len(words))
    words.append((dict(kw), comment))
    return len(words) - 1


def opcode(pattern, target, mnemonic):
    """Map a 16-bit opcode pattern to a microcode entry point.

    The pattern is 16 characters of '0', '1' or '-'. Patterns are tried in the
    order given, so a more specific one must come first -- which is how BRA.W
    (a displacement byte of zero) is told apart from BRA.B without costing a
    microcode branch at run time.
    """
    if len(pattern) != 16 or any(c not in '01-' for c in pattern):
        raise ValueError('bad opcode pattern %r' % pattern)
    patterns.append((pattern, target, mnemonic))


# ==========================================================================
# Reset -- UM 5.5
#
# "The processor reads the reset vector table entry (address $00000) and loads
# the contents into the supervisor stack pointer (SSP). Next, the processor
# loads the contents of address $00004 (vector table entry 1) into the program
# counter. Then the processor initializes the interrupt level in the status
# register to a value of seven. In the MC68010, the processor also clears the
# vector base register to $00000."
#
# The status register and VBR are set by the RTL's own reset, not from here;
# what the microcode does is the four reads and the two prefetches that fill
# the pipe. A long word is two word reads, high word first, shifted into T1.
# ==========================================================================
def reset_sequence():
    label('reset')
    u(comment='address of the reset vector table',
      asrc=SRC['ZERO'], alu=ALU['A'], dst=DST['T0'])

    # A long word is two word reads, high first, each shifted into the low
    # half of T1. The address register post-increments itself, so the ALU is
    # free to carry the data across in the same microword.
    u(comment='SSP, high word',
      bus=BUS['READ'], asel=ASEL['T0_INC2'], fc=FC['PROG'],
      asrc=SRC['RDATA'], alu=ALU['A'], dst=DST['T1_SHW'])
    u(comment='SSP, low word',
      bus=BUS['READ'], asel=ASEL['T0_INC2'], fc=FC['PROG'],
      asrc=SRC['RDATA'], alu=ALU['A'], dst=DST['T1_SHW'])
    u(comment='A7 <- SSP',
      asrc=SRC['T1'], alu=ALU['A'], dst=DST['REG'], rsel=RSEL['A7'])

    u(comment='PC, high word',
      bus=BUS['READ'], asel=ASEL['T0_INC2'], fc=FC['PROG'],
      asrc=SRC['RDATA'], alu=ALU['A'], dst=DST['T1_SHW'])
    u(comment='PC, low word',
      bus=BUS['READ'], asel=ASEL['T0_INC2'], fc=FC['PROG'],
      asrc=SRC['RDATA'], alu=ALU['A'], dst=DST['T1_SHW'])
    u(comment='PC <- reset vector',
      asrc=SRC['T1'], alu=ALU['A'], dst=DST['PC'])

    # Fill the pipe: the first read loads irc, the second moves it into ir and
    # loads irc again, so ir and irc hold the first two words of the program.
    u(comment='fill irc',
      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
    u(comment='fill ir and irc, then decode the first instruction',
      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'],
      seq=SEQ['DECODE'])


# ==========================================================================
# NOP -- PRM section 4
#
# Four cycles in the reference vectors, which is exactly one prefetch: no
# internal work at all, just advance the pipe and decode what comes next.
# ==========================================================================
def nop():
    label('nop')
    u(comment='advance the prefetch pipe and go',
      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'],
      seq=SEQ['DECODE'])
    opcode('0100111001110001', 'nop', 'NOP')


# ==========================================================================
# BRA -- PRM section 4
#
# Ten cycles in the reference vectors: two internal, then two prefetches from
# the new stream, because both ir and irc have to be refilled.
#
# The displacement is measured from the word after the opcode, which is the
# word irc holds -- so irc_pc is the base, in both the byte and the word form.
# A displacement byte of zero selects the word form; the decoder tells the two
# apart by pattern, so no run-time test is needed.
# ==========================================================================
def bra():
    label('bra_b')
    u(comment='target = irc_pc + sign-extended displacement byte',
      asrc=SRC['IRC_PC'], bsrc=SRC['IR_SXB'], alu=ALU['ADD'], dst=DST['T0'])
    u(comment='take the branch', goto='branch_refill',
      asrc=SRC['T0'], alu=ALU['A'], dst=DST['PC'])

    label('bra_w')
    u(comment='target = irc_pc + sign-extended displacement word',
      asrc=SRC['IRC_PC'], bsrc=SRC['IRC_SX'], alu=ALU['ADD'], dst=DST['T0'])
    u(comment='take the branch', goto='branch_refill',
      asrc=SRC['T0'], alu=ALU['A'], dst=DST['PC'])

    # Shared by every taken branch: refill both halves of the pipe.
    label('branch_refill')
    u(comment='fill irc from the new stream',
      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
    u(comment='fill ir and irc, then decode',
      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'],
      seq=SEQ['DECODE'])

    # A displacement byte of zero is the word form. This pattern has to come
    # first to win the priority order.
    opcode('0110000000000000', 'bra_w', 'BRA.W')
    opcode('01100000--------', 'bra_b', 'BRA.B')


# ==========================================================================
# Anything with no pattern lands here. Illegal instruction exception
# processing arrives in P4; for now it stops, which a testbench can see.
# ==========================================================================
def illegal():
    label('illegal')
    u(comment='no exception processing yet: stand still', goto='illegal')


def build():
    reset_sequence()
    illegal()
    nop()
    bra()
    return words, labels, fixups, patterns, fallthrough
