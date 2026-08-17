#!/usr/bin/env python3
"""The AC electrical specifications, as data.

    python3 tools/timing/specs.py --dump read-write
    python3 tools/timing/specs.py --dump read-write --grade 10

`Inputs/doc/MC68030_Doc_More_Readable/MC68000UM_split/ac-electrical-specifications.csv`
is 158 rows transcribed from section 10 of the user manual, and the transcription
was done honestly: where the manual is wrong, the printed value is what landed in
the file, with the `note` column saying what is wrong with it. That is the right
policy for a transcription and the wrong one for a checker, so the judgement about
which printed values to believe lives here, in one place, with its citations.

Everything downstream reads limits through `limits()` and never touches the CSV.

WHY THE LIMITS LIVE IN PYTHON AND NOT IN GENERATED SYSTEMVERILOG

The testbenches emit measurements -- times in nanoseconds -- and nothing else.
They do not know what a specification is. That split matters for three reasons:

  * The fragile part of this job is deciding which two events a specification
    measures between, and that lives in anchors.py. Compiling it into a
    simulation image would make a wrong anchor cost an elaboration instead of a
    one-line edit.
  * Re-analysis over a recorded log is milliseconds; re-elaboration under xsim is
    minutes. Six grades times two designs times several pad corners is a lot of
    re-analysis and very little re-simulation.
  * One of the two designs is simulated through VHDL. A SystemVerilog header of
    limits would be dead weight on that side, and dead weight everywhere if the
    flow ever has to split across two simulators.
"""

import argparse
import csv
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CSV_PATH = os.path.join(
    ROOT, 'Inputs', 'doc', 'MC68030_Doc_More_Readable', 'MC68000UM_split',
    'ac-electrical-specifications.csv')

# The speed grades, in the order the manual prints them. '16.67' is the column
# the manual heads "16.67 MHz 12F"; '16' is the separate plain 16 MHz column
# that exists only in the MC68000/08/10 tables. They are different parts, not a
# rounding of each other, and several specifications differ between them.
GRADES = ['8', '10', '12.5', '16.67', '16', '20']

_COL = {'8': 'f8', '10': 'f10', '12.5': 'f12_5',
        '16.67': 'f16_67', '16': 'f16', '20': 'f20'}

# Minimum cycle time from specification 1, which is what a grade *means*.
PERIOD_NS = {'8': 125.0, '10': 100.0, '12.5': 80.0,
             '16.67': 60.0, '16': 60.0, '20': 50.0}


class Defect(object):
    """A printed value this checker declines to believe, and why."""

    def __init__(self, table, num, grade, field, printed, corrected, why):
        self.table = table
        self.num = num
        self.grade = grade
        self.field = field          # 'min' or 'max'
        self.printed = printed
        self.corrected = corrected
        self.why = why


# Every correction applied to the source, each with the citation that justifies
# it. Nothing else in this package second-guesses a printed number.
DEFECTS = [
    Defect('read-write', '23', '16.67', 'max', 550.0, 50.0,
           "Section 10.10 prints 550 ns for 'Clock Low to Data-Out Valid' at "
           "16.67 MHz. Section 10.11 gives 50 ns for the same specification at "
           "the same grade, and every other grade is between 25 and 62 ns. The "
           "CSV's own note column marks it SOURCE ERROR. A 550 ns limit on a "
           "60 ns cycle is not a limit."),
    Defect('bus-arbitration', '46', None, 'unit', 'ns', 'Clks',
           "Section 10.10 prints the unit of 'BGACK Width Low' as ns, giving a "
           "minimum width of 1.5 ns. Section 10.12 gives the same specification "
           "in Clks. The CSV's note column marks it SOURCE ERROR."),
]

# Rows the manual prints as one line covering two specification numbers. A
# lookup for either number has to find the shared row; keying only on the
# printed string would silently miss both.
ALIASES = {'2': '2, 3', '3': '2, 3', '4': '4, 5', '5': '4, 5'}

# Numbers that simply do not exist anywhere in section 10. Asking for one is a
# bug in the caller, not an empty result.
ABSENT = {'10', '19', '24', '52'}


class Spec(object):
    def __init__(self, row):
        self.table = row['table']
        self.num = row['num']
        self.characteristic = row['characteristic']
        self.unit = row['unit']
        self.note = row['note']
        self.printed_page = row['printed_page']
        self._row = row

    def __repr__(self):
        return '<Spec %s/%s %r>' % (self.table, self.num, self.characteristic)


def _num(text):
    text = (text or '').strip()
    if not text or text == '-':
        return None
    try:
        return float(text)
    except ValueError:
        return None


class Specs(object):
    def __init__(self, path=CSV_PATH):
        self.path = path
        self.rows = []
        with open(path) as f:
            for row in csv.DictReader(f):
                self.rows.append(Spec(row))
        self.applied = []

    def find(self, table, num):
        num = ALIASES.get(num, num)
        for s in self.rows:
            if s.table == table and s.num == num:
                return s
        if num in ABSENT:
            raise KeyError(
                'specification %s does not exist in section 10 (the numbering '
                'has gaps at 10, 19, 24 and 52)' % num)
        raise KeyError('no specification %s in table %r' % (num, table))

    def unit(self, table, num):
        s = self.find(table, num)
        for d in DEFECTS:
            if d.table == table and d.num == s.num and d.field == 'unit':
                return d.corrected
        return s.unit

    def limits(self, table, num, grade):
        """(min, max) for one specification at one grade, corrections applied.

        Either may be None, meaning the manual gives no limit in that
        direction. The unit is whatever `unit()` reports -- usually ns, but
        Clks for the arbitration handshake, and the caller has to care.
        """
        if grade not in _COL:
            raise KeyError('unknown grade %r; have %s' % (grade, GRADES))
        s = self.find(table, num)
        col = _COL[grade]
        lo = _num(s._row[col + '_min'])
        hi = _num(s._row[col + '_max'])
        for d in DEFECTS:
            if d.table != table or d.num != s.num or d.field not in ('min', 'max'):
                continue
            if d.grade is not None and d.grade != grade:
                continue
            if d.field == 'max' and hi == d.printed:
                hi = d.corrected
                self.applied.append((s.num, grade, d))
            elif d.field == 'min' and lo == d.printed:
                lo = d.corrected
                self.applied.append((s.num, grade, d))
        return lo, hi


def _fmt(lo, hi):
    if lo is None and hi is None:
        return '--'
    if lo is None:
        return '<= %g' % hi
    if hi is None:
        return '>= %g' % lo
    return '%g - %g' % (lo, hi)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--dump', metavar='TABLE', default='read-write',
                    help='which of the seven tables to print')
    ap.add_argument('--grade', default=None,
                    help='one grade, or all six if omitted')
    ap.add_argument('--csv', default=CSV_PATH)
    args = ap.parse_args(argv)

    sp = Specs(args.csv)
    grades = [args.grade] if args.grade else GRADES

    rows = [s for s in sp.rows if s.table == args.dump]
    if not rows:
        sys.stderr.write('no table %r; have %s\n' % (
            args.dump, sorted(set(s.table for s in sp.rows))))
        return 2

    print('%s (%d rows), limits in the unit named' % (args.dump, len(rows)))
    print('%-5s %-46s %-6s %s' % (
        'spec', 'characteristic', 'unit',
        ' '.join('%-14s' % ('%s MHz' % g) for g in grades)))
    for s in rows:
        cells = []
        for g in grades:
            lo, hi = sp.limits(s.table, s.num, g)
            cells.append('%-14s' % _fmt(lo, hi))
        print('%-5s %-46s %-6s %s' % (
            s.num, s.characteristic[:46], sp.unit(s.table, s.num),
            ' '.join(cells)))

    if sp.applied:
        print('\ncorrections applied:')
        seen = set()
        for num, grade, d in sp.applied:
            key = (num, d.field, grade)
            if key in seen:
                continue
            seen.add(key)
            print('  spec %s at %s MHz: %s %s -> %s' % (
                num, grade, d.field, d.printed, d.corrected))
            for line in d.why.split('. '):
                if line.strip():
                    print('      %s' % line.strip().rstrip('.') + '.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
