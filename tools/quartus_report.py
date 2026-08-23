#!/usr/bin/env python3
"""Pull the headline numbers out of a Quartus fit report.

`make quartus` prints them so that the fit says something useful without anyone
opening rd68011.fit.rpt, in the same shape `make impl` prints Vivado's.

The report is a table of `; label ; value ;` rows, which is stable across
Quartus versions in a way its panel API is not.
"""

import sys

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


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print('usage: quartus_report.py <rd68011.fit.rpt>', file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
