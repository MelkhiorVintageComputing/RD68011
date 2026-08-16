#!/usr/bin/env python3
"""Summarise the bus-cycle shape of an opcode's reference vectors.

    python3 tools/harte/shapes.py ADD.w 010

Groups clean tests by their sequence of bus cycles -- P for a program read,
r/w for a data read or write -- so the microcode for a whole instruction group
can be written from what the reference actually does rather than discovered one
failing test at a time.

The optional second argument filters by the source mode field (bits 5:3), and a
third by the destination mode field (bits 8:6).
"""

import sys
import os
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reader                                          # noqa: E402


def shape(t):
    out = []
    for x in t['transactions']:
        if x[0] == 'n':
            continue
        prog = x[2] in (2, 6)
        if x[0] == 'r':
            out.append('P' if prog else 'r')
        elif x[0] == 'w':
            out.append('w')
        else:
            return None            # address error: a different shape entirely
    return ' '.join(out)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    op = sys.argv[1]
    smode = sys.argv[2] if len(sys.argv) > 2 else None
    dmode = sys.argv[3] if len(sys.argv) > 3 else None

    counts = Counter()
    example = {}
    for t in reader.read_opcode(op):
        o = t['initial']['prefetch'][0]
        if smode is not None and ((o >> 3) & 7) != int(smode, 2):
            continue
        if dmode is not None and ((o >> 6) & 7) != int(dmode, 2):
            continue
        s = shape(t)
        if s is None:
            continue
        key = (s, t['length'])
        counts[key] += 1
        example.setdefault(key, t['name'])

    for (s, cycles), n in counts.most_common(14):
        print('  %-28s %3d cycles  %5d tests   %s' % (s, cycles, n,
                                                      example[(s, cycles)]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
