"""The RD68011 microcode program, and the opcode patterns that enter it.

Read this alongside isa.py, which defines the fields each line sets.

Cycle counts fall out of the structure: a microword with no bus request costs
one clock, one with a bus request costs the whole bus cycle. So the reference
NOP at four cycles is a single prefetch microword, and Bcc taken at ten cycles
is two internal microwords and two prefetches.
"""

from isa import SEQ, COND, SRC, ALU, DST, BUS, ASEL, FC, PF, RSEL, SIZE, \
                EASEL, CCR, WSEL, AUPD, AEASEL

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
                     'bus', 'asel', 'fc', 'pf', 'rsel', 'wsel', 'size', 'easel',
                     'ccr', 'aupd', 'aeasel', 'dhi', 'sh', 'shone',
                     'bitimm', 'vec', 'vsel', 'rstreq', 'stop',
                     'goto'):
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
    # BRA is Bcc with the always-true condition, and the generic Bcc code
    # covers it; these entry points stay for the P2 fetch testbench, which
    # names them directly.
    opcode('0110000000000000', 'bra_w', 'BRA.W')
    opcode('01100000--------', 'bra_b', 'BRA.B')


# ==========================================================================
# Anything with no pattern lands here. Illegal instruction exception
# processing arrives in P4; for now it stops, which a testbench can see.
# ==========================================================================
def illegal():
    # Where the decoder sends anything it has no pattern for. It jumps to the
    # illegal-instruction exception, which is set up later in the build, so
    # this is a one-word trampoline.
    label('illegal')
    u(comment='an unrecognised opcode is an illegal instruction',
      goto='illegal_exc')


# ==========================================================================
# MOVEQ -- PRM section 4
#
#   0111 rrr 0 dddddddd     Dn <- sign-extended data byte
#
# Four cycles in the reference vectors, which is one prefetch and nothing else.
# The whole instruction is a single microword: the sign extension is a source
# multiplexer, the register write is a destination, and the prefetch is the
# same one every instruction ends with.
#
# The condition codes are the logical rule at long size -- N from bit 31 of the
# sign-extended value, Z over all 32 bits -- because MOVEQ always writes the
# full register.
# ==========================================================================
def moveq():
    label('moveq')
    u(comment='Dn <- sign-extended byte, and end the instruction',
      asrc=SRC['IR_SXB'], alu=ALU['A'], dst=DST['REG_L'], rsel=RSEL['IR9_D'],
      size=SIZE['LONG'], ccr=CCR['LOGIC'],
      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'],
      seq=SEQ['DECODE'])
    opcode('0111---0--------', 'moveq', 'MOVEQ')


# ==========================================================================
# MOVE, register to register -- PRM section 4
#
#   00 ss RRR 000 000 rrr    MOVE  <ea>,Dn   with a register-direct source
#   00 ss RRR 000 001 rrr
#
# Size is in bits 13:12: 01 byte, 11 word, 10 long. The destination field is
# bits 11:6 with the register and mode *swapped* relative to every other
# instruction, which is what the microword's `easel` bit is for.
#
# Four cycles: one prefetch, no internal work. A byte or word move leaves the
# rest of the destination register alone, which the size-aware register merge
# in the sequencer does.
#
# An address register source is legal for word and long moves and not for byte
# ones (PRM section 4: "the source operand may not be an address register when
# the size is byte"), so the byte patterns below name mode 000 only.
# ==========================================================================
MOVE_SIZE_BITS = {'BYTE': '01', 'WORD': '11', 'LONG': '10'}


def move_reg_to_reg():
    for sz in ('BYTE', 'WORD', 'LONG'):
        label('move_%s_r2r' % sz.lower())
        # One microword: read the source register the mode names, write the
        # destination register in bits 11:9, set the flags, prefetch, done.
        u(comment='MOVE.%s <register>,Dn' % sz[0],
          asrc=SRC['REG'], alu=ALU['A'], dst=DST['REG'],
          rsel=RSEL['EA_ANY'], wsel=WSEL['IR9_D'], easel=EASEL['SRC'],
          size=SIZE[sz], ccr=CCR['LOGIC'],
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'],
          seq=SEQ['DECODE'])


def move_reg_to_reg_patterns():
    for sz, bits in MOVE_SIZE_BITS.items():
        tgt = 'move_%s_r2r' % sz.lower()
        # Source modes 000 (Dn) always; 001 (An) for word and long only.
        opcode('00%s---000000---' % bits, tgt, 'MOVE.%s Dn,Dn' % sz[0])
        if sz != 'BYTE':
            opcode('00%s---000001---' % bits, tgt, 'MOVE.%s An,Dn' % sz[0])


# ==========================================================================
# MOVE with memory operands -- PRM section 4
#
# The addressing modes cost no internal cycles on the real part: MOVE.W
# (A0)+,D0 is eight cycles, which is two bus cycles and nothing else. So an
# address is never computed in a microword of its own. Instead:
#
#   (An), (An)+, -(An)   the access microword addresses through the register
#                        directly, and `aupd` modifies it in the same step
#   (d16,An), (xxx).W    the address is computed in the microword that
#   (xxx).L, (d16,PC)    prefetches the extension word it needs, which the
#                        instruction has to run anyway
#   #imm                 the operand is the extension word; no address at all
#
# A long transfer is two word accesses. The second addresses two bytes past the
# first (_PLUS2), and the register update, where there is one, goes on the
# second microword with a long size so it moves by four in one step.
#
# Source shapes below are named by what they leave in T1.
# ==========================================================================
SRC_MODES = [
    # (name, mode bits, extension words, microcode generator)
    ('aind',   '010', 0),
    ('apost',  '011', 0),
    ('apre',   '100', 0),
    ('adisp',  '101', 1),
    ('absw',   '111000', 1),
    ('absl',   '111001', 2),
    ('pcdisp', '111010', 1),
    ('imm',    '111100', None),
]

DST_MODES = [
    ('dn',    '000'),
    ('aind',  '010'),
    ('apost', '011'),
    ('apre',  '100'),
    ('adisp', '101'),
    ('absw',  '111', '000'),
    ('absl',  '111', '001'),
]


def ea_setup(name, sz, easel_v, is_source=False):
    """Emit the microwords that make the address available, if any.

    Modes that address through a register directly emit nothing: the access
    microword does the work. Modes with extension words fold the arithmetic
    into the prefetch that consumes them.
    """
    if name in ('aind', 'apost', 'apre'):
        return
    if name == 'adisp':
        u(comment='(d16,An): address, computed as the displacement is consumed',
          asrc=SRC['REG'], rsel=RSEL['EA_A'], easel=easel_v,
          bsrc=SRC['IRC_SX'], alu=ALU['ADD'], dst=DST['T0'],
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
    elif name == 'pcdisp':
        u(comment='(d16,PC): the base is the address of the displacement word',
          asrc=SRC['IRC_PC'], bsrc=SRC['IRC_SX'], alu=ALU['ADD'], dst=DST['T0'],
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
    elif name == 'absw':
        u(comment='(xxx).W: sign-extended to 32 bits',
          asrc=SRC['IRC_SX'], alu=ALU['A'], dst=DST['T0'],
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
    elif name in ('aidx', 'pcidx'):
        # (d8,An,Xn) and (d8,PC,Xn). The base, the sign-extended displacement
        # byte and the index register are three terms and the ALU adds two, so
        # this takes two internal microwords -- which is also what the
        # reference charges for it: an indexed operand costs two cycles more
        # than a displacement one, which has the same number of bus cycles.
        if name == 'aidx':
            u(comment='(d8,An,Xn): base plus the displacement byte',
              asrc=SRC['REG'], rsel=RSEL['EA_A'], easel=easel_v,
              bsrc=SRC['IRC_SXB'], alu=ALU['ADD'], dst=DST['T0'])
        else:
            u(comment='(d8,PC,Xn): the base is the extension word address',
              asrc=SRC['IRC_PC'], bsrc=SRC['IRC_SXB'], alu=ALU['ADD'],
              dst=DST['T0'])
        u(comment='and the index register, sized by bit 11 of the extension',
          asrc=SRC['T0'], bsrc=SRC['INDEX'], alu=ALU['ADD'], dst=DST['T0'])
        u(comment='the extension word is consumed; refill the pipe',
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
    elif name == 'absl':
        # Both extension words in one bus cycle: the high half is already in
        # irc and the low half is the word this cycle reads. The reference
        # vectors show exactly one program read before the operand access and
        # two after it, which is what this leaves behind -- the pipe is a word
        # short, so the instruction ends with a double prefetch.
        u(comment='(xxx).L: high word from irc, low word from this read',
          asrc=SRC['IRC'], bsrc=SRC['RDATA'], alu=ALU['CAT'], dst=DST['T0'],
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
        if is_source:
            # With the address complete and the operand access still to come,
            # the pipe is topped up now rather than at the end.
            u(comment='and top the pipe up before the operand access',
              bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])


def ea_fc(name):
    """A PC-relative operand lives in program space (UM table 3-3)."""
    return FC['PROG'] if name in ('pcdisp', 'pcidx') else FC['DATA']


def ea_needs_double_refill(name):
    """A *destination* (xxx).L leaves the pipe a word short at the end.

    A source one does not, because the refill fits in before the operand
    access -- see ea_setup. The reference vectors show both orders plainly:
    with the absolute long as the source the reads go ext, refill, operand;
    with it as the destination they go operand, ext, write, refill, refill.
    Both are three program reads, which is the N+1 the prefetch model predicts
    for two extension words; only the placement differs.
    """
    return name == 'absl'


def ea_setup_nopf(name, easel_v):
    """Compute the address without prefetching.

    JMP and JSR leave the instruction stream entirely, so there is nothing to
    top the prefetch pipe up for: the reference gives JMP (d16,An) two bus
    cycles, both of them refills from the target. The extension word is taken
    straight out of irc instead.

    (xxx).L is the exception, and the only one: its low half is not in irc and
    has to be read, which is why the reference gives it three.
    """
    if name == 'aind':
        return
    if name == 'adisp':
        u(comment='(d16,An), with no prefetch: the stream is about to change',
          asrc=SRC['REG'], rsel=RSEL['EA_A'], easel=easel_v,
          bsrc=SRC['IRC_SX'], alu=ALU['ADD'], dst=DST['T0'])
    elif name == 'pcdisp':
        u(comment='(d16,PC), with no prefetch',
          asrc=SRC['IRC_PC'], bsrc=SRC['IRC_SX'], alu=ALU['ADD'], dst=DST['T0'])
    elif name == 'absw':
        u(comment='(xxx).W, with no prefetch',
          asrc=SRC['IRC_SX'], alu=ALU['A'], dst=DST['T0'])
    elif name == 'absl':
        u(comment='(xxx).L: the low half still has to be read',
          asrc=SRC['IRC'], bsrc=SRC['RDATA'], alu=ALU['CAT'], dst=DST['T0'],
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['NONE'])
    elif name in ('aidx', 'pcidx'):
        if name == 'aidx':
            u(comment='(d8,An,Xn): base plus the displacement byte',
              asrc=SRC['REG'], rsel=RSEL['EA_A'], easel=easel_v,
              bsrc=SRC['IRC_SXB'], alu=ALU['ADD'], dst=DST['T0'])
        else:
            u(comment='(d8,PC,Xn): base plus the displacement byte',
              asrc=SRC['IRC_PC'], bsrc=SRC['IRC_SXB'], alu=ALU['ADD'],
              dst=DST['T0'])
        u(comment='and the index register',
          asrc=SRC['T0'], bsrc=SRC['INDEX'], alu=ALU['ADD'], dst=DST['T0'])


def jump_return_src(name):
    """Where the return address comes from, by how many extension words."""
    if name == 'aind':
        return SRC['IRC_PC'], None          # no extension word
    if name == 'absl':
        return SRC['PC'], SRC['TWO']        # two of them
    return SRC['PC'], None                  # one


def ea_asel(name, second=False):
    """Which address the access microword uses."""
    if name in ('aind', 'apost', 'apre'):
        return ASEL['EA_PLUS2'] if second else ASEL['EA']
    return ASEL['T0_PLUS2'] if second else ASEL['T0']


def ea_aupd(name, sz, second):
    """The register modification, on the microword that should carry it."""
    if name == 'aind':
        # No modification, but the address still has to reach the output
        # buffer for a write that comes after a prefetch.
        return AUPD['LATCH'] if not second else AUPD['NONE']
    if name == 'apost':
        # On a long, both words are read before the register moves, so the
        # update rides the second access and moves by four.
        return AUPD['POST'] if (sz != 'LONG' or second) else AUPD['NONE']
    if name == 'apre':
        # The decrement happens before the first access and is the whole four
        # at once, so the second access is a plain +2 from there.
        return AUPD['PRE'] if not second else AUPD['NONE']
    return AUPD['NONE']


def ea_upd_size(name, sz, second):
    """A long (An)+/-(An) moves the register by four in one step."""
    return SIZE[sz] if (name in ('apost', 'apre')) else SIZE[sz]


def move_src_fetch(name, sz, easel_v, keep_addr=False):
    """Leave the source operand in T1."""
    if name == 'imm':
        if sz == 'LONG':
            u(comment='#imm.L: high word',
              asrc=SRC['IRC'], alu=ALU['A'], dst=DST['T1'],
              bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
            u(comment='#imm.L: low word',
              asrc=SRC['IRC'], alu=ALU['A'], dst=DST['T1_SHW'],
              bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
        else:
            u(comment='#imm: the extension word is the operand',
              asrc=SRC['IRC'], alu=ALU['A'], dst=DST['T1'],
              bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
        return

    ea_setup(name, sz, easel_v, is_source=True)
    if sz == 'LONG':
        u(comment='source, high word',
          asrc=SRC['RDATA'], alu=ALU['A'], dst=DST['T1'],
          bus=BUS['READ'], asel=ea_asel(name), fc=ea_fc(name),
          aupd=ea_aupd(name, sz, False), size=SIZE['LONG'],
          rsel=RSEL['EA_A'], easel=easel_v)
        u(comment='source, low word',
          asrc=SRC['RDATA'], alu=ALU['A'], dst=DST['T1_SHW'],
          bus=BUS['READ'], asel=ea_asel(name, True), fc=ea_fc(name),
          aupd=ea_aupd(name, sz, True), size=SIZE['LONG'],
          rsel=RSEL['EA_A'], easel=easel_v)
    elif sz == 'BYTE':
        u(comment='source byte',
          asrc=SRC['RDATA_B'], alu=ALU['A'], dst=DST['T1'],
          bus=BUS['READ'], asel=ea_asel(name), fc=ea_fc(name),
          aupd=ea_aupd(name, sz, False), size=SIZE['BYTE'],
          rsel=RSEL['EA_A'], easel=easel_v)
    else:
        u(comment='source word',
          asrc=SRC['RDATA'], alu=ALU['A'], dst=DST['T1'],
          bus=BUS['READ'], asel=ea_asel(name), fc=ea_fc(name),
          aupd=ea_aupd(name, sz, False), size=SIZE['WORD'],
          rsel=RSEL['EA_A'], easel=easel_v)


def move_pre_dec_store(src_sel, sz, rsel=RSEL['NONE']):
    """MOVE to -(An), which prefetches before it writes.

    The reference vectors are unambiguous: MOVE.W D7,-(A4) does a program read
    at the current pc and only then the write. So by the time the write cycle
    runs, ir already holds the next instruction and the destination register
    field has gone -- which is why the prefetch microword decrements the
    register and latches the address it produced, and the write addresses
    through that latch.

    The flags come from the moved value and are set on the prefetch microword,
    which is where the value passes through the ALU.
    """
    if sz == 'LONG':
        # A long decrements by four at once, and then writes the LOW word
        # first, at An-2, followed by the high word at An-4. That order is the
        # reference's, not a guess: MOVE.L D4,-(A0) with A0 at ...c77e writes
        # ...c77c before ...c77a. It falls out of the machine working down from
        # the top of the operand rather than up from the bottom.
        u(comment='MOVE.L to -(An): prefetch, decrement by four, latch address',
          asrc=src_sel, rsel=rsel, easel=EASEL['SRC'],
          alu=ALU['A'], dst=DST['DBUF'], ccr=CCR['LOGIC'],
          aeasel=AEASEL['DST'], aupd=AUPD['PRE'], size=SIZE['LONG'],
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'])
        u(comment='low word first, two bytes above the decremented address',
          bus=BUS['WRITE'], asel=ASEL['EAL_PLUS2'], fc=FC['DATA'],
          size=SIZE['LONG'], dhi=0)
        u(comment='then the high word at the decremented address, and end',
          bus=BUS['WRITE'], asel=ASEL['EAL'], fc=FC['DATA'],
          size=SIZE['LONG'], dhi=1, seq=SEQ['DECODE'])
    else:
        u(comment='MOVE to -(An): prefetch, decrement, latch the address',
          asrc=src_sel, rsel=rsel, easel=EASEL['SRC'],
          alu=ALU['A'], dst=DST['DBUF'], ccr=CCR['LOGIC'],
          aeasel=AEASEL['DST'], aupd=AUPD['PRE'], size=SIZE[sz],
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'])
        u(comment='and the write, through the latched address',
          bus=BUS['WRITE'], asel=ASEL['EAL'], fc=FC['DATA'], size=SIZE[sz],
          seq=SEQ['DECODE'])


def move_dst_store(name, sz):
    """Write T1 to the destination, setting the flags from the moved value."""
    ea_setup(name, sz, EASEL['DST'])
    if sz == 'LONG':
        u(comment='buffer the operand, then the high word',
          asrc=SRC['T1'], alu=ALU['A'], dst=DST['DBUF'],
          bus=BUS['WRITE'], asel=ea_asel(name), fc=FC['DATA'],
          aeasel=AEASEL['DST'], aupd=ea_aupd(name, sz, False),
          size=SIZE['LONG'], ccr=CCR['LOGIC'], dhi=1)
        u(comment='destination, low word',
          bus=BUS['WRITE'], asel=ea_asel(name, True), fc=FC['DATA'],
          aeasel=AEASEL['DST'], aupd=ea_aupd(name, sz, True),
          size=SIZE['LONG'], dhi=0)
    else:
        u(comment='destination',
          asrc=SRC['T1'], alu=ALU['A'], dst=DST['DBUF'],
          bus=BUS['WRITE'], asel=ea_asel(name), fc=FC['DATA'],
          aeasel=AEASEL['DST'], aupd=ea_aupd(name, sz, False),
          size=SIZE[sz], ccr=CCR['LOGIC'])


def final_prefetch(comment='end of instruction', double=False):
    """Refill the pipe and end the instruction.

    `double` is for the modes that consumed an extension word out of irc
    without prefetching a replacement -- (xxx).L -- which leaves both halves of
    the pipe to fill rather than one.
    """
    if double:
        u(comment='refill irc, the pipe being a word short',
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
    u(comment=comment,
      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'],
      seq=SEQ['DECODE'])


# The source modes MOVE can read from, as (name, mode bits, register bits).
MOVE_SRC = [
    ('aind',   '010', '---'),
    ('apost',  '011', '---'),
    ('apre',   '100', '---'),
    ('adisp',  '101', '---'),
    ('aidx',   '110', '---'),
    ('absw',   '111', '000'),
    ('absl',   '111', '001'),
    ('pcdisp', '111', '010'),
    ('pcidx',  '111', '011'),
    ('imm',    '111', '100'),
]

# The destination modes it can write to. An address register destination is
# MOVEA, a different instruction; PC-relative and immediate are not
# destinations at all.
MOVE_DST = [
    ('dn',    '000', '---'),
    ('aind',  '010', '---'),
    ('apost', '011', '---'),
    ('apre',  '100', '---'),
    ('adisp', '101', '---'),
    ('aidx',  '110', '---'),
    ('absw',  '111', '000'),
    ('absl',  '111', '001'),
]


def move_full():
    """Every combination of a memory source or destination with the rest."""
    for sz in ('BYTE', 'WORD', 'LONG'):
        bits = MOVE_SIZE_BITS[sz]
        lo = sz.lower()

        # --- register source, memory destination -------------------------
        for dname, dmode, dreg in MOVE_DST:
            if dname == 'dn':
                continue     # already covered by the fused reg-to-reg form
            lbl = 'move_%s_r2%s' % (lo, dname)
            label(lbl)
            if dname == 'apre':
                move_pre_dec_store(SRC['REG'], sz, rsel=RSEL['EA_ANY'])
                for smode, sreg in (('000', '---'), ('001', '---')):
                    if sz == 'BYTE' and smode == '001':
                        continue
                    opcode('00%s%s%s%s%s' % (bits, dreg, dmode, smode, sreg),
                           lbl, 'MOVE.%s reg,-(An)' % sz[0])
                continue
            # The source register is read straight into the write cycle: one
            # microword, no internal cycles.
            ea_setup(dname, sz, EASEL['DST'])
            if ea_needs_double_refill(dname):
                # (xxx).L left the pipe a word short. With a register source
                # there is no operand read to fill the gap, so the refill goes
                # here, before the store -- which is where the reference puts
                # it. With a memory source the source read takes this slot and
                # both refills land after the store instead.
                u(comment='top the pipe up before the store',
                  bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                  pf=PF['FETCH'])
            if sz == 'LONG':
                u(comment='MOVE.L <register>,<memory>: buffer it, high word out',
                  asrc=SRC['REG'], rsel=RSEL['EA_ANY'], easel=EASEL['SRC'],
                  alu=ALU['A'], dst=DST['DBUF'],
                  bus=BUS['WRITE'], asel=ea_asel(dname), fc=FC['DATA'],
                  aeasel=AEASEL['DST'], aupd=ea_aupd(dname, sz, False),
                  size=SIZE['LONG'], ccr=CCR['LOGIC'], dhi=1)
                u(comment='and the low word',
                  bus=BUS['WRITE'], asel=ea_asel(dname, True), fc=FC['DATA'],
                  aeasel=AEASEL['DST'], aupd=ea_aupd(dname, sz, True),
                  size=SIZE['LONG'], dhi=0)
            else:
                u(comment='MOVE.%s <register>,<memory>' % sz[0],
                  asrc=SRC['REG'], rsel=RSEL['EA_ANY'], easel=EASEL['SRC'],
                  alu=ALU['A'], dst=DST['DBUF'],
                  bus=BUS['WRITE'], asel=ea_asel(dname), fc=FC['DATA'],
                  aeasel=AEASEL['DST'], aupd=ea_aupd(dname, sz, False),
                  size=SIZE[sz], ccr=CCR['LOGIC'])
            final_prefetch()

            for smode, sreg in (('000', '---'), ('001', '---')):
                if sz == 'BYTE' and smode == '001':
                    continue    # an address register is not a byte operand
                opcode('00%s%s%s%s%s' % (bits, dreg, dmode, smode, sreg),
                       lbl, 'MOVE.%s reg,%s' % (sz[0], dname))

        # --- memory source ------------------------------------------------
        for sname, smode, sreg in MOVE_SRC:
            for dname, dmode, dreg in MOVE_DST:
                lbl = 'move_%s_%s2%s' % (lo, sname, dname)
                label(lbl)
                move_src_fetch(sname, sz, EASEL['SRC'])
                if dname == 'apre':
                    move_pre_dec_store(SRC['T1'], sz)
                elif dname == 'dn':
                    u(comment='MOVE.%s <memory>,Dn' % sz[0],
                      asrc=SRC['T1'], alu=ALU['A'], dst=DST['REG'],
                      wsel=WSEL['IR9_D'], size=SIZE[sz], ccr=CCR['LOGIC'],
                      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                      pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
                else:
                    move_dst_store(dname, sz)
                    final_prefetch(double=ea_needs_double_refill(dname))
                opcode('00%s%s%s%s%s' % (bits, dreg, dmode, smode, sreg),
                       lbl, 'MOVE.%s %s,%s' % (sz[0], sname, dname))


def build():
    reset_sequence()
    illegal()
    nop()
    bra()
    moveq()
    move_reg_to_reg()
    move_reg_to_reg_patterns()
    move_full()
    movea()
    tst()
    rmw_group()
    clr()
    alu_group()
    cmp_and_eor()
    addr_forms()
    imm_group()
    addq_subq()
    ext_swap()
    lea_pea()
    shifts()
    bit_ops()
    scc()
    negx()
    tas()
    # BSR before Bcc: Bcc's catch-all pattern would otherwise swallow the
    # 0001 condition field that means BSR.
    bsr()
    dbcc()
    bcc()
    jmp_jsr()
    rts_rtr()
    link_unlk()
    exception_tail()
    traps()
    priv_violation()
    rte()
    sr_instructions()
    sr_immediates()
    move_usp()
    reset_stop()
    chk()
    interrupt()
    trace()
    return words, labels, fixups, patterns, fallthrough


# ==========================================================================
# The rest of the integer instruction set
#
# Everything below is generated from one set of helpers, because the bus
# behaviour of an instruction is almost entirely a function of its addressing
# mode and its size rather than of what the ALU does in the middle. The shapes
# are the reference's, surveyed with tools/harte/shapes.py:
#
#   NEG.w (A5)     r P w    read the operand, prefetch, write it back
#   TST.w (A6)     r P      read the operand, prefetch
#   NOT.w D0       P        no memory at all
#   ADD.w (A0),D0  r P
#   LEA (A0),A6    P        an address is computed, never dereferenced
#   PEA (A2)       P w w    prefetch, then a long onto the stack
#
# The prefetch sitting *between* the read and the write is the thing to notice:
# it is why the address output buffer exists, since ir has moved on to the next
# instruction by the time the write happens.
# ==========================================================================

# (name, mode bits, register bits) for every addressing mode.
M_DN     = ('dn',     '000', '---')
M_AN     = ('an',     '001', '---')
M_AIND   = ('aind',   '010', '---')
M_APOST  = ('apost',  '011', '---')
M_APRE   = ('apre',   '100', '---')
M_ADISP  = ('adisp',  '101', '---')
M_AIDX   = ('aidx',   '110', '---')
M_ABSW   = ('absw',   '111', '000')
M_ABSL   = ('absl',   '111', '001')
M_PCDISP = ('pcdisp', '111', '010')
M_PCIDX  = ('pcidx',  '111', '011')
M_IMM    = ('imm',    '111', '100')

# PRM section 2's categories.
MEM_ALT   = [M_AIND, M_APOST, M_APRE, M_ADISP, M_AIDX, M_ABSW, M_ABSL]
DATA_ALT  = [M_DN] + MEM_ALT
DATA_ALL  = DATA_ALT + [M_PCDISP, M_PCIDX, M_IMM]
ALL_MODES = [M_DN, M_AN] + DATA_ALL[1:]
CONTROL   = [M_AIND, M_ADISP, M_AIDX, M_ABSW, M_ABSL, M_PCDISP, M_PCIDX]

SIZE_BITS = {'BYTE': '00', 'WORD': '01', 'LONG': '10'}


def is_reg_mode(name):
    return name in ('dn', 'an')


def ea_read_operand(name, sz, easel_v, dest=None):
    """Leave the effective operand in T1, whatever the mode.

    Register-direct and immediate modes never touch memory; the rest read
    through the address the mode produces.
    """
    dest = dest or DST['T1']
    if name == 'dn':
        u(comment='operand: a data register',
          asrc=SRC['REG'], rsel=RSEL['EA_D'], easel=easel_v,
          alu=ALU['A'], dst=dest, size=SIZE[sz])
        return
    if name == 'an':
        u(comment='operand: an address register',
          asrc=SRC['REG'], rsel=RSEL['EA_A'], easel=easel_v,
          alu=ALU['A'], dst=dest, size=SIZE[sz])
        return
    move_src_fetch(name, sz, easel_v)


def ea_write_operand(name, sz, easel_v, src_sel=None, wsel_v=None):
    """Write the value in T1 (or src_sel) back to the mode's destination."""
    src_sel = src_sel if src_sel is not None else SRC['T1']
    if name == 'dn':
        u(comment='result to a data register',
          asrc=src_sel, alu=ALU['A'], dst=DST['REG'],
          rsel=RSEL['EA_D'], wsel=wsel_v or WSEL['SAME'], easel=easel_v,
          size=SIZE[sz], seq=SEQ['DECODE'],
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'])
        return
    # Memory: the address is already in the output buffer or in T0, because
    # the read that preceded this put it there.
    base = ASEL['T0'] if name not in ('aind', 'apost', 'apre') else ASEL['EAL']
    plus = (ASEL['T0_PLUS2'] if name not in ('aind', 'apost', 'apre')
            else ASEL['EAL_PLUS2'])
    if sz == 'LONG':
        u(comment='result, high word',
          asrc=src_sel, alu=ALU['A'], dst=DST['DBUF'], dhi=1,
          bus=BUS['WRITE'], asel=base, fc=FC['DATA'], size=SIZE['LONG'])
        u(comment='result, low word',
          bus=BUS['WRITE'], asel=plus, fc=FC['DATA'], size=SIZE['LONG'],
          dhi=0, seq=SEQ['DECODE'])
    else:
        u(comment='result to memory',
          asrc=src_sel, alu=ALU['A'], dst=DST['DBUF'],
          bus=BUS['WRITE'], asel=base, fc=FC['DATA'], size=SIZE[sz],
          seq=SEQ['DECODE'])


def pattern(prefix, mode, reg, suffix=''):
    """Assemble a 16-bit opcode pattern from its pieces."""
    p = prefix + mode + reg + suffix
    assert len(p) == 16, '%r is %d bits' % (p, len(p))
    return p


# ==========================================================================
# MOVEA -- PRM section 4
#
#   00 ss RRR 001 mmmrrr    An <- <ea>, with no condition codes at all
#
# A word source is sign-extended to the full 32 bits of the register: an
# address register is never written narrowly.
# ==========================================================================
def movea():
    for sz, bits in (('WORD', '11'), ('LONG', '10')):
        for name, mode, reg in ALL_MODES:
            lbl = 'movea_%s_%s' % (sz.lower(), name)
            label(lbl)
            if is_reg_mode(name):
                # One microword: read the register, sign-extend if needed,
                # write the address register, prefetch, done.
                u(comment='MOVEA.%s <register>,An' % sz[0],
                  asrc=SRC['REG'], rsel=RSEL['EA_ANY'], easel=EASEL['SRC'],
                  alu=ALU['SXW'] if sz == 'WORD' else ALU['A'],
                  dst=DST['REG_L'], wsel=WSEL['IR9_A'],
                  size=SIZE['LONG'],
                  bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                  pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
            else:
                move_src_fetch(name, sz, EASEL['SRC'])
                u(comment='MOVEA.%s <memory>,An' % sz[0],
                  asrc=SRC['T1'],
                  alu=ALU['SXW'] if sz == 'WORD' else ALU['A'],
                  dst=DST['REG_L'],
                  wsel=WSEL['IR9_A'], size=SIZE['LONG'],
                  bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                  pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
            opcode(pattern('00' + bits + '---001', mode, reg), lbl,
                   'MOVEA.%s %s' % (sz[0], name))


# ==========================================================================
# TST -- PRM section 4
#
#   0100 1010 ss mmmrrr     set the condition codes from <ea>
#
# Shape: r P. The operand is read, the flags are set from it, and the
# instruction ends on its prefetch.
# ==========================================================================
def tst():
    for sz in ('BYTE', 'WORD', 'LONG'):
        for name, mode, reg in DATA_ALT:
            lbl = 'tst_%s_%s' % (sz.lower(), name)
            label(lbl)
            if name == 'dn':
                u(comment='TST.%s Dn' % sz[0],
                  asrc=SRC['REG'], rsel=RSEL['EA_D'], easel=EASEL['SRC'],
                  alu=ALU['A'], size=SIZE[sz], ccr=CCR['LOGIC'],
                  bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                  pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
            else:
                move_src_fetch(name, sz, EASEL['SRC'])
                u(comment='TST.%s <memory>: flags from the operand' % sz[0],
                  asrc=SRC['T1'], alu=ALU['A'], size=SIZE[sz],
                  ccr=CCR['LOGIC'],
                  bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                  pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
            opcode(pattern('01001010' + SIZE_BITS[sz], mode, reg), lbl,
                   'TST.%s %s' % (sz[0], name))


# ==========================================================================
# The single-operand read-modify-write group -- PRM section 4
#
#   0100 0100 ss mmmrrr   NEG
#   0100 0110 ss mmmrrr   NOT
#   0100 0000 ss mmmrrr   NEGX
#   0100 0010 ss mmmrrr   CLR
#
# Shape on memory: r P w. The prefetch between the read and the write is why
# the address output buffer exists.
#
# CLR IS THE EXCEPTION, AND IT IS AN MC68010 DIVERGENCE
#
# UM section 9's execution times give MC68010 CLR two cycles fewer than the
# MC68000 for every memory destination, because the MC68010 does not read an
# operand it is about to overwrite. Its shape is P w, not r P w.
#
# The reference vectors are an MC68000, so every memory CLR disagrees with
# them by exactly that missing read. That is the divergence filter's job, not
# a bug; see doc/divergences.md.
# ==========================================================================
RMW_OPS = [
    # (name, opcode bits 11:8, alu op, A operand, flag rule)
    ('neg',  '0100', ALU['SUB'],  'zero_minus', CCR['ARITH']),
    ('not',  '0110', ALU['NOT'],  'operand',    CCR['LOGIC']),
]


def rmw_group():
    for iname, opbits, aluop, shape, ccr_rule in RMW_OPS:
        for sz in ('BYTE', 'WORD', 'LONG'):
            for name, mode, reg in DATA_ALT:
                lbl = '%s_%s_%s' % (iname, sz.lower(), name)
                label(lbl)
                if shape == 'zero_minus':
                    a, b = SRC['T1'], SRC['ZERO']      # 0 - operand
                else:
                    a, b = SRC['T1'], SRC['ZERO']
                if name == 'dn':
                    u(comment='%s.%s Dn' % (iname.upper(), sz[0]),
                      asrc=SRC['REG'], rsel=RSEL['EA_D'], easel=EASEL['SRC'],
                      bsrc=SRC['ZERO'] if shape == 'zero_minus' else SRC['ZERO'],
                      alu=aluop, dst=DST['REG'], size=SIZE[sz], ccr=ccr_rule,
                      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                      pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
                else:
                    move_src_fetch(name, sz, EASEL['SRC'])
                    u(comment='compute and prefetch, before the write',
                      asrc=a, bsrc=b, alu=aluop, dst=DST['DBUF'],
                      size=SIZE[sz], ccr=ccr_rule,
                      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                      pf=PF['ADVFETCH'])
                    rmw_store(name, sz)
                opcode(pattern('0100' + opbits + SIZE_BITS[sz], mode, reg),
                       lbl, '%s.%s %s' % (iname.upper(), sz[0], name))


def rmw_store(name, sz):
    """Write the buffered result back to where the operand came from.

    A long goes back LOW word first, at the high address, and then the high
    word: NOT.L (A6) reads A6 then A6+2 and writes A6+2 then A6. A fresh MOVE
    store goes the other way round -- the difference is that this one has the
    whole operand in the buffer and unwinds it, where MOVE is streaming it out.
    Both orders are the reference's.
    """
    base = ASEL['T0'] if name not in ('aind', 'apost', 'apre') else ASEL['EAL']
    plus = (ASEL['T0_PLUS2'] if name not in ('aind', 'apost', 'apre')
            else ASEL['EAL_PLUS2'])
    if sz == 'LONG':
        u(comment='result, low word first',
          bus=BUS['WRITE'], asel=plus, fc=FC['DATA'], size=SIZE['LONG'],
          dhi=0)
        u(comment='then the high word',
          bus=BUS['WRITE'], asel=base, fc=FC['DATA'], size=SIZE['LONG'],
          dhi=1, seq=SEQ['DECODE'])
    else:
        u(comment='result back to memory',
          bus=BUS['WRITE'], asel=base, fc=FC['DATA'], size=SIZE[sz],
          seq=SEQ['DECODE'])


# ==========================================================================
# CLR -- PRM section 4, and UM section 9
#
# The MC68010 writes without reading first. Shape: P w.
# ==========================================================================
def clr():
    for sz in ('BYTE', 'WORD', 'LONG'):
        for name, mode, reg in DATA_ALT:
            lbl = 'clr_%s_%s' % (sz.lower(), name)
            label(lbl)
            if name == 'dn':
                u(comment='CLR.%s Dn' % sz[0],
                  asrc=SRC['ZERO'], alu=ALU['A'], dst=DST['REG'],
                  rsel=RSEL['EA_D'], easel=EASEL['SRC'],
                  size=SIZE[sz], ccr=CCR['LOGIC'],
                  bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                  pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
            else:
                # No read: the MC68010 does not fetch an operand it is about
                # to overwrite (UM section 9). The address still has to be
                # computed, which for the modes with extension words happens
                # in the prefetch that consumes them.
                ea_setup(name, sz, EASEL['SRC'], is_source=True)
                if name in ('aind', 'apost', 'apre'):
                    # CLR touches the address register once, not twice, even
                    # for a long -- there is no read half to split the update
                    # across -- so the whole modification happens here.
                    clr_upd = {'aind': AUPD['LATCH'],
                               'apost': AUPD['POST'],
                               'apre': AUPD['PRE']}[name]
                    u(comment='CLR: prefetch, and latch the address',
                      asrc=SRC['ZERO'], alu=ALU['A'], dst=DST['DBUF'],
                      size=SIZE[sz], ccr=CCR['LOGIC'],
                      aupd=clr_upd, aeasel=AEASEL['SRC'],
                      rsel=RSEL['EA_A'], easel=EASEL['SRC'],
                      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                      pf=PF['ADVFETCH'])
                else:
                    u(comment='CLR: prefetch; the address is already in T0',
                      asrc=SRC['ZERO'], alu=ALU['A'], dst=DST['DBUF'],
                      size=SIZE[sz], ccr=CCR['LOGIC'],
                      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                      pf=PF['ADVFETCH'])
                rmw_store(name, sz)
            opcode(pattern('01000010' + SIZE_BITS[sz], mode, reg), lbl,
                   'CLR.%s %s' % (sz[0], name))


# ==========================================================================
# The ALU group -- PRM section 4
#
#   1101 RRR ooo mmmrrr   ADD      1001 ...   SUB
#   1100 RRR ooo mmmrrr   AND      1000 ...   OR
#   1011 RRR 0ss mmmrrr   CMP      1011 RRR 1ss mmmrrr   EOR
#
# ooo is direction and size together: 000/001/010 are <ea>,Dn at byte, word
# and long, and 100/101/110 are Dn,<ea>. 011 and 111 are the address-register
# forms (ADDA, SUBA, CMPA) for ADD/SUB/CMP and the multiply and divide
# instructions for AND and OR, which are P5.
#
# Shapes: r P for <ea>,Dn, and r P w for Dn,<ea> -- the same read, prefetch,
# write as the rest of the read-modify-write group.
#
# The encodings that look like a Dn,<ea> form with a register destination are
# not: 1101 xxx 1ss 00yyy is ADDX, 1100 xxx 10000 yyy is ABCD, 1000 xxx 10000
# yyy is SBCD, and 1011 xxx 1ss 001yyy is CMPM. All of those are P5, so the
# Dn,<ea> patterns here name memory destinations only. EOR is the exception:
# EOR Dn,Dm is a real instruction, so its destination list keeps Dn.
# ==========================================================================
ALU_GROUP = [
    # (name, opcode bits 15:12, alu op, flag rule, has address forms)
    ('add', '1101', ALU['ADD'], CCR['ARITH'], True),
    ('sub', '1001', ALU['SUB'], CCR['ARITH'], True),
    ('and', '1100', ALU['AND'], CCR['LOGIC'], False),
    ('or',  '1000', ALU['OR'],  CCR['LOGIC'], False),
]


def alu_ea_to_dn(iname, opbits, aluop, ccr_rule, sz, oobits, modes):
    """<ea> op Dn -> Dn."""
    for name, mode, reg in modes:
        lbl = '%s_%s_ea2dn_%s' % (iname, sz.lower(), name)
        label(lbl)
        if is_reg_mode(name):
            u(comment='%s.%s <register>,Dn' % (iname.upper(), sz[0]),
              asrc=SRC['REG'], rsel=RSEL['EA_ANY'], easel=EASEL['SRC'],
              bsrc=SRC['REG2'], alu=aluop, dst=DST['REG'],
              wsel=WSEL['IR9_D'], size=SIZE[sz], ccr=ccr_rule,
              bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
              pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
        else:
            move_src_fetch(name, sz, EASEL['SRC'])
            u(comment='%s.%s <memory>,Dn' % (iname.upper(), sz[0]),
              asrc=SRC['T1'], bsrc=SRC['REG'], rsel=RSEL['IR9_D'],
              alu=aluop, dst=DST['REG'], wsel=WSEL['IR9_D'],
              size=SIZE[sz], ccr=ccr_rule,
              bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
              pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
        opcode(pattern(opbits + '---' + oobits, mode, reg), lbl,
               '%s.%s %s,Dn' % (iname.upper(), sz[0], name))


def alu_dn_to_ea(iname, opbits, aluop, ccr_rule, sz, oobits, modes):
    """Dn op <ea> -> <ea>."""
    for name, mode, reg in modes:
        lbl = '%s_%s_dn2ea_%s' % (iname, sz.lower(), name)
        label(lbl)
        if name == 'dn':
            u(comment='%s.%s Dn,Dm' % (iname.upper(), sz[0]),
              asrc=SRC['REG2'], bsrc=SRC['REG'], rsel=RSEL['EA_D'],
              easel=EASEL['SRC'], alu=aluop, dst=DST['REG'],
              size=SIZE[sz], ccr=ccr_rule,
              bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
              pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
        else:
            move_src_fetch(name, sz, EASEL['SRC'], keep_addr=True)
            u(comment='combine with Dn, prefetch, then write back',
              asrc=SRC['REG2'], bsrc=SRC['T1'], alu=aluop, dst=DST['DBUF'],
              size=SIZE[sz], ccr=ccr_rule,
              bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
              pf=PF['ADVFETCH'])
            rmw_store(name, sz)
        opcode(pattern(opbits + '---' + oobits, mode, reg), lbl,
               '%s.%s Dn,%s' % (iname.upper(), sz[0], name))


def alu_group():
    for iname, opbits, aluop, ccr_rule, has_addr in ALU_GROUP:
        for i, sz in enumerate(('BYTE', 'WORD', 'LONG')):
            # <ea>,Dn. An is not a data addressing mode, so AND and OR never
            # take it, and a byte operand never does either.
            srcs = list(DATA_ALL)
            if has_addr and sz != 'BYTE':
                srcs = [M_DN, M_AN] + DATA_ALL[1:]
            alu_ea_to_dn(iname, opbits, aluop, ccr_rule, sz,
                         '{0:03b}'.format(i), srcs)
            # Dn,<ea>: memory destinations only, the register ones being
            # ADDX/SUBX/ABCD/SBCD.
            alu_dn_to_ea(iname, opbits, aluop, ccr_rule, sz,
                         '{0:03b}'.format(4 + i), MEM_ALT)


def cmp_and_eor():
    for i, sz in enumerate(('BYTE', 'WORD', 'LONG')):
        srcs = list(DATA_ALL) if sz == 'BYTE' else [M_DN, M_AN] + DATA_ALL[1:]
        # CMP: the flags only, so no destination write at all.
        for name, mode, reg in srcs:
            lbl = 'cmp_%s_%s' % (sz.lower(), name)
            label(lbl)
            if is_reg_mode(name):
                u(comment='CMP.%s <register>,Dn' % sz[0],
                  asrc=SRC['REG'], rsel=RSEL['EA_ANY'], easel=EASEL['SRC'],
                  bsrc=SRC['REG2'], alu=ALU['SUB'], size=SIZE[sz],
                  ccr=CCR['CMP'],
                  bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                  pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
            else:
                move_src_fetch(name, sz, EASEL['SRC'])
                u(comment='CMP.%s <memory>,Dn' % sz[0],
                  asrc=SRC['T1'], bsrc=SRC['REG'], rsel=RSEL['IR9_D'],
                  alu=ALU['SUB'], size=SIZE[sz], ccr=CCR['CMP'],
                  bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                  pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
            opcode(pattern('1011---0' + '{0:02b}'.format(i), mode, reg), lbl,
                   'CMP.%s %s' % (sz[0], name))

        # EOR Dn,<ea>. Mode 001 in this encoding is CMPM, so it is excluded.
        for name, mode, reg in DATA_ALT:
            lbl = 'eor_%s_%s' % (sz.lower(), name)
            label(lbl)
            if name == 'dn':
                u(comment='EOR.%s Dn,Dm' % sz[0],
                  asrc=SRC['REG2'], bsrc=SRC['REG'], rsel=RSEL['EA_D'],
                  easel=EASEL['SRC'], alu=ALU['EOR'], dst=DST['REG'],
                  size=SIZE[sz], ccr=CCR['LOGIC'],
                  bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                  pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
            else:
                move_src_fetch(name, sz, EASEL['SRC'], keep_addr=True)
                u(comment='EOR with Dn, prefetch, then write back',
                  asrc=SRC['REG2'], bsrc=SRC['T1'], alu=ALU['EOR'],
                  dst=DST['DBUF'], size=SIZE[sz], ccr=CCR['LOGIC'],
                  bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                  pf=PF['ADVFETCH'])
                rmw_store(name, sz)
            opcode(pattern('1011---1' + '{0:02b}'.format(i), mode, reg), lbl,
                   'EOR.%s Dn,%s' % (sz[0], name))


def addr_forms():
    """ADDA, SUBA and CMPA: a full 32-bit address register operand."""
    for iname, opbits, aluop, is_cmp in (('adda', '1101', ALU['ADD'], False),
                                         ('suba', '1001', ALU['SUB'], False),
                                         ('cmpa', '1011', ALU['SUB'], True)):
        for sz, oobits in (('WORD', '011'), ('LONG', '111')):
            for name, mode, reg in ALL_MODES:
                lbl = '%s_%s_%s' % (iname, sz.lower(), name)
                label(lbl)
                # A word operand is sign-extended to 32 bits and the operation
                # is done at long size, flags and all (PRM section 4).
                if is_reg_mode(name):
                    u(comment='%s.%s: bring the operand to 32 bits'
                              % (iname.upper(), sz[0]),
                      asrc=SRC['REG'], rsel=RSEL['EA_ANY'], easel=EASEL['SRC'],
                      alu=ALU['SXW'] if sz == 'WORD' else ALU['A'],
                      dst=DST['T1'], size=SIZE['LONG'])
                else:
                    move_src_fetch(name, sz, EASEL['SRC'])
                    if sz == 'WORD':
                        u(comment='sign-extend the word operand',
                          asrc=SRC['T1'], alu=ALU['SXW'], dst=DST['T1'],
                          size=SIZE['LONG'])
                u(comment='%s at long size' % iname.upper(),
                  asrc=SRC['T1'], bsrc=SRC['REG'], rsel=RSEL['IR9_A'],
                  alu=aluop,
                  dst=DST['NONE'] if is_cmp else DST['REG_L'],
                  wsel=WSEL['IR9_A'], size=SIZE['LONG'],
                  ccr=CCR['CMP'] if is_cmp else CCR['NONE'],
                  bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                  pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
                opcode(pattern(opbits + '---' + oobits, mode, reg), lbl,
                       '%s.%s %s' % (iname.upper(), sz[0], name))


# ==========================================================================
# The immediate group -- PRM section 4
#
#   0000 0000 ss mmmrrr  ORI      0000 0010 ss  ANDI
#   0000 0100 ss mmmrrr  SUBI     0000 0110 ss  ADDI
#   0000 1010 ss mmmrrr  EORI     0000 1100 ss  CMPI
#
# Shape: P r P w -- the extension word, the operand, the prefetch, the write.
#
# The immediate is parked in the data output buffer rather than in a working
# register: it has to survive while the effective address is computed and the
# operand read, and the buffer is idle until the write at the end. That keeps
# the working set inside the checkpoint budget in doc/checkpoint.md.
# ==========================================================================
IMM_GROUP = [
    ('ori',  '0000', ALU['OR'],  CCR['LOGIC'], False),
    ('andi', '0010', ALU['AND'], CCR['LOGIC'], False),
    ('subi', '0100', ALU['SUB'], CCR['ARITH'], False),
    ('addi', '0110', ALU['ADD'], CCR['ARITH'], False),
    ('eori', '1010', ALU['EOR'], CCR['LOGIC'], False),
    ('cmpi', '1100', ALU['SUB'], CCR['CMP'],   True),
]


def imm_fetch(sz, dest):
    """Leave the immediate operand in `dest`."""
    if sz == 'LONG':
        u(comment='immediate, high word',
          asrc=SRC['IRC'], alu=ALU['A'], dst=dest,
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
        u(comment='immediate, low word',
          asrc=SRC['IRC'], alu=ALU['A'],
          dst=DST['DBUF_SHW'] if dest == DST['DBUF'] else DST['T1_SHW'],
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
    else:
        u(comment='immediate word',
          asrc=SRC['IRC'], alu=ALU['A'], dst=dest,
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])


def imm_group():
    for iname, opbits, aluop, ccr_rule, is_cmp in IMM_GROUP:
        for sz in ('BYTE', 'WORD', 'LONG'):
            # CMPI reads but does not write, so it reaches the data addressing
            # modes; the rest need a destination they can alter.
            modes = DATA_ALT
            for name, mode, reg in modes:
                lbl = '%s_%s_%s' % (iname, sz.lower(), name)
                label(lbl)
                imm_fetch(sz, DST['DBUF'])
                if name == 'dn':
                    u(comment='%s.%s #,Dn' % (iname.upper(), sz[0]),
                      asrc=SRC['DBUF'], bsrc=SRC['REG'], rsel=RSEL['EA_D'],
                      easel=EASEL['SRC'], alu=aluop,
                      dst=DST['NONE'] if is_cmp else DST['REG'],
                      size=SIZE[sz], ccr=ccr_rule,
                      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                      pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
                else:
                    move_src_fetch(name, sz, EASEL['SRC'])
                    if is_cmp:
                        u(comment='CMPI.%s #,<memory>: flags only' % sz[0],
                          asrc=SRC['DBUF'], bsrc=SRC['T1'], alu=aluop,
                          size=SIZE[sz], ccr=ccr_rule,
                          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                          pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
                    else:
                        u(comment='combine, prefetch, then write back',
                          asrc=SRC['DBUF'], bsrc=SRC['T1'], alu=aluop,
                          dst=DST['DBUF'], size=SIZE[sz], ccr=ccr_rule,
                          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                          pf=PF['ADVFETCH'])
                        rmw_store(name, sz)
                opcode(pattern('0000' + opbits + SIZE_BITS[sz], mode, reg),
                       lbl, '%s.%s %s' % (iname.upper(), sz[0], name))


# ==========================================================================
# ADDQ and SUBQ -- PRM section 4
#
#   0101 ddd 0 ss mmmrrr   ADDQ      0101 ddd 1 ss mmmrrr   SUBQ
#
# ddd is the operand, one to eight, with zero meaning eight. Shape: r P w, with
# no extension word to fetch.
#
# An address register destination is a special case in two ways: the operation
# is always at long size whatever the size field says, and it sets no condition
# codes at all (PRM section 4).
# ==========================================================================
def addq_subq():
    for iname, dbit, aluop in (('addq', '0', ALU['ADD']),
                               ('subq', '1', ALU['SUB'])):
        for sz in ('BYTE', 'WORD', 'LONG'):
            modes = DATA_ALT if sz == 'BYTE' else [M_DN, M_AN] + MEM_ALT
            for name, mode, reg in modes:
                lbl = '%s_%s_%s' % (iname, sz.lower(), name)
                label(lbl)
                if name == 'an':
                    u(comment='%s.%s #,An: long, and no flags'
                              % (iname.upper(), sz[0]),
                      asrc=SRC['QUICK'], bsrc=SRC['REG'], rsel=RSEL['EA_A'],
                      easel=EASEL['SRC'], alu=aluop, dst=DST['REG_L'],
                      size=SIZE['LONG'],
                      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                      pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
                elif name == 'dn':
                    u(comment='%s.%s #,Dn' % (iname.upper(), sz[0]),
                      asrc=SRC['QUICK'], bsrc=SRC['REG'], rsel=RSEL['EA_D'],
                      easel=EASEL['SRC'], alu=aluop, dst=DST['REG'],
                      size=SIZE[sz], ccr=CCR['ARITH'],
                      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                      pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
                else:
                    move_src_fetch(name, sz, EASEL['SRC'])
                    u(comment='combine, prefetch, then write back',
                      asrc=SRC['QUICK'], bsrc=SRC['T1'], alu=aluop,
                      dst=DST['DBUF'], size=SIZE[sz], ccr=CCR['ARITH'],
                      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                      pf=PF['ADVFETCH'])
                    rmw_store(name, sz)
                opcode(pattern('0101---' + dbit + SIZE_BITS[sz], mode, reg),
                       lbl, '%s.%s %s' % (iname.upper(), sz[0], name))


# ==========================================================================
# EXT, SWAP, LEA and PEA -- PRM section 4
# ==========================================================================
def ext_swap():
    label('ext_w')
    u(comment='EXT.W: sign-extend the low byte into the low word',
      asrc=SRC['REG'], rsel=RSEL['EA_D'], easel=EASEL['SRC'],
      alu=ALU['SXB'], dst=DST['REG'], size=SIZE['WORD'], ccr=CCR['LOGIC'],
      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'],
      seq=SEQ['DECODE'])
    opcode('0100100010000---', 'ext_w', 'EXT.W')

    label('ext_l')
    u(comment='EXT.L: sign-extend the low word into the whole register',
      asrc=SRC['REG'], rsel=RSEL['EA_D'], easel=EASEL['SRC'],
      alu=ALU['SXW'], dst=DST['REG'], size=SIZE['LONG'], ccr=CCR['LOGIC'],
      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'],
      seq=SEQ['DECODE'])
    opcode('0100100011000---', 'ext_l', 'EXT.L')

    label('swap')
    u(comment='SWAP: exchange the halves, flags over the whole result',
      asrc=SRC['REG'], rsel=RSEL['EA_D'], easel=EASEL['SRC'],
      alu=ALU['SWAP'], dst=DST['REG'], size=SIZE['LONG'], ccr=CCR['LOGIC'],
      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'],
      seq=SEQ['DECODE'])
    opcode('0100100001000---', 'swap', 'SWAP')


def lea_pea():
    for name, mode, reg in CONTROL:
        lbl = 'lea_%s' % name
        label(lbl)
        if name == 'aind':
            u(comment='LEA (An),Am: the address is the register',
              asrc=SRC['REG'], rsel=RSEL['EA_A'], easel=EASEL['SRC'],
              alu=ALU['A'], dst=DST['REG_L'], wsel=WSEL['IR9_A'],
              size=SIZE['LONG'],
              bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
              pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
        else:
            ea_setup(name, 'LONG', EASEL['SRC'], is_source=True)
            u(comment='LEA: the computed address, never dereferenced',
              asrc=SRC['T0'], alu=ALU['A'], dst=DST['REG_L'],
              wsel=WSEL['IR9_A'], size=SIZE['LONG'],
              bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
              pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
        opcode(pattern('0100---111', mode, reg), lbl, 'LEA %s' % name)

    for name, mode, reg in CONTROL:
        lbl = 'pea_%s' % name
        label(lbl)
        # Where the instruction's own prefetch goes depends on the mode, and
        # the reference is unambiguous about it: the absolute modes put it
        # after the two writes and every other control mode puts it before.
        #
        #   PEA (A2)        P w w        PEA (d16,A6)   P P w w
        #   PEA (xxx).W     P w w P      PEA (xxx).L    P P w w P
        absolute = name in ('absw', 'absl')
        if name != 'aind':
            ea_setup(name, 'LONG', EASEL['SRC'], is_source=True)
        src_for_push = SRC['REG'] if name == 'aind' else SRC['T0']

        if not absolute:
            # Buffer the address on the prefetch, because the prefetch
            # replaces ir and with it the register field that names it.
            u(comment='PEA: prefetch, buffering the address first',
              asrc=src_for_push, rsel=RSEL['EA_A'], easel=EASEL['SRC'],
              alu=ALU['A'], dst=DST['DBUF'], size=SIZE['LONG'],
              bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
              pf=PF['ADVFETCH'])
            u(comment='make room, high word at the new top of stack',
              bus=BUS['WRITE'], asel=ASEL['EA'], fc=FC['DATA'],
              aeasel=AEASEL['SP'], aupd=AUPD['PRE'], size=SIZE['LONG'], dhi=1)
            u(comment='low word above it, and end',
              bus=BUS['WRITE'], asel=ASEL['EAL_PLUS2'], fc=FC['DATA'],
              size=SIZE['LONG'], dhi=0, seq=SEQ['DECODE'])
        else:
            u(comment='make room, buffer the address, high word out',
              asrc=src_for_push, alu=ALU['A'], dst=DST['DBUF'],
              bus=BUS['WRITE'], asel=ASEL['EA'], fc=FC['DATA'],
              aeasel=AEASEL['SP'], aupd=AUPD['PRE'], size=SIZE['LONG'], dhi=1)
            u(comment='low word above it',
              bus=BUS['WRITE'], asel=ASEL['EAL_PLUS2'], fc=FC['DATA'],
              size=SIZE['LONG'], dhi=0)
            final_prefetch()
        opcode(pattern('0100100001', mode, reg), lbl, 'PEA %s' % name)


# ==========================================================================
# Shifts and rotates -- PRM section 4
#
#   1110 ccc d ss i tt rrr    on a data register, by an immediate or a count
#                             held in another register
#   1110 0tt d 11 mmmrrr      on memory, one bit, word size only
#
# tt picks the operation -- 00 arithmetic, 01 logical, 10 through the extend
# bit, 11 plain rotate -- and d the direction. The register forms take one
# clock per bit shifted on the original and one clock in total here, which
# doc/timing-divergences.md records; the bus behaviour is identical either way,
# there being no bus cycle but the prefetch.
# ==========================================================================
SHIFT_KINDS = [('as', '00'), ('ls', '01'), ('rox', '10'), ('ro', '11')]
SHIFT_KIND_NUM = {'as': 0, 'ls': 1, 'rox': 2, 'ro': 3}


def shifts():
    # -- the register forms -------------------------------------------------
    for kname, ttbits in SHIFT_KINDS:
        for dname, dbit in (('r', '0'), ('l', '1')):
            shv = (SHIFT_KIND_NUM[kname] << 1) | int(dbit)
            for sz in ('BYTE', 'WORD', 'LONG'):
                for iname, ibit in (('imm', '0'), ('reg', '1')):
                    lbl = '%s%s_%s_%s' % (kname, dname, sz.lower(), iname)
                    label(lbl)
                    u(comment='%s%s.%s Dn, count from %s'
                              % (kname.upper(), dname.upper(), sz[0], iname),
                      bsrc=SRC['REG'], rsel=RSEL['EA_D'], easel=EASEL['SRC'],
                      alu=ALU['SHIFT'], sh=shv, dst=DST['REG'],
                      size=SIZE[sz], ccr=CCR['SHIFT'],
                      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                      pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
                    opcode('1110---' + dbit + SIZE_BITS[sz] + ibit + ttbits +
                           '---', lbl,
                           '%s%s.%s' % (kname.upper(), dname.upper(), sz[0]))

    # -- the memory forms: one bit, word size ------------------------------
    for kname, ttbits in SHIFT_KINDS:
        for dname, dbit in (('r', '0'), ('l', '1')):
            shv = (SHIFT_KIND_NUM[kname] << 1) | int(dbit)
            for name, mode, reg in MEM_ALT:
                lbl = '%s%s_mem_%s' % (kname, dname, name)
                label(lbl)
                move_src_fetch(name, 'WORD', EASEL['SRC'])
                u(comment='shift by one, prefetch, then write back',
                  bsrc=SRC['T1'], alu=ALU['SHIFT'], sh=shv, shone=1,
                  dst=DST['DBUF'],
                  size=SIZE['WORD'], ccr=CCR['SHIFT'],
                  bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                  pf=PF['ADVFETCH'])
                rmw_store(name, 'WORD')
                # 1110 0tt d 11 mmmrrr: bits 11:9 are 0tt, bit 8 the
                # direction, bits 7:6 the size field pinned to 11.
                opcode(pattern('1110' + '0' + ttbits + dbit + '11', mode, reg),
                       lbl, '%s%s <memory>' % (kname.upper(), dname.upper()))


# ==========================================================================
# The bit operations -- PRM section 4
#
#   0000 rrr 1 tt mmmrrr   bit number in a data register
#   0000 1000 tt mmmrrr    bit number in the extension word
#
# tt: 00 BTST, 01 BCHG, 10 BCLR, 11 BSET.
#
# The operand is a long when the destination is a data register and a byte
# otherwise, and the bit number is reduced modulo that width. Only Z is
# touched, and it reflects the bit as it was *before* any change.
#
# BTST does not write, so it reaches the read-only addressing modes; the other
# three are read-modify-write and need a destination they can alter.
# ==========================================================================
BIT_OPS = [
    ('btst', '00', None,          False),
    ('bchg', '01', ALU['EOR'],    True),
    ('bclr', '10', ALU['ANDN'],   True),
    ('bset', '11', ALU['OR'],     True),
]


def bit_ops():
    for iname, ttbits, aluop, writes in BIT_OPS:
        for form, imm in (('dyn', 0), ('imm', 1)):
            modes = DATA_ALT if writes else DATA_ALT + [M_PCDISP, M_PCIDX]
            if not writes and form == 'dyn':
                modes = DATA_ALT + [M_PCDISP, M_PCIDX]
            for name, mode, reg in modes:
                lbl = '%s_%s_%s' % (iname, form, name)
                label(lbl)
                sz = 'LONG' if name == 'dn' else 'BYTE'
                if imm:
                    # The bit number is in the extension word already sitting
                    # in irc. Turn it into a mask and park it in the data
                    # output buffer before this microword's own prefetch
                    # replaces the word it came from.
                    u(comment='the bit number, as a mask, before it is lost',
                      asrc=SRC['BITMASK'], bitimm=1, alu=ALU['A'],
                      dst=DST['DBUF'], size=SIZE[sz],
                      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                      pf=PF['FETCH'])
                mask_src = SRC['DBUF'] if imm else SRC['BITMASK']
                if name == 'dn':
                    u(comment='%s.L #,Dn' % iname.upper(),
                      asrc=mask_src, bsrc=SRC['REG'], rsel=RSEL['EA_D'],
                      easel=EASEL['SRC'], bitimm=imm,
                      alu=aluop if writes else ALU['B'],
                      dst=DST['REG'] if writes else DST['NONE'],
                      size=SIZE[sz], ccr=CCR['BIT'],
                      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                      pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
                else:
                    move_src_fetch(name, sz, EASEL['SRC'])
                    if writes:
                        u(comment='modify, prefetch, then write back',
                          asrc=mask_src, bsrc=SRC['T1'], bitimm=imm,
                          alu=aluop, dst=DST['DBUF'],
                          size=SIZE[sz], ccr=CCR['BIT'],
                          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                          pf=PF['ADVFETCH'])
                        rmw_store(name, sz)
                    else:
                        u(comment='BTST: the flag only',
                          asrc=mask_src, bsrc=SRC['T1'], bitimm=imm,
                          alu=ALU['B'], size=SIZE[sz], ccr=CCR['BIT'],
                          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                          pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
                if imm:
                    opcode(pattern('00001000' + ttbits, mode, reg), lbl,
                           '%s #,%s' % (iname.upper(), name))
                else:
                    opcode(pattern('0000---1' + ttbits, mode, reg), lbl,
                           '%s Dn,%s' % (iname.upper(), name))


# ==========================================================================
# Scc and NEGX -- PRM section 4
#
#   0101 cccc 11 mmmrrr    Scc: all ones if the condition holds, else zero
#   0100 0000 ss mmmrrr    NEGX: 0 - operand - X
#
# Scc's shape on memory is r P w -- it reads the operand it is about to
# overwrite, which is the same thing an MC68000 CLR does. Unlike CLR, UM
# section 9 does not list Scc among the MC68010's improvements, so the read
# stays.
#
# NEGX leaves Z alone when its result is zero rather than setting it, so that
# a multi-precision negation reads as zero only if every word of it did.
# ==========================================================================
def scc():
    for name, mode, reg in DATA_ALT:
        lbl = 'scc_%s' % name
        label(lbl)
        if name == 'dn':
            u(comment='Scc Dn',
              asrc=SRC['SCC'], alu=ALU['A'], dst=DST['REG'],
              rsel=RSEL['EA_D'], easel=EASEL['SRC'], size=SIZE['BYTE'],
              bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
              pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
        else:
            move_src_fetch(name, 'BYTE', EASEL['SRC'])
            u(comment='the condition, prefetch, then write it',
              asrc=SRC['SCC'], alu=ALU['A'], dst=DST['DBUF'],
              size=SIZE['BYTE'],
              bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
              pf=PF['ADVFETCH'])
            rmw_store(name, 'BYTE')
        opcode(pattern('0101----11', mode, reg), lbl, 'Scc %s' % name)


def negx():
    for sz in ('BYTE', 'WORD', 'LONG'):
        for name, mode, reg in DATA_ALT:
            lbl = 'negx_%s_%s' % (sz.lower(), name)
            label(lbl)
            if name == 'dn':
                u(comment='NEGX.%s Dn' % sz[0],
                  asrc=SRC['REG'], rsel=RSEL['EA_D'], easel=EASEL['SRC'],
                  bsrc=SRC['ZERO'], alu=ALU['SUBX'], dst=DST['REG'],
                  size=SIZE[sz], ccr=CCR['ARITHX'],
                  bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                  pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
            else:
                move_src_fetch(name, sz, EASEL['SRC'])
                u(comment='negate with borrow, prefetch, then write back',
                  asrc=SRC['T1'], bsrc=SRC['ZERO'], alu=ALU['SUBX'],
                  dst=DST['DBUF'], size=SIZE[sz], ccr=CCR['ARITHX'],
                  bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
                  pf=PF['ADVFETCH'])
                rmw_store(name, sz)
            opcode(pattern('01000000' + SIZE_BITS[sz], mode, reg), lbl,
                   'NEGX.%s %s' % (sz[0], name))


# ==========================================================================
# TAS -- PRM section 4, UM 5.1.3
#
#   0100 1010 11 mmmrrr
#
# The one instruction that uses the indivisible read-modify-write bus cycle:
# the operand is read, bit 7 set, and the result written back without AS ever
# being negated, so no other master can get between the two halves.
#
# Shape on memory: r w P -- the two halves of the one cycle, then the prefetch.
#
# The condition codes describe the operand as it was read, not the result:
# the result always has bit 7 set, so taking N from it would make N always one.
# ==========================================================================
def tas():
    for name, mode, reg in DATA_ALT:
        lbl = 'tas_%s' % name
        label(lbl)
        if name == 'dn':
            u(comment='TAS Dn',
              asrc=SRC['REG'], rsel=RSEL['EA_D'], easel=EASEL['SRC'],
              bsrc=SRC['BIT7'], alu=ALU['OR'], dst=DST['REG'],
              size=SIZE['BYTE'], ccr=CCR['LOGIC_A'],
              bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
              pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
        else:
            ea_setup(name, 'BYTE', EASEL['SRC'], is_source=True)
            asel_v = (ASEL['EA'] if name in ('aind', 'apost', 'apre')
                      else ASEL['T0'])
            u(comment='the indivisible cycle: read, set bit 7, write back',
              asrc=SRC['RDATA_B'], bsrc=SRC['BIT7'], alu=ALU['OR'],
              dst=DST['DBUF'], size=SIZE['BYTE'], ccr=CCR['LOGIC_A'],
              rsel=RSEL['EA_A'], easel=EASEL['SRC'],
              aupd=ea_aupd(name, 'BYTE', False),
              bus=BUS['RMW'], asel=asel_v, fc=FC['DATA'])
            final_prefetch()
        opcode(pattern('0100101011', mode, reg), lbl, 'TAS %s' % name)


# ==========================================================================
# Control flow -- PRM section 4
#
# The reference's shapes, which fix where the prefetches go relative to the
# stack traffic and which the microcode below reproduces:
#
#   BSR     w w P P     push the return address, then refill from the target
#   JSR     P w w P     one prefetch from the target, the push, then the other
#   JMP     P P         no stack traffic at all
#   RTS     r r P P     pop the return address, then refill
#   RTR     r r r P P   the condition codes come off the stack first
#   LINK    P w w P     the displacement, the push, then the prefetch
#   UNLK    r r P       pop into the register, then prefetch
#   DBcc    P P         two prefetches, taken or not
#
# A push writes the high word at SP-4 and the low word at SP-2, which is the
# same order PEA uses and the opposite of MOVE.L to -(An).
# ==========================================================================
def branch_target(long_form):
    """T0 <- the branch target. The displacement base is always irc_pc."""
    if long_form:
        u(comment='target = irc_pc + the displacement word',
          asrc=SRC['IRC_PC'], bsrc=SRC['IRC_SX'], alu=ALU['ADD'], dst=DST['T0'])
    else:
        u(comment='target = irc_pc + the displacement byte',
          asrc=SRC['IRC_PC'], bsrc=SRC['IR_SXB'], alu=ALU['ADD'], dst=DST['T0'])


def refill_from(addr_src):
    """Load the program counter and refill both halves of the prefetch pipe."""
    u(comment='take the branch',
      asrc=addr_src, alu=ALU['A'], dst=DST['PC'])
    u(comment='fill irc from the new stream',
      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
    u(comment='fill ir and irc, then decode',
      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'],
      seq=SEQ['DECODE'])


def bcc():
    """Bcc, in both displacement forms.

    A conditional microword lands on `next` or `next+1`, so the two arms have
    to start as a pair of adjacent microwords at an even address. Each is a
    single word that jumps on to the rest of its arm.

    The target is computed on the testing microword whether the branch is taken
    or not: it costs nothing when it is not, and it keeps a taken branch to two
    internal cycles, which is what the reference charges.
    """
    for form, long_form in (('b', False), ('w', True)):
        lbl_arms = 'bcc_%s_arms' % form
        label('bcc_%s' % form)
        if long_form:
            u(comment='test the condition, and compute the target meanwhile',
              asrc=SRC['IRC_PC'], bsrc=SRC['IRC_SX'], alu=ALU['ADD'],
              dst=DST['T0'],
              cond=COND['CC'], seq=SEQ['COND'], goto=lbl_arms)
        else:
            u(comment='test the condition, and compute the target meanwhile',
              asrc=SRC['IRC_PC'], bsrc=SRC['IR_SXB'], alu=ALU['ADD'],
              dst=DST['T0'],
              cond=COND['CC'], seq=SEQ['COND'], goto=lbl_arms)

        label(lbl_arms, align_even=True)
        u(comment='not taken', goto='bcc_%s_fall' % form)
        u(comment='taken', goto='bcc_%s_take' % form)

        label('bcc_%s_fall' % form)
        if long_form:
            u(comment='step over the displacement word',
              bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
        final_prefetch('on to the next instruction')

        label('bcc_%s_take' % form)
        refill_from(SRC['T0'])

    # 0000 and 0001 in the condition field are BRA and BSR, whose patterns are
    # registered before these and so win.
    opcode('0110----00000000', 'bcc_w', 'Bcc.W')
    opcode('0110------------', 'bcc_b', 'Bcc.B')


def dbcc():
    """DBcc: test, decrement, and branch while the counter has not run out.

    Two conditional microwords, each with its own pair of arms. The decrement
    and the test of its result are one microword, because the condition looks
    at the value on its way to the register rather than at the register.
    """
    label('dbcc')
    u(comment='test the condition',
      cond=COND['CC'], seq=SEQ['COND'], goto='dbcc_arms')

    label('dbcc_arms', align_even=True)
    u(comment='condition false: try the counter', goto='dbcc_count')
    u(comment='condition true: fall through', goto='dbcc_fall')

    label('dbcc_count')
    u(comment='decrement the counter word, and test what it becomes',
      asrc=SRC['ONE'], bsrc=SRC['REG'], rsel=RSEL['EA_D'], easel=EASEL['SRC'],
      alu=ALU['SUB'], dst=DST['REG'], size=SIZE['WORD'],
      cond=COND['CNT'], seq=SEQ['COND'], goto='dbcc_cnt_arms')

    label('dbcc_cnt_arms', align_even=True)
    u(comment='counter still running: branch', goto='dbcc_take')
    u(comment='counter ran out: fall through', goto='dbcc_fall')

    label('dbcc_fall')
    u(comment='step over the displacement word',
      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
    final_prefetch('on to the next instruction')

    label('dbcc_take')
    u(comment='target = irc_pc + the displacement word',
      asrc=SRC['IRC_PC'], bsrc=SRC['IRC_SX'], alu=ALU['ADD'], dst=DST['T0'])
    refill_from(SRC['T0'])

    opcode('0101----11001---', 'dbcc', 'DBcc')


def bsr():
    for form, long_form, ret_off in (('b', False, 0), ('w', True, 2)):
        lbl = 'bsr_%s' % form
        label(lbl)
        branch_target(long_form)
        # The return address is the word after the instruction: irc_pc for the
        # byte form, two further on for the word form, whose displacement is an
        # extension word.
        if ret_off:
            u(comment='the return address, and room on the stack for it',
              asrc=SRC['IRC_PC'], bsrc=SRC['TWO'], alu=ALU['ADD'],
              dst=DST['DBUF'],
              aeasel=AEASEL['SP'], aupd=AUPD['PRE'], size=SIZE['LONG'])
        else:
            u(comment='the return address, and room on the stack for it',
              asrc=SRC['IRC_PC'], alu=ALU['A'], dst=DST['DBUF'],
              aeasel=AEASEL['SP'], aupd=AUPD['PRE'], size=SIZE['LONG'])
        u(comment='high word at the new top of stack',
          bus=BUS['WRITE'], asel=ASEL['EAL'], fc=FC['DATA'],
          size=SIZE['LONG'], dhi=1)
        u(comment='low word above it',
          bus=BUS['WRITE'], asel=ASEL['EAL_PLUS2'], fc=FC['DATA'],
          size=SIZE['LONG'], dhi=0)
        refill_from(SRC['T0'])
    opcode('0110000100000000', 'bsr_w', 'BSR.W')
    opcode('01100001--------', 'bsr_b', 'BSR.B')


def jmp_jsr():
    for name, mode, reg in CONTROL:
        lbl = 'jmp_%s' % name
        label(lbl)
        if name == 'aind':
            u(comment='JMP (An): the target is the register',
              asrc=SRC['REG'], rsel=RSEL['EA_A'], easel=EASEL['SRC'],
              alu=ALU['A'], dst=DST['PC'])
        else:
            ea_setup_nopf(name, EASEL['SRC'])
            u(comment='JMP: the computed target',
              asrc=SRC['T0'], alu=ALU['A'], dst=DST['PC'])
        u(comment='fill irc from the new stream',
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
        u(comment='fill ir and irc, then decode',
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'],
          seq=SEQ['DECODE'])
        opcode(pattern('0100111011', mode, reg), lbl, 'JMP %s' % name)

    for name, mode, reg in CONTROL:
        lbl = 'jsr_%s' % name
        label(lbl)
        ea_setup_nopf(name, EASEL['SRC'])
        # The return address is the word after the whole instruction, so it
        # depends on how many extension words there were. Compute it before
        # the program counter moves.
        ret_a, ret_b = jump_return_src(name)
        if ret_b is None:
            u(comment='the return address',
              asrc=ret_a, alu=ALU['A'], dst=DST['DBUF'])
        else:
            u(comment='the return address, past both extension words',
              asrc=ret_a, bsrc=ret_b, alu=ALU['ADD'], dst=DST['DBUF'])
        if name == 'aind':
            u(comment='the target',
              asrc=SRC['REG'], rsel=RSEL['EA_A'], easel=EASEL['SRC'],
              alu=ALU['A'], dst=DST['PC'])
        else:
            u(comment='the target',
              asrc=SRC['T0'], alu=ALU['A'], dst=DST['PC'])
        # One refill from the target, then the push, then the other: the
        # reference's order.
        u(comment='first refill from the target',
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
        u(comment='make room on the stack, high word out',
          bus=BUS['WRITE'], asel=ASEL['EA'], fc=FC['DATA'],
          aeasel=AEASEL['SP'], aupd=AUPD['PRE'], size=SIZE['LONG'], dhi=1)
        u(comment='low word above it',
          bus=BUS['WRITE'], asel=ASEL['EAL_PLUS2'], fc=FC['DATA'],
          size=SIZE['LONG'], dhi=0)
        u(comment='second refill, and decode',
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'],
          seq=SEQ['DECODE'])
        opcode(pattern('0100111010', mode, reg), lbl, 'JSR %s' % name)


# ==========================================================================
# RTS, RTR, LINK and UNLK -- PRM section 4
#
#   RTS   r r P P       pop the return address, then refill from it
#   RTR   r r r P P     the condition codes come off the stack first
#   LINK  P w w P       the displacement, the push, then the prefetch
#   UNLK  r r P         pop into the register, then prefetch
#
# A pop reads the high word at (SP) and the low word at (SP)+2, and the stack
# pointer moves by the whole amount once.
# ==========================================================================
def rts_rtr():
    label('rts')
    u(comment='return address, high word',
      asrc=SRC['RDATA'], alu=ALU['A'], dst=DST['T1'],
      bus=BUS['READ'], asel=ASEL['EA'], fc=FC['DATA'],
      aeasel=AEASEL['SP'], size=SIZE['LONG'])
    u(comment='and the low word; the stack pointer moves by four',
      asrc=SRC['RDATA'], alu=ALU['A'], dst=DST['T1_SHW'],
      bus=BUS['READ'], asel=ASEL['EA_PLUS2'], fc=FC['DATA'],
      aeasel=AEASEL['SP'], aupd=AUPD['POST'], size=SIZE['LONG'])
    refill_from(SRC['T1'])
    opcode('0100111001110101', 'rts', 'RTS')

    label('rtr')
    # The condition codes are the low byte of the word at the top of stack;
    # the supervisor half of the status register is untouched (PRM section 4).
    u(comment='the saved condition codes',
      asrc=SRC['RDATA'], alu=ALU['A'], dst=DST['CCR'],
      bus=BUS['READ'], asel=ASEL['EA'], fc=FC['DATA'],
      aeasel=AEASEL['SP'], size=SIZE['WORD'])
    u(comment='return address, high word',
      asrc=SRC['RDATA'], alu=ALU['A'], dst=DST['T1'],
      bus=BUS['READ'], asel=ASEL['EA_PLUS2'], fc=FC['DATA'],
      aeasel=AEASEL['SP'], size=SIZE['LONG'])
    u(comment='and the low word; the stack pointer moves by six in all',
      asrc=SRC['RDATA'], alu=ALU['A'], dst=DST['T1_SHW'],
      bus=BUS['READ'], asel=ASEL['EA_PLUS4'], fc=FC['DATA'],
      aeasel=AEASEL['SP'], aupd=AUPD['POST6'], size=SIZE['LONG'])
    refill_from(SRC['T1'])
    opcode('0100111001110111', 'rtr', 'RTR')


def link_unlk():
    label('link')
    # LINK An,#d: push An, put the stack pointer in An, then add the
    # displacement to it.
    #
    # The displacement has to be taken out of irc before this microword's own
    # prefetch replaces it, which is why it goes to a working register rather
    # than being read where it is used.
    u(comment='the displacement, before the prefetch overwrites it',
      asrc=SRC['IRC_SX'], alu=ALU['A'], dst=DST['T1'], size=SIZE['LONG'],
      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
    u(comment='make room, and the high word of An out',
      asrc=SRC['REG'], rsel=RSEL['EA_A'], easel=EASEL['SRC'],
      alu=ALU['A'], dst=DST['DBUF'],
      bus=BUS['WRITE'], asel=ASEL['EA'], fc=FC['DATA'],
      aeasel=AEASEL['SP'], aupd=AUPD['PRE'], size=SIZE['LONG'], dhi=1)
    u(comment='the low word, and An takes the new top of stack',
      asrc=SRC['EAL'], alu=ALU['A'], dst=DST['REG_L'],
      rsel=RSEL['EA_A'], easel=EASEL['SRC'],
      bus=BUS['WRITE'], asel=ASEL['EAL_PLUS2'], fc=FC['DATA'],
      size=SIZE['LONG'], dhi=0)
    u(comment='and the stack pointer moves by the displacement',
      asrc=SRC['EAL'], bsrc=SRC['T1'], alu=ALU['ADD'], dst=DST['REG_L'],
      wsel=WSEL['A7'], size=SIZE['LONG'],
      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'],
      seq=SEQ['DECODE'])
    opcode('0100111001010---', 'link', 'LINK')

    label('unlk')
    # UNLK An: the stack pointer takes An, then An is popped from it.
    u(comment='the saved register, high word, read through An itself',
      asrc=SRC['RDATA'], alu=ALU['A'], dst=DST['T1'],
      bus=BUS['READ'], asel=ASEL['EA'], fc=FC['DATA'],
      rsel=RSEL['EA_A'], easel=EASEL['SRC'], size=SIZE['LONG'])
    u(comment='and the low word; An itself moves by four',
      asrc=SRC['RDATA'], alu=ALU['A'], dst=DST['T1_SHW'],
      bus=BUS['READ'], asel=ASEL['EA_PLUS2'], fc=FC['DATA'],
      aupd=AUPD['POST'], size=SIZE['LONG'])
    u(comment='the stack pointer takes what An became, then An is restored',
      asrc=SRC['REG'], rsel=RSEL['EA_A'], easel=EASEL['SRC'],
      alu=ALU['A'], dst=DST['REG_L'], wsel=WSEL['A7'], size=SIZE['LONG'])
    u(comment='An takes the popped value',
      asrc=SRC['T1'], alu=ALU['A'], dst=DST['REG_L'],
      rsel=RSEL['EA_A'], easel=EASEL['SRC'], size=SIZE['LONG'],
      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'],
      seq=SEQ['DECODE'])
    opcode('0100111001011---', 'unlk', 'UNLK')


# ==========================================================================
# Exception processing -- UM section 6
#
# The MC68010's four-word frame (figure 6-6), and the reason every MC68000
# vector that reaches exception processing is skipped by the sweep rather than
# compared: an MC68000 pushes three words and has no format field at all.
#
#   SP+0   status register, as it was when the exception began
#   SP+2   program counter, high
#   SP+4   program counter, low
#   SP+6   0000 and the vector offset, which is the vector number times four
#
# One shared tail does the whole of it. Each exception sets up three things and
# jumps to it:
#
#   T1     the program counter to stack, which is the faulting instruction for
#          the ones that are the instruction's own fault and the next one for
#          the ones the instruction asked for
#   T0     the vector table address, VBR + vector*4
#   DBUF   the format-and-offset word
#
# The order the four words are written in is this design's own: no reference
# available records it for an MC68010, only the resulting memory, which is what
# software sees and which is exactly right. doc/divergences.md says so.
# ==========================================================================
def exception_tail():
    label('except')
    u(comment='supervisor mode on, trace off, the old status register kept',
      dst=DST['SR_EXC'])
    label('except_frame')
    u(comment='room for four words on the supervisor stack',
      aeasel=AEASEL['SP'], aupd=AUPD['PRE8'], size=SIZE['LONG'])
    # The format word is already in the buffer: the caller put it there,
    # because only the caller knows which vector this is.
    u(comment='the format and vector offset, at the top of the frame',
      bus=BUS['WRITE'], asel=ASEL['EAL_PLUS6'], fc=FC['DATA'],
      size=SIZE['WORD'], dhi=0)
    u(comment='the program counter, low word',
      asrc=SRC['T1'], alu=ALU['A'], dst=DST['DBUF'], dhi=0,
      bus=BUS['WRITE'], asel=ASEL['EAL_PLUS4'], fc=FC['DATA'],
      size=SIZE['LONG'])
    u(comment='and its high word',
      bus=BUS['WRITE'], asel=ASEL['EAL_PLUS2'], fc=FC['DATA'],
      size=SIZE['LONG'], dhi=1)
    u(comment='the saved status register, at the bottom of the frame',
      asrc=SRC['SRSAVE'], alu=ALU['A'], dst=DST['DBUF'],
      bus=BUS['WRITE'], asel=ASEL['EAL'], fc=FC['DATA'], size=SIZE['WORD'])
    u(comment='the vector, high word',
      asrc=SRC['RDATA'], alu=ALU['A'], dst=DST['T1'],
      bus=BUS['READ'], asel=ASEL['T0'], fc=FC['DATA'], size=SIZE['LONG'])
    u(comment='and its low word',
      asrc=SRC['RDATA'], alu=ALU['A'], dst=DST['T1_SHW'],
      bus=BUS['READ'], asel=ASEL['T0_PLUS2'], fc=FC['DATA'], size=SIZE['LONG'])
    refill_from(SRC['T1'])


def raise_exception(name, vector, use_next_pc, vsel=0):
    """Set up the three things the shared tail needs, and jump to it."""
    u(comment='the vector table address',
      asrc=SRC['VBR'], bsrc=SRC['VECOFF'], alu=ALU['ADD'], dst=DST['T0'],
      vec=vector, vsel=vsel)
    # The instruction's own address for a fault, the next instruction's for an
    # exception the instruction asked for (UM section 6).
    u(comment='the program counter to stack',
      asrc=SRC['IRC_PC'] if use_next_pc else SRC['IR_PC'],
      alu=ALU['A'], dst=DST['T1'])
    u(comment='the format and vector word', goto='except',
      asrc=SRC['FMTVEC'], alu=ALU['A'], dst=DST['DBUF'],
      vec=vector, vsel=vsel)


def traps():
    # The unrecognised opcodes. `illegal` is where the decoder sends anything
    # with no pattern, so it has to be an exception now rather than a stall.
    label('illegal_exc')
    raise_exception('illegal', 4, False)
    opcode('0100101011111100', 'illegal_exc', 'ILLEGAL')

    label('line_a')
    raise_exception('line_a', 10, False)
    opcode('1010------------', 'line_a', 'line A')

    label('line_f')
    raise_exception('line_f', 11, False)
    opcode('1111------------', 'line_f', 'line F')

    # TRAP #n takes vector 32+n and stacks the following instruction.
    label('trap')
    raise_exception('trap', 0, True, vsel=1)
    opcode('010011100100----', 'trap', 'TRAP')

    # TRAPV traps only when the overflow flag is set, and falls through when
    # it is not.
    label('trapv')
    u(comment='test the overflow flag', cond=COND['V'], seq=SEQ['COND'],
      goto='trapv_arms')
    label('trapv_arms', align_even=True)
    u(comment='no overflow: nothing happens', goto='trapv_fall')
    u(comment='overflow: take the exception', goto='trapv_take')
    label('trapv_fall')
    final_prefetch('TRAPV with V clear is a very slow NOP')
    label('trapv_take')
    raise_exception('trapv', 7, True)
    opcode('0100111001110110', 'trapv', 'TRAPV')


# ==========================================================================
# The privileged instructions and RTE -- PRM section 6, UM section 6
#
# A privileged instruction checks the supervisor bit before it does anything.
# The check is three microwords -- a conditional and its two arms -- generated
# in front of each one rather than shared as a subroutine, because the arms
# have to be adjacent and a shared version would need a return address the
# sequencer does not have.
# ==========================================================================
def privileged(lbl):
    """Emit the supervisor check in front of `lbl`_body."""
    u(comment='privileged: check the supervisor bit',
      cond=COND['SUPER'], seq=SEQ['COND'], goto='%s_arms' % lbl)
    label('%s_arms' % lbl, align_even=True)
    u(comment='user mode: privilege violation', goto='priv_violation')
    u(comment='supervisor mode: go ahead', goto='%s_body' % lbl)
    label('%s_body' % lbl)


def priv_violation():
    label('priv_violation')
    raise_exception('privilege', 8, False)


def rte():
    label('rte')
    privileged('rte')
    # Read the whole frame before committing to any of it, so that a bad
    # format code leaves the stack exactly as it was (UM 6.4).
    u(comment='the saved status register',
      asrc=SRC['RDATA'], alu=ALU['A'], dst=DST['T0'],
      bus=BUS['READ'], asel=ASEL['EA'], fc=FC['DATA'],
      aeasel=AEASEL['SP'], size=SIZE['WORD'])
    u(comment='the saved program counter, high word',
      asrc=SRC['RDATA'], alu=ALU['A'], dst=DST['T1'],
      bus=BUS['READ'], asel=ASEL['EA_PLUS2'], fc=FC['DATA'],
      aeasel=AEASEL['SP'], size=SIZE['LONG'])
    u(comment='and its low word',
      asrc=SRC['RDATA'], alu=ALU['A'], dst=DST['T1_SHW'],
      bus=BUS['READ'], asel=ASEL['EA_PLUS4'], fc=FC['DATA'],
      aeasel=AEASEL['SP'], size=SIZE['LONG'])
    u(comment='the format word, and the check on it',
      bus=BUS['READ'], asel=ASEL['EA_PLUS6'], fc=FC['DATA'],
      aeasel=AEASEL['SP'], size=SIZE['WORD'],
      cond=COND['FMT0'], seq=SEQ['COND'], goto='rte_fmt_arms')

    label('rte_fmt_arms', align_even=True)
    u(comment='a format code we do not know', goto='rte_format_error')
    u(comment='the four-word frame', goto='rte_ok')

    label('rte_ok')
    u(comment='the frame is good: release it',
      aeasel=AEASEL['SP'], aupd=AUPD['POST8'], size=SIZE['LONG'])
    u(comment='restore the status register, which may change the stack',
      asrc=SRC['T0'], alu=ALU['A'], dst=DST['SR_ALL'])
    refill_from(SRC['T1'])

    label('rte_format_error')
    # UM 6.4: the stack pointer is not updated, so the handler still has the
    # frame it could not use.
    raise_exception('format error', 14, False)

    opcode('0100111001110011', 'rte', 'RTE')


# ==========================================================================
# The status register instructions -- PRM sections 4 and 6
#
# MOVE from SR is privileged on the MC68010 and was not on the MC68000, which
# is the divergence the sweep skips user-mode vectors for. MOVE from CCR is an
# MC68010 addition and is not privileged.
# ==========================================================================
def sr_instructions():
    # MOVE from SR: 0100 0000 11 mmmrrr, privileged.
    for name, mode, reg in DATA_ALT:
        lbl = 'movefromsr_%s' % name
        label(lbl)
        privileged(lbl)
        if name == 'dn':
            u(comment='MOVE SR,Dn',
              asrc=SRC['SR'], alu=ALU['A'], dst=DST['REG'],
              rsel=RSEL['EA_D'], easel=EASEL['SRC'], size=SIZE['WORD'],
              bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
              pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
        else:
            # It reads the destination first, unlike CLR: UM section 9 lists
            # CLR among the MC68010's improvements and does not list this, and
            # the reference reads here too.
            move_src_fetch(name, 'WORD', EASEL['SRC'])
            u(comment='the status register, prefetch, then write it',
              asrc=SRC['SR'], alu=ALU['A'], dst=DST['DBUF'], size=SIZE['WORD'],
              bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
              pf=PF['ADVFETCH'])
            rmw_store(name, 'WORD')
        opcode(pattern('0100000011', mode, reg), lbl, 'MOVE SR,%s' % name)

    # MOVE from CCR: 0100 0010 11 mmmrrr, an MC68010 addition, not privileged.
    for name, mode, reg in DATA_ALT:
        lbl = 'movefromccr_%s' % name
        label(lbl)
        if name == 'dn':
            u(comment='MOVE CCR,Dn',
              asrc=SRC['CCRVAL'], alu=ALU['A'], dst=DST['REG'],
              rsel=RSEL['EA_D'], easel=EASEL['SRC'], size=SIZE['WORD'],
              bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
              pf=PF['ADVFETCH'], seq=SEQ['DECODE'])
        else:
            move_src_fetch(name, 'WORD', EASEL['SRC'])
            u(comment='the condition codes, prefetch, then write them',
              asrc=SRC['CCRVAL'], alu=ALU['A'], dst=DST['DBUF'],
              size=SIZE['WORD'],
              bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'],
              pf=PF['ADVFETCH'])
            rmw_store(name, 'WORD')
        opcode(pattern('0100001011', mode, reg), lbl, 'MOVE CCR,%s' % name)

    # MOVE to CCR: 0100 0100 11 mmmrrr, not privileged.
    for name, mode, reg in DATA_ALL:
        lbl = 'movetoccr_%s' % name
        label(lbl)
        ea_read_operand(name, 'WORD', EASEL['SRC'])
        u(comment='MOVE <ea>,CCR: the low byte only',
          asrc=SRC['T1'], alu=ALU['A'], dst=DST['CCR'])
        sr_refetch()
        final_prefetch()
        opcode(pattern('0100010011', mode, reg), lbl, 'MOVE %s,CCR' % name)

    # MOVE to SR: 0100 0110 11 mmmrrr, privileged.
    for name, mode, reg in DATA_ALL:
        lbl = 'movetosr_%s' % name
        label(lbl)
        privileged(lbl)
        ea_read_operand(name, 'WORD', EASEL['SRC'])
        u(comment='MOVE <ea>,SR: the whole register',
          asrc=SRC['T1'], alu=ALU['A'], dst=DST['SR_ALL'])
        sr_refetch()
        final_prefetch()
        opcode(pattern('0100011011', mode, reg), lbl, 'MOVE %s,SR' % name)


def sr_refetch():
    """The word already in irc, read again.

    MOVE to SR and MOVE to CCR both do it, and it is plainly visible: the
    reference reads pc-2 before its prefetch and the program counter ends only
    two further on, not four. Writing the status register can change the
    privilege mode, and re-reading the word the pipe already holds is how the
    part makes sure it was fetched in whatever mode now applies.
    """
    u(comment='re-read the word already in the pipe, in the new mode',
      bus=BUS['READ'], asel=ASEL['PC_MINUS2'], fc=FC['PROG'], pf=PF['NONE'])


def sr_store(name, src):
    """Write a status-register word out to memory, without reading first."""
    if name in ('aind', 'apost', 'apre'):
        upd = {'aind': AUPD['LATCH'], 'apost': AUPD['POST'],
               'apre': AUPD['PRE']}[name]
        u(comment='prefetch, and latch the address',
          asrc=src, alu=ALU['A'], dst=DST['DBUF'], size=SIZE['WORD'],
          aupd=upd, aeasel=AEASEL['SRC'], rsel=RSEL['EA_A'],
          easel=EASEL['SRC'],
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'])
    else:
        u(comment='prefetch; the address is already in T0',
          asrc=src, alu=ALU['A'], dst=DST['DBUF'], size=SIZE['WORD'],
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'])
    rmw_store(name, 'WORD')


# ==========================================================================
# The immediate-to-status-register forms, MOVE USP, RESET, STOP and CHK
# ==========================================================================
SR_IMM = [('ori', '0000', ALU['OR']), ('andi', '0010', ALU['AND']),
          ('eori', '1010', ALU['EOR'])]


def sr_immediates():
    for iname, opbits, aluop in SR_IMM:
        # to CCR: the low byte only, and not privileged.
        lbl = '%s_to_ccr' % iname
        label(lbl)
        u(comment='%s #,CCR' % iname.upper(),
          asrc=SRC['IRC'], bsrc=SRC['CCRVAL'], alu=aluop, dst=DST['CCR'],
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
        sr_refetch()
        final_prefetch()
        opcode('0000' + opbits + '00111100', lbl, '%s to CCR' % iname.upper())

        # to SR: the whole register, and privileged.
        lbl = '%s_to_sr' % iname
        label(lbl)
        privileged(lbl)
        u(comment='%s #,SR' % iname.upper(),
          asrc=SRC['IRC'], bsrc=SRC['SR'], alu=aluop, dst=DST['SR_ALL'],
          bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['FETCH'])
        sr_refetch()
        final_prefetch()
        opcode('0000' + opbits + '01111100', lbl, '%s to SR' % iname.upper())


def move_usp():
    label('move_to_usp')
    privileged('move_to_usp')
    u(comment='MOVE An,USP',
      asrc=SRC['REG'], rsel=RSEL['EA_A'], easel=EASEL['SRC'],
      alu=ALU['A'], dst=DST['USP'], size=SIZE['LONG'],
      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'],
      seq=SEQ['DECODE'])
    opcode('0100111001100---', 'move_to_usp', 'MOVE An,USP')

    label('move_from_usp')
    privileged('move_from_usp')
    u(comment='MOVE USP,An',
      asrc=SRC['USP'], alu=ALU['A'], dst=DST['REG_L'],
      rsel=RSEL['EA_A'], easel=EASEL['SRC'], size=SIZE['LONG'],
      bus=BUS['READ'], asel=ASEL['PC'], fc=FC['PROG'], pf=PF['ADVFETCH'],
      seq=SEQ['DECODE'])
    opcode('0100111001101---', 'move_from_usp', 'MOVE USP,An')


def reset_stop():
    # RESET asserts the pin for 124 clock periods and changes nothing inside
    # (UM 5.5). The bus unit does the timing; this starts it and waits.
    label('reset_i')
    privileged('reset_i')
    u(comment='start the 124-clock output pulse', rstreq=1)
    label('reset_wait', align_even=True)
    u(comment='wait for it', cond=COND['RSTB'], seq=SEQ['COND'],
      goto='reset_arms')
    label('reset_arms', align_even=True)
    u(comment='pulse finished', goto='reset_done')
    u(comment='still running', goto='reset_wait')
    label('reset_done')
    final_prefetch()
    opcode('0100111001110000', 'reset_i', 'RESET')

    # STOP loads the status register and waits for an interrupt. The sequencer
    # holds on the marked microword until one arrives, and then takes it
    # instead of moving on.
    label('stop')
    privileged('stop')
    u(comment='the immediate word into the status register',
      asrc=SRC['IRC'], alu=ALU['A'], dst=DST['SR_ALL'])
    label('stop_wait')
    u(comment='wait here until an interrupt arrives', stop=1)
    opcode('0100111001110010', 'stop', 'STOP')


def chk():
    """CHK: trap if the register is negative or above the bound."""
    for name, mode, reg in DATA_ALL:
        lbl = 'chk_%s' % name
        label(lbl)
        ea_read_operand(name, 'WORD', EASEL['SRC'])
        u(comment='is the register negative?',
          asrc=SRC['ZERO'], bsrc=SRC['REG2'], alu=ALU['SUB'],
          size=SIZE['WORD'], ccr=CCR['CMP'],
          cond=COND['N'], seq=SEQ['COND'], goto='%s_arms' % lbl)
        label('%s_arms' % lbl, align_even=True)
        u(comment='not negative: check the upper bound', goto='%s_upper' % lbl)
        u(comment='negative: trap', goto='chk_trap')
        label('%s_upper' % lbl)
        # PRM section 4 leaves Z, V and C undefined after CHK and defines N
        # only for the two trapping cases. The reference's behaviour is that
        # the flags come from the first test and the second leaves them alone,
        # so that is what this does.
        u(comment='is it above the bound? flags unchanged by this one',
          asrc=SRC['REG2'], bsrc=SRC['T1'], alu=ALU['SUB'],
          size=SIZE['WORD'],
          cond=COND['N'], seq=SEQ['COND'], goto='%s_uarms' % lbl)
        label('%s_uarms' % lbl, align_even=True)
        u(comment='within the bound: nothing happens', goto='%s_ok' % lbl)
        u(comment='above it: trap', goto='chk_trap')
        label('%s_ok' % lbl)
        final_prefetch()
        opcode(pattern('0100---110', mode, reg), lbl, 'CHK %s' % name)

    label('chk_trap')
    raise_exception('CHK', 6, True)


def interrupt():
    """The interrupt sequence -- UM 5.1.4 and section 6.

    The acknowledge cycle runs in CPU space with the level on A1-A3 and every
    other address line high. A device that answers with DTACK supplies its own
    vector number on the data bus; one that answers with VPA is asking for the
    autovector for its level.
    """
    label('interrupt')
    u(comment='supervisor mode, trace off, mask raised to this level',
      dst=DST['SR_IRQ'])
    u(comment='the acknowledge address: the level, and ones everywhere else',
      asrc=SRC['IRQVEC'], alu=ALU['A'], dst=DST['T0'])
    u(comment='the acknowledge cycle, in CPU space',
      bus=BUS['IACK'], asel=ASEL['T0'], fc=FC['CPU'], size=SIZE['WORD'])
    u(comment='the vector table address, from whichever vector came back',
      asrc=SRC['VBR'], bsrc=SRC['VECOFF'], alu=ALU['ADD'], dst=DST['T0'],
      vsel=2)
    u(comment='the program counter to stack is the instruction not run',
      asrc=SRC['IRQPC'], alu=ALU['A'], dst=DST['T1'])
    u(comment='the format and vector word', goto='except_irq',
      asrc=SRC['FMTVEC'], alu=ALU['A'], dst=DST['DBUF'], vsel=2)

    # The shared tail sets the supervisor bit again, which is harmless, but it
    # would also overwrite the saved status register -- so an interrupt uses
    # its own copy of the tail's first step, taken before the mask was raised.
    label('except_irq')
    u(comment='into the shared frame builder', goto='except_frame')


def trace():
    """The trace exception, taken after an instruction that ran with T set."""
    label('trace')
    raise_exception('trace', 9, False)
