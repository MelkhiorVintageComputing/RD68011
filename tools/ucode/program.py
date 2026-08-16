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
                     'ccr', 'aupd', 'aeasel', 'dhi', 'goto'):
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


def ea_asel(name, second=False):
    """Which address the access microword uses."""
    if name in ('aind', 'apost', 'apre'):
        return ASEL['EA_PLUS2'] if second else ASEL['EA']
    return ASEL['T0_PLUS2'] if second else ASEL['T0']


def ea_aupd(name, sz, second):
    """The register modification, on the microword that should carry it."""
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


def move_src_fetch(name, sz, easel_v):
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
    ('absw',   '111', '000'),
    ('absl',   '111', '001'),
    ('pcdisp', '111', '010'),
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
    return words, labels, fixups, patterns, fallthrough
