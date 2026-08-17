#!/usr/bin/env python3
"""Compare this design's bus transactions with the Suska WF68K10's.

    python3 tools/suska/compare.py <ours> <suska>

Both files are one line per bus cycle -- `CYCLE <addr> <rw> <fc> <ds>` -- from
sim/suska/rd68011_bus_tb.sv and sim/suska/wf68k10_tb.vhd running the same
image.

Two things are compared, and one deliberately is not.

**The data accesses**, in order: address, direction and address space. These are
what the program asked for, and two implementations of the same instruction set
have to agree about them exactly.

**The program reads**, as a set. Not in order, because the order they interleave
with the data accesses is a property of the prefetch pipe, and the two pipes are
different depths -- Suska's entity has a NO_PIPELINE generic and by default runs
deeper than the MC68010's three words. Ours is fixed by the reference vectors,
which compare the whole transaction list of 23492 tests exactly; Suska's is its
own. doc/suska-crosscheck.md has the measurement.

**Not the timing.** Suska runs a two-clock bus cycle with AS asserting on a
falling edge where the manual's is four clocks with AS asserting on a rising
one. Nothing about the S0-S7 ruler can be corroborated from it, which was the
original hope for this cross-check and is its most useful finding.
"""

import sys

PROGRAM_SPACE = ('010', '110')
DATA_SPACE    = ('001', '101')


def read(path):
    out = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) >= 4 and p[0] == 'CYCLE' and p[1] != 'END':
                out.append((p[1], p[2], p[3]))
    return out


def main():
    if len(sys.argv) != 3:
        sys.stderr.write(__doc__)
        return 2
    ours = read(sys.argv[1])
    ref  = read(sys.argv[2])
    if not ours or not ref:
        print('error: one of the traces is empty')
        return 1

    # Compare only as far as the shorter of the two got.
    n = min(len(ours), len(ref))
    ours, ref = ours[:n], ref[:n]

    od = [c for c in ours if c[2] in DATA_SPACE]
    rd = [c for c in ref  if c[2] in DATA_SPACE]
    op = sorted(c for c in ours if c[2] in PROGRAM_SPACE)
    rp = sorted(c for c in ref  if c[2] in PROGRAM_SPACE)

    # The data accesses have to be the same sequence, except where Suska is
    # known to differ. Truncated to the shorter of the two, since they ran for
    # the same number of cycles rather than the same number of instructions.
    m = min(len(od), len(rd))
    bad = []
    swaps = 0
    i = 0
    while i < m:
        if od[i] == rd[i]:
            i += 1
            continue
        # A known divergence: the two words of a long written through -(An).
        # This design writes the low word first, at the higher address, which
        # is what the reference vectors record and what the whole MOVE.l sweep
        # compares cycle by cycle. Suska writes the high word first. Same two
        # accesses, opposite order.
        if (i + 1 < m and od[i] == rd[i + 1] and od[i + 1] == rd[i] and
                od[i][1] == '0' and od[i + 1][1] == '0'):
            swaps += 1
            i += 2
            continue
        bad.append((i, od[i], rd[i]))
        i += 1
        if len(bad) >= 5:
            break

    if bad:
        print('suska: %d data accesses differ beyond the known divergences:' %
              len(bad))
        for i, a, b in bad:
            print('  %4d  ours %s   suska %s' % (i, ' '.join(a), ' '.join(b)))
    else:
        print('suska: %d data accesses, same addresses in the same order, '
              'read and written the same way' % m)
    if swaps:
        print('suska: %d long writes through -(An) in the opposite word order, '
              'which is a known divergence' % swaps)

    common = len(set(op) & set(rp))
    only_ours = len(set(op) - set(rp))
    only_ref  = len(set(rp) - set(op))
    print('suska: %d program reads in common; %d only ours, %d only Suska '
          '(the pipes are different depths)' % (common, only_ours, only_ref))

    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
