#!/usr/bin/env python3
"""Find the first place the RTL and Musashi stop agreeing.

    python3 tools/cosim/compare.py <rtl trace> <musashi trace>

Both traces are one line per instruction, printed at the boundary that starts
it: address, status register, D0-D7, A0-A7. The RTL's comes from
sim/tb/core_program_tb.sv and Musashi's from tools/cosim/musashi_trace.c.

What is compared is architectural state and nothing else. Musashi is an
instruction-set simulator: it has no bus cycles, no prefetch pipe and no cycle
counts, so it can say nothing about the half of this project that is bus
behaviour -- but it is an independent implementation of the other half, written
by somebody else from the same manuals, and running a real program against it
asks a question no single-instruction vector can.

Two things are deliberately not compared.

The condition codes PRM section 4 marks undefined -- N and V after any of the
BCD instructions -- because two implementations are entitled to disagree about
them, and they do: this one's answers came from the reference vectors, which
are MAME's MC68000, and Musashi's came from wherever Musashi's did. The opcode
in each line is there so this can be masked exactly where the manual says it is
undefined and nowhere else, and the count of how often it mattered is printed.

And the condition codes of the very first instruction. UM 5.5 says what reset
does -- the interrupt mask goes to seven, the supervisor bit is set, and on the
MC68010 the vector base register is cleared -- and says nothing about the
condition codes, so they are undefined there too. Every program under
sim/programs/ sets them with its first instruction, so this matters for one
line.
"""

import sys

FIELDS = (['pc', 'op', 'sr'] +
          ['d%d' % i for i in range(8)] +
          ['a%d' % i for i in range(8)])

# The condition codes PRM section 4 marks undefined, by the instruction that
# leaves them that way. Two implementations are entitled to disagree about
# these, and this one's answers come from the reference vectors -- MAME's
# MC68000 -- where Musashi's come from wherever Musashi's do.
#
# Masked against the *previous* line's opcode, because a line shows the flags
# the instruction before it produced.
CC_N = 0x0008
CC_Z = 0x0004
CC_V = 0x0002

UNDEFINED = [
    # (mask, match, bits, what)
    (0xF1F0, 0xC100, CC_N | CC_V, 'ABCD'),
    (0xF1F0, 0x8100, CC_N | CC_V, 'SBCD'),
    (0xFFC0, 0x4800, CC_N | CC_V, 'NBCD'),
]


def undefined_bits(op):
    bits = 0
    for mask, match, b, _ in UNDEFINED:
        if (op & mask) == match:
            bits |= b
    return bits


def read(path):
    out = []
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) == len(FIELDS):
                out.append(parts)
    return out


def main():
    if len(sys.argv) != 3:
        sys.stderr.write(__doc__)
        return 2
    rtl = read(sys.argv[1])
    ref = read(sys.argv[2])

    if not rtl or not ref:
        print('error: %s is empty' % (sys.argv[1] if not rtl else sys.argv[2]))
        return 1

    n = min(len(rtl), len(ref))
    masked = 0
    for i in range(n):
        a, b = rtl[i], ref[i]
        bad = []
        # What the instruction before this line left undefined.
        srmask = 0xFFFF
        if i == 0:
            # Reset leaves the condition codes undefined; see the docstring.
            srmask = 0xFFE0
        else:
            u = undefined_bits(int(rtl[i - 1][1], 16))
            if u:
                srmask = 0xFFFF & ~u
        for j, name in enumerate(FIELDS):
            av, bv = a[j], b[j]
            if name == 'sr' and srmask != 0xFFFF:
                if (int(av, 16) ^ int(bv, 16)) & ~srmask:
                    masked += 1
                av, bv = ('%04x' % (int(av, 16) & srmask),
                          '%04x' % (int(bv, 16) & srmask))
            if av != bv:
                bad.append((name, av, bv))
        if bad:
            print('divergence at instruction %d, pc %s' % (i, a[0]))
            for k in range(max(0, i - 3), i):
                print('  ok   %s' % ' '.join(rtl[k]))
            print('  rtl  %s' % ' '.join(a))
            print('  ref  %s' % ' '.join(b))
            print('  differs in: ' +
                  ', '.join('%s rtl=%s ref=%s' % t for t in bad))
            return 1

    if len(rtl) != len(ref):
        print('agreed for %d instructions, then the traces ran out at '
              'different lengths: rtl %d, ref %d'
              % (n, len(rtl), len(ref)))
        # Not a failure by itself: the two stop for their own reasons once the
        # program has written its result.
    if masked:
        print('cosim: %d instructions, every register the same '
              '(%d undefined condition codes not compared)' % (n, masked))
    else:
        print('cosim: %d instructions, every register the same' % n)
    return 0


if __name__ == '__main__':
    sys.exit(main())
