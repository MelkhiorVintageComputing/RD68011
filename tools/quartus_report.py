#!/usr/bin/env python3
"""Pull the headline numbers out of a Quartus fit report, and gate on Fmax.

    quartus_report.py <rd68011.fit.rpt> [<fmax.rpt> <floor-MHz>]

`make quartus` prints them so that the fit says something useful without anyone
opening the reports, in the same shape `make impl` prints Vivado's.

With an fmax.rpt and a floor, it also fails when the measured Fmax falls below
the floor. That is the gate for this flow: the 48 ns in scripts/rd68011.sdc is
the Artix-7 target and this part does not reach it, so slack against it says
nothing, while a drop in Fmax against a number measured here is a regression.

Both reports are tables of `; label ; value ;` rows, which is stable across
Quartus versions in a way the panel API is not.
"""

import re
import sys

FMAX = re.compile(r'^;\s*([0-9.]+)\s*MHz\s*;')


def fmax_of(path):
    """The first Fmax in a report_clock_fmax_summary panel, in MHz."""
    with open(path, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            m = FMAX.match(line)
            if m:
                return float(m.group(1))
    return None

WANTED = [
    ('Device', 'device'),
    ('Total logic elements', 'logic elements'),
    ('Total registers', 'registers'),
    ('Total memory bits', 'memory bits'),
    ('Embedded Multiplier 9-bit elements', '9-bit multipliers'),
    ('Total pins', 'pins'),
]


def row(line):
    """A report row's label and first value, or None.

    Rows are `; label ; value ;` -- except the ones that are not, because some
    tables carry a third empty column and the value has to be the second field
    rather than the last.
    """
    if not line.startswith(';'):
        return None
    parts = [p.strip() for p in line.rstrip('\n').split(';')]
    if len(parts) < 3:
        return None
    return parts[1], parts[2]


def main(path):
    found = {}
    with open(path, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            r = row(line)
            if r is None:
                continue
            label, value = r
            for want, _ in WANTED:
                if label == want and want not in found:
                    found[want] = value

    if not found:
        print('quartus_report: no resource rows in %s' % path, file=sys.stderr)
        return 1

    parts = []
    for want, name in WANTED:
        if want in found:
            parts.append('%s %s' % (name, found[want]))
    print('RD68011: ' + ', '.join(parts))
    return 0


def check_fmax(path, floor):
    got = fmax_of(path)
    if got is None:
        print('quartus_report: no Fmax row in %s' % path, file=sys.stderr)
        return 1
    print('RD68011: Fmax %.2f MHz, floor %.2f' % (got, floor))
    if got < floor:
        print('RD68011: Fmax BELOW THE FLOOR -- doc/implementation.md has the '
              'number this was measured at')
        return 1
    return 0


if __name__ == '__main__':
    if len(sys.argv) not in (2, 4):
        print('usage: quartus_report.py <rd68011.fit.rpt> [<fmax.rpt> <floor>]',
              file=sys.stderr)
        sys.exit(2)
    rc = main(sys.argv[1])
    if rc == 0 and len(sys.argv) == 4:
        rc = check_fmax(sys.argv[2], float(sys.argv[3]))
    sys.exit(rc)
