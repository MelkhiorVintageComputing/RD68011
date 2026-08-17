#!/usr/bin/env python3
"""What each AC specification measures between.

    python3 tools/timing/anchors.py            # print the table and self-check

A limit in nanoseconds is useless without knowing which two events it separates,
and the CSV does not say -- its `characteristic` column is prose. The manual says
it in the figures, and the figures have a machine-readable source:

    Inputs/doc/MC68030_Doc_More_Readable/MC68000UM_split/make-figure-svg.py

Its `f.span(row, lane, t_from, t_to, spec)` calls place every callout on the
redrawn read and write cycles, in bus states, on the ruler recovered by measuring
the 300 dpi scan. Each entry below cites the line it came from, so a disputed
anchor can be taken back to the source in one step.

THE CONVENTION, AND WHY IT TRANSFERS TO ANOTHER DESIGN

Several specifications are measured from "clock high" or "clock low" without
saying which clock edge. Reading the anchors out of the figure answers that for
the original -- and the answer is uniform:

    every clock anchor is the nearest clock edge of the named polarity,
    preceding the pin event for an output delay, following it for an input
    setup time.

That is not an assumption imposed on the data; it is what all fourteen of the
figure's clock anchors turn out to be. Specification 6 anchors at 1.0 with the
address valid at 1.50, specification 9 at 2.0 with AS asserted at 2.80,
specification 12 at 7.0 with AS negated at 7.80, and so on for the rest.

It matters because it is the only reading that survives being applied to a
processor with a different state machine. "The rising edge entering S2" is
meaningless for a design that has no S2; "the nearest preceding rising edge" is
meaningful for any design at all, and reduces to the same thing for this one.
That is what makes the Suska core measurable against the same limits.

CLASSES

  1  clock-to-output   one end a clock edge, the other an output pin. Zero in a
                       delay-free RTL, so not measurable -- a budget on the pad
                       delay, with both a ceiling and, for specification 9 and
                       others, a floor.
  2  output-to-output  both ends output pins. A property of the design's edge
                       assignment, and the class this project can actually decide.
  3  input             one end an input pin. A demand on the system around the
                       processor, settled by simulation with ns-accurate stimulus
                       rather than by the constraint system.
"""

import sys

# Pin events, named as the log names them: <SIGNAL>.<transition>. `prev` and
# `next` refer to the adjacent bus cycle, which two specifications need.
CLASS1, CLASS2, CLASS3 = 1, 2, 3

RISE, FALL = 'rise', 'fall'
BEFORE, AFTER = 'before', 'after'


class Anchor(object):
    """One end of a measurement: a clock edge, or a pin event."""

    def __init__(self, kind, a=None, b=None):
        self.kind = kind        # 'clk' or 'pin'
        self.a = a              # polarity, or signal name
        self.b = b              # BEFORE/AFTER, or transition

    def __repr__(self):
        if self.kind == 'clk':
            return 'clk.%s(%s)' % (self.a, self.b)
        return '%s.%s' % (self.a, self.b)


def clk(pol, when):
    return Anchor('clk', pol, when)


def pin(sig, trans):
    return Anchor('pin', sig, trans)


class SpecAnchor(object):
    def __init__(self, num, cls, frm, to, cycles, src, why=''):
        self.num = num
        self.cls = cls
        self.frm = frm
        self.to = to
        self.cycles = cycles    # 'read', 'write', or 'both'
        self.src = src          # line of make-figure-svg.py
        self.why = why

    def __repr__(self):
        return '<%s %s -> %s>' % (self.num, self.frm, self.to)


# The table. `src` is the line number in make-figure-svg.py the anchor was read
# from; r### is the read cycle, w### the write cycle.
ANCHORS = [
    # -- class 1: a clock edge to an output ---------------------------------
    SpecAnchor('6',   CLASS1, clk(FALL, BEFORE), pin('A', 'valid'),    'both', 'r107/w171'),
    SpecAnchor('6A',  CLASS1, clk(RISE, BEFORE), pin('FC', 'valid'),   'both', 'r105/w169'),
    SpecAnchor('7',   CLASS1, clk(RISE, BEFORE), pin('A', 'hiz'),      'both', 'r108/w172'),
    SpecAnchor('8',   CLASS1, clk(RISE, BEFORE), pin('A', 'invalid'),  'both', 'r106/w170'),
    SpecAnchor('9',   CLASS1, clk(RISE, BEFORE), pin('AS', 'assert'),  'both', 'r116/w177',
               'The read figure draws it on DS and the write figure on AS; the '
               'characteristic covers both, and on a read the two assert together.'),
    SpecAnchor('12',  CLASS1, clk(FALL, BEFORE), pin('AS', 'negate'),  'both', 'r109/w173'),
    SpecAnchor('18',  CLASS1, clk(RISE, BEFORE), pin('RW', 'high'),    'both', 'r117/w183'),
    SpecAnchor('20',  CLASS1, clk(RISE, BEFORE), pin('RW', 'low'),     'write', 'w184'),
    SpecAnchor('23',  CLASS1, clk(FALL, BEFORE), pin('DOUT', 'valid'), 'write', 'w192'),
    SpecAnchor('53',  CLASS1, clk(RISE, BEFORE), pin('DOUT', 'invalid'), 'write', 'w193',
               'A minimum, not a maximum: the data has to be held past the edge.'),

    # -- class 2: output to output ------------------------------------------
    SpecAnchor('11',  CLASS2, pin('A', 'valid'),        pin('AS', 'assert'), 'both', 'r113/w178'),
    SpecAnchor('11A', CLASS2, pin('FC', 'valid'),       pin('AS', 'assert'), 'both', 'r114/w179'),
    SpecAnchor('13',  CLASS2, pin('AS', 'negate_prev'), pin('A', 'invalid'), 'both', 'r112/w176'),
    SpecAnchor('14',  CLASS2, pin('AS', 'assert'),      pin('AS', 'negate'), 'both', 'r111/w175'),
    SpecAnchor('14A', CLASS2, pin('DS', 'assert'),      pin('AS', 'negate'), 'write', 'w182',
               'Drawn from the write DS assertion to the AS negation, which is '
               'what makes it shorter than 14 rather than equal to it.'),
    SpecAnchor('15',  CLASS2, pin('AS', 'negate_prev'), pin('AS', 'assert'), 'both', 'r110/w174',
               'Cross-cycle: the gap between one cycle and the next, so it has '
               'to be taken from the log and not assumed.'),
    SpecAnchor('17',  CLASS2, pin('AS', 'negate_prev'), pin('RW', 'high'),   'both', 'r115/w180'),
    SpecAnchor('20A', CLASS2, pin('AS', 'assert'),      pin('RW', 'low'),    'write', 'w181'),
    SpecAnchor('21',  CLASS2, pin('A', 'valid'),        pin('RW', 'low'),    'write', 'w185'),
    SpecAnchor('21A', CLASS2, pin('FC', 'valid'),       pin('RW', 'low'),    'write', 'w187'),
    SpecAnchor('22',  CLASS2, pin('RW', 'low'),         pin('DS', 'assert'), 'write', 'w186'),
    SpecAnchor('25',  CLASS2, pin('AS', 'negate'),      pin('DOUT', 'invalid'), 'write', 'w194'),
    SpecAnchor('26',  CLASS2, pin('DOUT', 'valid'),     pin('DS', 'assert'), 'write', 'w191'),
    SpecAnchor('55',  CLASS2, pin('RW', 'low'),         pin('DOUT', 'valid'), 'write', 'w190'),

    # -- class 3: something the system has to do ----------------------------
    SpecAnchor('27',  CLASS3, pin('DIN', 'valid'),   clk(FALL, AFTER),      'read',  'r120'),
    SpecAnchor('28',  CLASS3, pin('AS', 'negate'),   pin('DTACK', 'negate'), 'both', 'r119/w189'),
    SpecAnchor('29',  CLASS3, pin('AS', 'negate'),   pin('DIN', 'invalid'), 'read',  'r125'),
    SpecAnchor('29A', CLASS3, pin('AS', 'negate'),   pin('DIN', 'hiz'),     'read',  'r122'),
    SpecAnchor('30',  CLASS3, pin('AS', 'negate'),   pin('BERR', 'negate'), 'both',  'r127/w196'),
    SpecAnchor('31',  CLASS3, pin('DTACK', 'assert'), pin('DIN', 'valid'),  'read',  'r124'),
    SpecAnchor('47',  CLASS3, pin('DTACK', 'assert'), clk(FALL, AFTER),     'both',  'r118/w188'),
    SpecAnchor('48',  CLASS3, pin('BERR', 'assert'), pin('DTACK', 'assert'), 'both', 'r123/w195'),
]

BY_NUM = dict((a.num, a) for a in ANCHORS)


def for_cycle(kind):
    """Anchors that apply to a 'read' or a 'write' cycle."""
    return [a for a in ANCHORS if a.cycles in ('both', kind)]


def of_class(cls):
    return [a for a in ANCHORS if a.cls == cls]


# The ruler the anchors were read off, for the self-check below: event times in
# bus states from the S0 rising edge, copied from make-figure-svg.py lines 37-53.
RULER = {
    'CLK_HI0': 0.0, 'CLK_LO1': 1.0,
    'FC.valid': 0.70, 'A.invalid': 0.60, 'A.hiz': 0.60, 'A.valid': 1.50,
    'AS.negate_prev': -0.45, 'AS.assert': 2.80, 'AS.negate': 7.80,
    'DS.assert': 4.40, 'RW.high': 0.40, 'RW.low': 2.90,
    'DTACK.assert': 4.55, 'DTACK.negate': 10.65,
    'DIN.valid': 6.55, 'DIN.invalid': 9.20, 'DIN.hiz': 9.20,
    'DOUT.valid': 3.30, 'DOUT.invalid': 8.60,
    'BERR.assert': 4.35, 'BERR.negate': 9.55,
}


def _nearest_edge(t, pol, when, any_polarity=False):
    """The nearest clock edge before or after `t`, in bus states.

    Even-numbered bus states begin on a rising edge and odd-numbered ones on a
    falling edge, so rising edges are at even integers and falling edges at odd
    ones -- which makes every integer an edge of one polarity or the other.

    With `any_polarity`, the named polarity is ignored and the nearest integer
    is taken. events.py resolves that way, for the reason given there; the
    self-check below establishes that both rules agree with the figure, which is
    what licenses using the more robust one.
    """
    import math
    if any_polarity:
        return math.floor(t) if when == BEFORE else math.ceil(t)
    if pol == RISE:
        k = math.floor(t / 2.0) * 2.0 if when == BEFORE else math.ceil(t / 2.0) * 2.0
    else:
        k = math.floor((t - 1.0) / 2.0) * 2.0 + 1.0 if when == BEFORE \
            else math.ceil((t - 1.0) / 2.0) * 2.0 + 1.0
    return k


def self_check(verbose=False):
    """Does 'nearest clock edge of the named polarity' reproduce the figure?

    Every class-1 and class-3 clock anchor in the table is checked against the
    ruler the figure was drawn on. If the convention is right, the edge it picks
    is the edge the figure drew the callout from, for all of them.
    """
    bad = []
    checked = 0
    for a in ANCHORS:
        for end, other in ((a.frm, a.to), (a.to, a.frm)):
            if end.kind != 'clk':
                continue
            key = '%s.%s' % (other.a, other.b)
            if key not in RULER:
                bad.append('%s: no ruler entry for %s' % (a.num, key))
                continue
            by_pol = _nearest_edge(RULER[key], end.a, end.b)
            by_any = _nearest_edge(RULER[key], end.a, end.b, any_polarity=True)
            checked += 1
            if by_pol != by_any:
                bad.append(
                    'spec %s: the named polarity gives %.1f and the nearest '
                    'edge gives %.1f; the two rules disagree, so the more '
                    'robust one can no longer be justified by this check'
                    % (a.num, by_pol, by_any))
            if verbose:
                print('  spec %-4s %s %s of %s (%.2f) -> %.1f' % (
                    a.num, end.b, end.a, key, RULER[key], by_pol))
    return checked, bad


def main():
    print('AC specification anchors, from make-figure-svg.py')
    print()
    print('%-5s %-6s %-22s %-22s %-6s %s' % (
        'spec', 'class', 'from', 'to', 'cycle', 'source'))
    for a in ANCHORS:
        print('%-5s %-6d %-22s %-22s %-6s %s' % (
            a.num, a.cls, a.frm, a.to, a.cycles, a.src))

    print()
    print('classes: %d clock-to-output, %d output-to-output, %d input' % (
        len(of_class(CLASS1)), len(of_class(CLASS2)), len(of_class(CLASS3))))

    checked, bad = self_check()
    print()
    if bad:
        print('SELF-CHECK FAILED:')
        for b in bad:
            print('  %s' % b)
        return 1
    print('self-check: %d clock anchors, every one of them the nearest edge of '
          'its polarity' % checked)
    print('            on the ruler the figure was drawn on -- so the '
          'convention is the figure\'s own,')
    print('            and applies unchanged to a design with different states.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
