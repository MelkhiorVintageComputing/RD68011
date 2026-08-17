#!/usr/bin/env python3
"""Read an event log and pull the measured spacings out of it.

    python3 tools/timing/events.py build/timing/ours.events

The log is written by sim/tb/timing/rd68011_timing_harness.svh and says only
when things happened:

    # design=rd68011 corner=zero period=125.000 hi=62.500 lo=62.500
    CLK  3875.000 rise tick=8
    EV   3875.001 AS assert
    BUS  3875.001 addr=000002 fc=6 rw=1

Everything about what a specification is lives in specs.py and anchors.py; this
module is the bridge, and it knows only two things about the processor: that a
bus cycle begins when AS asserts, and that clock edges alternate.

That is deliberately little, because the same code has to read the log of a
processor whose bus cycle is two clocks long and whose AS asserts on a falling
edge. Nothing here refers to S0-S7.
"""

import re
import sys

import anchors


class Event(object):
    __slots__ = ('t', 'sig', 'trans', 'val')

    def __init__(self, t, sig, trans, val=None):
        self.t = t
        self.sig = sig
        self.trans = trans
        self.val = val

    def __repr__(self):
        return '%.3f %s %s' % (self.t, self.sig, self.trans)


class Cycle(object):
    def __init__(self, index, t, addr, fc, rw):
        self.index = index
        self.t = t
        self.addr = addr
        self.fc = fc
        self.rw = rw            # 1 read, 0 write
        self.at = {}            # 'AS.assert' -> time

    @property
    def kind(self):
        return 'read' if self.rw else 'write'

    def __repr__(self):
        return '<cycle %d %s %s at %.3f>' % (
            self.index, self.kind, self.addr, self.t)


class Log(object):
    def __init__(self, path, strict_polarity=False):
        self.path = path
        # See edge(). False resolves a clock anchor to the nearest edge of
        # either polarity -- the edge that caused the pin to move -- and is the
        # right default. True resolves by the polarity the specification names,
        # which is the literal reading of the manual's text and is worth being
        # able to ask for, because for a design whose events sit on the other
        # edge the two readings give different verdicts.
        self.strict_polarity = strict_polarity
        self.header = {}
        self.events = []
        self.edges = []         # (time, 'rise'|'fall')
        self.cycles = []
        self.glitches = []
        self._read()
        self._group()

    # -- reading ------------------------------------------------------------
    def _read(self):
        hdr = re.compile(r'^#\s+(.*)$')
        with open(self.path) as f:
            for line in f:
                line = line.rstrip('\n')
                m = hdr.match(line)
                if m:
                    for bit in m.group(1).split():
                        if '=' in bit:
                            k, v = bit.split('=', 1)
                            self.header[k] = v
                    continue
                p = line.split()
                if not p:
                    continue
                if p[0] == 'CLK' and len(p) >= 3:
                    self.edges.append((float(p[1]), p[2]))
                elif p[0] == 'EV' and len(p) >= 4:
                    self.events.append(
                        Event(float(p[1]), p[2], p[3],
                              p[4] if len(p) > 4 else None))
                elif p[0] == 'BUS' and len(p) >= 5:
                    kv = dict(x.split('=', 1) for x in p[2:] if '=' in x)
                    self.cycles.append(Cycle(len(self.cycles), float(p[1]),
                                             kv.get('addr'), kv.get('fc'),
                                             int(kv.get('rw', '1'))))
                elif p[0] == 'GLITCH':
                    self.glitches.append(line)
        self.edges.sort(key=lambda e: e[0])
        # Never rely on the order two lines were printed in at the same
        # simulated time: two simulators may emit them either way round.
        self.events.sort(key=lambda e: (e.t, e.sig, e.trans))

    def period(self):
        return float(self.header.get('period', '125'))

    # -- the events of one cycle --------------------------------------------
    def _first(self, sig, trans, after, before=None, val_not=None):
        for e in self.events:
            if e.sig != sig or e.trans != trans:
                continue
            if e.t < after:
                continue
            if before is not None and e.t > before:
                break
            if val_not is not None and e.val == val_not:
                continue
            return e.t
        return None

    def _last(self, sig, trans, at_or_before):
        best = None
        for e in self.events:
            if e.sig == sig and e.trans == trans and e.t <= at_or_before:
                best = e.t
            elif e.t > at_or_before:
                break
        return best

    def _group(self):
        n = len(self.cycles)
        for i, c in enumerate(self.cycles):
            nxt = self.cycles[i + 1].t if i + 1 < n else float('inf')
            end = None

            c.at['AS.assert'] = c.t
            c.at['AS.negate'] = self._first('AS', 'negate', c.t, nxt)
            end = c.at['AS.negate'] if c.at['AS.negate'] is not None else nxt

            # The previous cycle's AS negation. Specifications 13, 15 and 17
            # are all measured from it, and 15 in particular is the gap between
            # one cycle and the next -- which has to be taken from the log
            # rather than assumed, because how far apart two cycles fall is the
            # sequencer's business and not the bus unit's.
            c.at['AS.negate_prev'] = self._last('AS', 'negate', c.t)

            c.at['DS.assert'] = self._first('DS', 'assert', c.t, end)
            c.at['DS.negate'] = self._first('DS', 'negate', c.t, nxt)

            # Signals that are *set up* for this cycle -- the address, the
            # function code, the direction -- are looked for only in the window
            # between the previous cycle's AS negation and this cycle's AS
            # assertion. That is where the manual's figure draws them.
            #
            # If one of them did not move in that window it kept the value it
            # already had, and the specification governing it is not measurable
            # on this cycle. Recording None rather than reaching further back is
            # the honest choice twice over: a value valid since before the
            # window has strictly more margin than one that just arrived, so
            # nothing that could fail is being discarded -- and reaching back
            # produced spacings like specification 17 at minus 937 ns, which is
            # not a measurement of anything.
            lo = c.at['AS.negate_prev']
            if lo is None:
                lo = 0.0

            def setup(sig, trans, lo=lo, hi=c.t):
                best = None
                for e in self.events:
                    if e.sig == sig and e.trans == trans and lo <= e.t <= hi:
                        best = e.t
                    elif e.t > hi:
                        break
                return best

            # The address and the function code are switched straight from one
            # valid value to the next rather than passing through invalid, so
            # one transition is both the old going invalid and the new becoming
            # valid. Recording it as both is what the manual's own figure does:
            # its generator places specifications 7 and 8 at the same instant.
            a = setup('A', 'change')
            c.at['A.valid'] = a
            c.at['A.invalid'] = a
            c.at['A.hiz'] = setup('A', 'hiz')
            fcv = setup('FC', 'change')
            c.at['FC.valid'] = fcv
            c.at['FC.invalid'] = fcv

            c.at['RW.high'] = setup('RW', 'high')
            c.at['RW.low'] = setup('RW', 'low')

            if c.rw:
                c.at['DIN.valid'] = self._first('DIN', 'change', c.t, nxt,
                                                val_not='xxxx')
                c.at['DIN.invalid'] = self._first('DIN', 'change', end or c.t,
                                                  nxt)
                c.at['DIN.hiz'] = self._first('D', 'hiz', end or c.t, nxt)
            else:
                c.at['DOUT.valid'] = self._first('DOUT', 'change', c.t, nxt,
                                                 val_not='xxxx')
                c.at['DOUT.invalid'] = self._first('D', 'hiz', end or c.t, nxt)
                c.at['DOUT.hiz'] = c.at['DOUT.invalid']

            c.at['DTACK.assert'] = self._first('DTACK', 'assert', c.t, nxt)
            c.at['DTACK.negate'] = self._first('DTACK', 'negate',
                                               end or c.t, nxt)
            c.at['BERR.assert'] = self._first('BERR', 'assert', c.t, nxt)
            c.at['BERR.negate'] = self._first('BERR', 'negate', end or c.t, nxt)

    # -- clock edges ---------------------------------------------------------
    def edge(self, t, pol, when):
        """The nearest clock edge before or after `t` -- of *either* polarity.

        The specification names a polarity ("Clock Low to Address Valid") and
        anchors.py records it, because that is the manual's own text. Resolving
        by that polarity is nevertheless wrong, and the measurement showed why.

        A clock-to-output limit bounds how long after the edge that *causes* it
        a pin takes to settle. Which edge causes it is the design's business.
        Ours drives the address from the falling edge entering S1 for a cycle
        that follows another, and from a rising edge for one that follows an
        idle bus -- and in the second case, measuring to the nearest preceding
        *falling* edge charges the design a half period it never spent, and
        reports the address as arriving 62.5 ns late when it arrived early.

        Taking the nearest preceding edge of either polarity measures what the
        limit is about: the delay from an edge to a pin. It reproduces all
        twelve of the clock anchors in the manual's own figure, exactly as the
        polarity rule does -- anchors.py checks that -- and unlike the polarity
        rule it stays meaningful for a design whose events fall on the other
        edge. Which is the whole reason this instrument exists.
        """
        strict = self.strict_polarity
        if when == anchors.BEFORE:
            best = None
            for (et, ep) in self.edges:
                if et <= t and (not strict or ep == pol):
                    best = et
                elif et > t:
                    break
            return best
        for (et, ep) in self.edges:
            if et >= t and (not strict or ep == pol):
                return et
        return None

    # -- what a specification measures, in this log --------------------------
    def spacing(self, spec, cycle):
        """(value, t_from, t_to) in ns, or None if the cycle has no such events.

        The sign convention is the manual's: the value is later minus earlier,
        so a minimum limit reads as `value >= limit` whichever end the clock is.
        """
        a, b = spec.frm, spec.to
        if a.kind == 'pin' and b.kind == 'pin':
            ta = cycle.at.get('%s.%s' % (a.a, a.b))
            tb = cycle.at.get('%s.%s' % (b.a, b.b))
            if ta is None or tb is None:
                return None
            return (tb - ta, ta, tb)
        if a.kind == 'clk':
            tb = cycle.at.get('%s.%s' % (b.a, b.b))
            if tb is None:
                return None
            ta = self.edge(tb, a.a, a.b)
            if ta is None:
                return None
            return (tb - ta, ta, tb)
        ta = cycle.at.get('%s.%s' % (a.a, a.b))
        if ta is None:
            return None
        tb = self.edge(ta, b.a, b.b)
        if tb is None:
            return None
        return (tb - ta, ta, tb)


def main(argv=None):
    argv = argv or sys.argv[1:]
    if not argv:
        sys.stderr.write(__doc__)
        return 2
    log = Log(argv[0])
    print('%s: %d cycles, %d events, %d clock edges, period %g ns' % (
        argv[0], len(log.cycles), len(log.events), len(log.edges),
        log.period()))
    if log.glitches:
        print('GLITCHES (%d) -- a transition was swallowed by a pad delay:'
              % len(log.glitches))
        for g in log.glitches[:5]:
            print('  %s' % g)

    reads = [c for c in log.cycles if c.rw]
    writes = [c for c in log.cycles if not c.rw]
    print('%d reads, %d writes' % (len(reads), len(writes)))

    for kind, sample in (('read', reads), ('write', writes)):
        if not sample:
            continue
        c = sample[len(sample) // 2]
        print('\nspacings on a %s cycle (%s at %.3f ns):' % (kind, c.addr, c.t))
        for sp in anchors.for_cycle(kind):
            got = log.spacing(sp, c)
            if got is None:
                continue
            print('  spec %-4s class %d  %-22s -> %-22s  %8.3f ns' % (
                sp.num, sp.cls, sp.frm, sp.to, got[0]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
