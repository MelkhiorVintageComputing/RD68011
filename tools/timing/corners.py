#!/usr/bin/env python3
"""Named pad-delay corners, as tool options.

    python3 tools/timing/corners.py max 8            # iverilog -P options
    python3 tools/timing/corners.py max 8 --xelab    # xelab -generic_top options
    python3 tools/timing/corners.py --list

A delay in a continuous assignment has to be a constant, so the sixteen pad
delays are parameters of the testbench rather than plusargs, and selecting a
corner means putting the right options on the build. This works them out from
the CSV so that "every delay at its maximum" means the manual's maxima for that
grade rather than somebody's idea of a large number.

The corners:

  zero      one picosecond everywhere -- the model every other testbench here
            implicitly assumes, and the one the edge assignment is measured at
  max       every delay at its clock-to-output maximum. Expected to break the
            output-to-output limits, and interesting precisely because of that:
            the solver predicts which one, and the simulation should show it
  min       every delay at its minimum, which for specification 9 is 3 ns and
            not 0
  late-as   AS and the data strobes delayed by half a clock, putting them on the
            following edge. This is the experiment doc/ac-timing.md describes:
            from the bus's side it is indistinguishable from a design that
            asserts AS there, and it needs no change to the RTL to ask
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import specs

# Which specification bounds each pad delay, and in which direction. The pin
# names are the parameters of sim/models/rd68011_pads.sv.
BOUNDED_BY = [
    ('P_A_VALID',    '6'),
    ('P_A_HIZ',      '7'),
    ('P_FC_VALID',   '6A'),
    ('P_AS_ASSERT',  '9'),
    ('P_AS_NEGATE',  '12'),
    ('P_DS_ASSERT',  '9'),
    ('P_DS_NEGATE',  '12'),
    ('P_RW_LOW',     '20'),
    ('P_RW_HIGH',    '18'),
    ('P_DOUT_VALID', '23'),
    ('P_DOUT_HIZ',   '7'),
    ('P_VMA_ASSERT', '40'),
    ('P_VMA_NEGATE', '40'),
    ('P_BG_ASSERT',  '33'),
    ('P_BG_NEGATE',  '34'),
    ('P_E',          '41'),
]

EPS = 0.001
CORNERS = ('zero', 'min', 'max', 'late-as')


def delays(corner, grade, sp=None):
    sp = sp or specs.Specs()
    half = specs.PERIOD_NS[grade] / 2.0
    out = {}
    for name, num in BOUNDED_BY:
        try:
            lo, hi = sp.limits('read-write', num, grade)
        except KeyError:
            lo, hi = None, None
        if corner == 'zero':
            v = EPS
        elif corner == 'min':
            v = lo if lo else EPS
        elif corner == 'max':
            v = hi if hi else EPS
        elif corner == 'late-as':
            # Only the strobes move; everything else stays where it was, so the
            # experiment has one variable in it.
            v = half if name in ('P_AS_ASSERT', 'P_DS_ASSERT') else EPS
        else:
            raise KeyError('no corner %r; have %s' % (corner, ', '.join(CORNERS)))
        out[name] = max(v, EPS)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('corner', nargs='?', default='zero')
    ap.add_argument('grade', nargs='?', default='8')
    ap.add_argument('--top', default='rd68011_ac_tb')
    ap.add_argument('--xelab', action='store_true',
                    help='emit -generic_top options instead of iverilog -P')
    ap.add_argument('--list', action='store_true')
    args = ap.parse_args(argv)

    if args.list:
        print('corners: %s' % ', '.join(CORNERS))
        print('grades:  %s' % ', '.join(specs.GRADES))
        return 0

    if args.grade not in specs.GRADES:
        sys.stderr.write('unknown grade %r; have %s\n'
                         % (args.grade, ', '.join(specs.GRADES)))
        return 2

    d = delays(args.corner, args.grade)
    if args.xelab:
        print(' '.join('-generic_top "%s=%g"' % (k, v)
                       for k, v in sorted(d.items())))
    else:
        print(' '.join('-P%s.%s=%g' % (args.top, k, v)
                       for k, v in sorted(d.items())))
    return 0


if __name__ == '__main__':
    sys.exit(main())
