#!/usr/bin/env python3
"""Judge the measured setup and hold requirements against the specification.

    python3 tools/timing/setup_report.py build/timing/ours.setup

sim/tb/timing/rd68011_setup_tb.sv moves one input a little later on each run and
reports where the behaviour changes:

    MEASURE 47 dtack  latest 187.469 edge 187.500 setup 0.031
    MEASURE 29 datain atmost 0.000
    MEASURE 28 dtack  tolerates 374.969

This turns those into verdicts. The limits live here rather than in the
testbench for the same reason they do in analyse.py: a testbench that knows what
a specification is has to be re-elaborated when the reading of one changes.

WHICH WAY EACH LIMIT RUNS

This is the part worth being careful about, because two of the four run the
opposite way from the other two.

Specifications 27 and 47 are setup times the *system* must provide: at 8 MHz the
memory has to present read data 10 ns before the clock edge. The processor is
conformant if its own requirement is no larger, so a small measured setup is
good and the test is `measured <= limit`.

Specification 29 is a hold time, and its minimum of 0 ns means the system need
not hold read data past the strobes at all. So the processor is conformant if it
needs no hold, and again `measured <= limit`.

Specification 28 is the other way round. Its 240 ns *maximum* is how long the
system may take to negate DTACK, so the processor has to put up with anything up
to that: `measured >= limit`. A processor that gave up at 200 ns would be
broken by a slave the manual explicitly permits.

WHAT IS NOT ASSERTED

That an input arriving later than the threshold is *refused*. Specification 47
obliges the system to be early; it does not oblige the processor to reject a
late input, and a real part very likely accepts one. Asserting that would encode
this implementation's flop into the suite and fail the day somebody added a
synchroniser.
"""

import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import specs

# spec -> (which measured quantity, direction, human description). 'le' means
# the processor's requirement must be no more than the limit; 'ge' means it must
# tolerate at least the limit.
JUDGED = {
    '47': ('setup', 'le', 'min', 'DTACK setup it needs'),
    '27': ('setup', 'le', 'min', 'read-data setup it needs'),
    '29': ('hold',  'le', 'min', 'read-data hold it needs'),
    '28': ('tol',   'ge', 'max', 'stale DTACK it tolerates'),
    # The worst case for the late bus error is a *late* acknowledge, since 48*
    # is a maximum the system is allowed to take: the window has to be at least
    # that wide however late DTACK was. Measured with an early acknowledge too,
    # and that one is reported for context rather than judged.
    '48*late': ('window', 'ge', 'max', 'late BERR window it accepts'),
}

# Rows whose limit lives in the CSV under a different number.
CSV_SPEC = {'48*late': '48*'}

# Judged, but derived rather than bisected: the measurements the other rows
# already produce settle these two, and a bisection for them would only
# rediscover the same numbers.
#
# 31, "DTACK Asserted to Data-In Valid", is a maximum the system is allowed. The
# worst case is an acknowledge as late as specification 47 permits, followed by
# read data as late as 31 permits after it:
#
#     latest legal DTACK  = (the edge that acts on DTACK) - (47 min)
#     latest legal data   = that + (31 max)
#
# and the processor is conformant if that is no later than the latest data it
# was measured to accept, which is what the 27 bisection found.
#
# 29A, "AS, DS Negated to Data-In High Impedance", is also a maximum the system
# is allowed: how long a slave may keep driving the data bus after the strobes
# negate. Nothing the processor samples is at risk -- it read the data two
# states earlier -- so its only exposure is driving the bus into a slave that
# has not let go. It next drives on a write, at the falling edge entering S3,
# and the strobes negated at the falling edge entering S7 of the cycle before:
# S7 to S0, S1, S2, S3 is four half clocks, two whole periods, and that ruler is
# what sim/tb/bus_rw_tb.sv checks. So the room is 2 x period - (29A max).
DERIVED = ('31', '29A')

# Measured and reported, deliberately not judged. See doc/ac-timing.md: the
# number this produces contradicts sim/tb/bus_error_tb.sv, which drives the bus
# unit directly and sees a late bus error recognised where this, driving the
# whole processor, does not. Until that is settled a pass/fail gate would be
# asserting one of two disagreeing measurements, which is worse than none.
REPORTED = {
    '48*': 'late BERR window with an early acknowledge',
}

LINE = re.compile(r'^MEASURE\s+(\S+)\s+(\S+)\s+(.*)$')
HDR = re.compile(r'^#\s+design=(\S+).*period=([0-9.]+)')


def parse(path):
    design, period, rows = os.path.basename(path), None, []
    with open(path) as f:
        for line in f:
            m = HDR.match(line)
            if m:
                design, period = m.group(1), float(m.group(2))
                continue
            m = LINE.match(line)
            if not m:
                continue
            spec, what, rest = m.group(1), m.group(2), m.group(3).split()
            row = {'spec': spec, 'what': what, 'kind': rest[0] if rest else '?'}
            if rest and rest[0] == 'latest':
                row['latest'] = float(rest[1])
                row['edge'] = float(rest[3])
                row['setup'] = float(rest[5])
            elif rest and rest[0] == 'atmost':
                row['hold'] = float(rest[1])
            elif rest and rest[0] == 'needs':
                row['hold'] = float(rest[1])
            elif rest and rest[0] == 'recognises':
                row['window'] = float(rest[1])
                row['fromas'] = float(rest[3])
            elif rest and rest[0] == 'tolerates':
                row['tol'] = float(rest[1])
                row['open'] = len(rest) > 2
            rows.append(row)
    return design, period, rows


def grades_for(period):
    return [g for g in specs.GRADES
            if abs(specs.PERIOD_NS[g] - period) < 1e-6]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('log', nargs='+')
    ap.add_argument('--grade', default=None)
    args = ap.parse_args(argv)

    sp = specs.Specs()
    failed = 0

    for path in args.log:
        design, period, rows = parse(path)
        grades = [args.grade] if args.grade else grades_for(period or 125.0)
        if not grades:
            print('%s: %g ns matches no grade' % (path, period))
            failed += 1
            continue
        # More than one grade can share a cycle time -- 16 and 16.67 MHz are
        # both 60 ns, and differ only in the limit columns. One recording is
        # evidence about both, so judge it against each rather than the first.
        for g in grades:
            failed += report(sp, design, period, rows, g)

    print('setup/hold: %s' % ('%d limit(s) not met' % failed if failed
                              else 'every limit met'))
    return 1 if failed else 0


def derived(sp, rows, g, period):
    """Specifications 31 and 29A, settled from the other rows. See DERIVED."""
    failed = 0
    by = {r['spec']: r for r in rows}

    # 31: the latest legal acknowledge, plus the latest legal data after it,
    # against the latest data the processor was measured to accept.
    lim31 = sp.limits('read-write', '31', g)[1]
    s47, s27 = by.get('47'), by.get('27')
    if lim31 is not None and s47 and s27 and 'edge' in s47 and 'latest' in s27:
        min47 = sp.limits('read-write', '47', g)[0]
        if min47 is not None:
            want = (s47['edge'] - min47) + lim31
            ok = want <= s27['latest'] + 1e-6
            print('%-5s %-26s %10.3f %s%8.3f  %s (derived)'
                  % ('31', 'late data it accepts', s27['latest'], '>=', want,
                     'ok' if ok else 'FAIL'))
            if not ok:
                failed += 1

    # 29A: two whole clock periods before the processor drives the bus itself.
    lim29a = sp.limits('read-write', '29A', g)[1]
    if lim29a is not None:
        got = 2.0 * period
        ok = got >= lim29a - 1e-6
        print('%-5s %-26s %10.3f %s%8.3f  %s (derived)'
              % ('29A', 'bus release it allows', got, '>=', lim29a,
                 'ok' if ok else 'FAIL'))
        if not ok:
            failed += 1
    return failed


def report(sp, design, period, rows, g):
    """One design at one grade. Returns how many limits it missed."""
    failed = 0
    if 1:
        print('=' * 70)
        print('%s at %s MHz (%g ns)' % (design, g, period))
        print('=' * 70)
        print('%-5s %-26s %10s %10s  %s'
              % ('spec', 'what', 'measured', 'limit', 'verdict'))
        print('-' * 70)

        for row in rows:
            spec = row['spec']
            if spec in REPORTED:
                continue
            if spec not in JUDGED:
                continue
            key, sense, side, desc = JUDGED[spec]
            if key not in row:
                print('%-5s %-26s %10s %10s  %s'
                      % (spec, desc, '-', '-', 'not measurable here'))
                continue
            got = row[key]
            lo, hi = sp.limits('read-write', CSV_SPEC.get(spec, spec), g)
            lim = lo if side == 'min' else hi
            if lim is None:
                print('%-5s %-26s %10.3f %10s  %s'
                      % (spec, desc, got, '-', 'no limit given'))
                continue
            ok = (got <= lim + 1e-6) if sense == 'le' else (got >= lim - 1e-6)
            mark = 'ok' if ok else 'FAIL'
            rel = '<=' if sense == 'le' else '>='
            print('%-5s %-26s %10.3f %s%8.3f  %s'
                  % (spec, desc, got, rel, lim, mark))
            if not ok:
                failed += 1

        failed += derived(sp, rows, g, period)

        # The sampling instants, which are the comparable numbers rather than
        # the verdicts: where in the cycle each input is acted on, in ns from AS
        # asserting. This is what can be put beside another processor's.
        note = [r for r in rows if r['spec'] in REPORTED]
        if note:
            print()
            print('measured, not judged:')
            for r in note:
                if 'thresh' in r or r['kind'] == 'recognises':
                    print('  %-9s %-30s %8.3f ns after DTACK, %8.3f after AS'
                          % (r['spec'], REPORTED[r['spec']],
                             r.get('window', 0.0), r.get('fromas', 0.0)))
                else:
                    print('  %-9s %-30s not measurable' % (r['spec'],
                                                           REPORTED[r['spec']]))

        edges = [(r['spec'], r['what'], r['edge'])
                 for r in rows if 'edge' in r]
        if edges:
            print()
            print('sampling instants, ns after AS asserts:')
            for spec, what, e in edges:
                print('  spec %-4s %-8s %8.3f ns  = %.2f clocks'
                      % (spec, what, e, e / period))
        print()
    return failed


if __name__ == '__main__':
    sys.exit(main())
