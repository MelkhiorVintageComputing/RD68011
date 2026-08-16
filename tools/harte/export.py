#!/usr/bin/env python3
"""Export SingleStepTests vectors as a flat hex stream a testbench can read.

    python3 tools/harte/export.py NOP [count] > build/vectors/NOP.hex

The RTL testbench reads this with $fscanf("%h"), so the format is nothing but a
sequence of hex numbers, interpreted positionally:

    ntests
    per test:
      index                       the test's position in the source file
      d0..d7 a0..a6 usp ssp sr pc     19 initial registers
      pf0 pf1                     initial prefetch: ir and irc
      nram, then nram pairs of (word address, word)   initial memory
      d0..d7 a0..a6 usp ssp sr pc     19 final registers
      pf0 pf1                     final prefetch
      nfram, then nfram pairs     final memory
      ntrans, then ntrans triples of (kind, fc, word address)
                                  kind: 1 write, 2 read, 3 TAS, 4/5 address error

Memory is exported as words rather than bytes because that is how the bus
works: the vectors store 16-bit values and split them into byte pairs on the way
out, and this puts them back together.

Idle entries in the transaction list are dropped -- they carry no address, and a
testbench that watches AS cannot see them anyway. Cycle counts are checked
separately, from the instruction boundary, not from this list.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reader                                          # noqa: E402

REGS = reader.REG_ORDER


def words(state):
    """Fold the vector's byte list back into word address -> word."""
    out = {}
    for addr, val in state['ram']:
        wa = addr >> 1
        cur = out.get(wa, 0)
        if addr & 1:
            out[wa] = (cur & 0xFF00) | val
        else:
            out[wa] = (cur & 0x00FF) | (val << 8)
    return out


def emit(t, index, out):
    w = out.write
    w('%x\n' % index)
    for r in REGS:
        w('%x ' % t['initial'][r])
    w('\n')
    w('%x %x\n' % (t['initial']['prefetch'][0], t['initial']['prefetch'][1]))

    ini = words(t['initial'])
    w('%x\n' % len(ini))
    for wa in sorted(ini):
        w('%x %x\n' % (wa, ini[wa]))

    for r in REGS:
        w('%x ' % t['final'][r])
    w('\n')
    w('%x %x\n' % (t['final']['prefetch'][0], t['final']['prefetch'][1]))

    fin = words(t['final'])
    w('%x\n' % len(fin))
    for wa in sorted(fin):
        w('%x %x\n' % (wa, fin[wa]))

    tr = [x for x in t['transactions'] if x[0] != 'n']
    kind = {'w': 1, 'r': 2, 't': 3, 're': 4, 'we': 5}
    w('%x\n' % len(tr))
    for x in tr:
        w('%x %x %x\n' % (kind[x[0]], x[2], x[3] >> 1))


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    op = sys.argv[1]
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 0

    tests = []
    for i, t in enumerate(reader.read_opcode(op)):
        tests.append((i, t))
        if limit and len(tests) >= limit:
            break

    out = sys.stdout
    out.write('%x\n' % len(tests))
    for i, t in tests:
        emit(t, i, out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
