#!/usr/bin/env python3
"""Judge an event log against the AC electrical specifications.

    python3 tools/timing/analyse.py build/timing/ours.events
    python3 tools/timing/analyse.py --grade 10 --verbose build/timing/ours.events
    python3 tools/timing/analyse.py --envelope A.valid,AS.assert ours.events

Prints, for each speed grade, whether a set of pad delays exists that satisfies
every clock-to-output and output-to-output limit at once -- and if not, which
specifications conflict and by how much.

The input-side limits (27, 28, 29, 29A, 30, 31, 47, 48) are not judged here.
They constrain the memory system rather than the processor, and what the
processor's own requirement actually is has to be measured by presenting inputs
at the limit and seeing what happens, which is what
sim/tb/timing/rd68011_setup_tb.sv does. They are listed at the end as measured
values so the two halves can be read together.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import anchors
import events
import feasible
import specs


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('log', nargs='+')
    ap.add_argument('--grade', default=None, help='one grade, or all six')
    ap.add_argument('--verbose', action='store_true')
    ap.add_argument('--brief', action='store_true',
                    help='one line per design and grade, for a summary table')
    ap.add_argument('--strict-polarity', action='store_true',
                    help='resolve clock anchors by the polarity the '
                         'specification names, rather than by the edge '
                         'that caused the pin to move')
    ap.add_argument('--pad-skew', type=float, default=None,
                    help='how far the two transition delays of one pin may '
                         'differ, in ns; omit to leave them independent, which '
                         'is the loosest reading, or give 0 for one delay per pin')
    ap.add_argument('--envelope', default=None,
                    help='two variables, comma separated, e.g. A.valid,AS.assert')
    args = ap.parse_args(argv)

    sp = specs.Specs()
    failed = 0

    def grades_for(log):
        """Which grades this log may be judged at.

        A log is only evidence about the grade it was recorded at. This design
        places its events in half-clocks, so every output-to-output spacing
        scales with the clock period -- judging an 8 MHz recording against the
        20 MHz limits compares a 62.5 ns gap with a limit written for a 25 ns
        one and gets the answer wrong in the design's favour. So the grade comes
        from the period the log was taken at, and one run is needed per grade.

        60 ns is the minimum cycle time of two different parts, the 16.67 MHz
        12F and the plain 16 MHz, whose limits differ. A 60 ns log is judged
        against both.
        """
        if args.grade:
            return [args.grade]
        p = log.period()
        got = [g for g in specs.GRADES if abs(specs.PERIOD_NS[g] - p) < 1e-6]
        return got

    if args.brief:
        print('%-8s %-9s %-11s %s' % ('grade', 'design', 'verdict',
                                      'binding constraint'))
        print('-' * 74)

    for path in args.log:
        log = events.Log(path, strict_polarity=args.strict_polarity)
        name = log.header.get('design', os.path.basename(path))
        corner = log.header.get('corner', '?')
        if args.brief:
            for g in grades_for(log):
                ok, result, edges, nodes = feasible.report(
                    log, sp, g, pad_skew=args.pad_skew)
                if not ok:
                    e = min(result, key=lambda x: x.w)
                    why = ('spec %s %s: measured %.1f, limit %s'
                           % (e.spec, e.kind, e.m, e.limit)) if e.spec else '-'
                    print('%-8s %-9s %-11s short by %.1f ns -- %s'
                          % (g, name, 'INFEASIBLE',
                             -sum(x.w for x in result), why))
                    failed += 1
                    continue
                env = feasible.envelope(edges, nodes)
                worst = None
                for e in edges:
                    if e.kind in ('physical', 'same-edge', 'pad-skew'):
                        continue
                    back = env[e.v][e.u]
                    if back == float('inf'):
                        continue
                    if worst is None or e.w + back < worst[0]:
                        worst = (e.w + back, e)
                print('%-8s %-9s %-11s %s'
                      % (g, name, 'feasible',
                         'spec %s %s, %.1f ns of room'
                         % (worst[1].spec, worst[1].kind, worst[0])
                         if worst else '-'))
            continue
        print('=' * 74)
        print('%s   corner=%s   %d cycles (%d read, %d write)' % (
            name, corner, len(log.cycles),
            len([c for c in log.cycles if c.rw]),
            len([c for c in log.cycles if not c.rw])))
        print('measured at period %g ns, hi %s / lo %s' % (
            log.period(), log.header.get('hi'), log.header.get('lo')))
        print('=' * 74)

        if log.glitches:
            print('FAIL: %d transitions were swallowed by a pad delay; the '
                  'measurement is not trustworthy' % len(log.glitches))
            for g in log.glitches[:5]:
                print('  %s' % g)
            failed += 1
            continue

        grades = grades_for(log)
        if not grades:
            print('FAIL: %g ns is not the minimum cycle time of any grade, so '
                  'there is nothing to judge this against.' % log.period())
            print('      Record one log per grade, at %s ns.' % ', '.join(
                '%g' % specs.PERIOD_NS[g] for g in specs.GRADES))
            failed += 1
            continue

        print()
        print('%-10s %-12s %s' % ('grade', 'verdict', 'tightest constraint'))
        print('-' * 74)

        for g in grades:
            if abs(specs.PERIOD_NS[g] - log.period()) > 1e-6:
                print('%-10s %-12s recorded at %g ns, but this grade\'s cycle '
                      'time is %g ns' % (g + ' MHz', 'WARNING', log.period(),
                                         specs.PERIOD_NS[g]))
            ok, result, edges, nodes = feasible.report(
                log, sp, g, pad_skew=args.pad_skew)
            if not ok:
                print('%-10s %-12s %s' % (g + ' MHz', 'INFEASIBLE',
                                          'see below'))
                feasible.print_cycle(result, g)
                print()
                failed += 1
                continue

            # How much room each constraint really has. Substituting the
            # witness back in does not answer that -- Bellman-Ford lands on a
            # vertex of the feasible region, so whichever constraints meet
            # there read as having exactly zero spare whether they are tight or
            # not. The witness-independent measure is the shortest path the
            # other way round: an edge u -> v of weight w can be tightened by
            # w + D[v][u] before a cycle goes negative.
            env = feasible.envelope(edges, nodes)
            worst = None
            for e in edges:
                # Only real specifications: the modelling edges (a delay is not
                # negative, two names for one transition, the two ends of one
                # pin) are always exactly tight and would otherwise win every
                # time while saying nothing.
                if e.kind in ('physical', 'same-edge', 'pad-skew'):
                    continue
                back = env[e.v][e.u]
                if back == float('inf'):
                    continue
                slack = e.w + back
                if worst is None or slack < worst[0]:
                    worst = (slack, e)
            desc = ('spec %s %s, %.3f ns of room'
                    % (worst[1].spec, worst[1].kind, worst[0])) if worst else '-'
            print('%-10s %-12s %s' % (g + ' MHz', 'feasible', desc))

            # The question this instrument was built to answer: how far may the
            # address pad drift ahead of the AS pad before specification 11 --
            # address valid to AS asserted -- stops holding.
            #
            # An edge u -> v of weight w encodes d_v - d_u <= w, so the bound on
            # how far the address may *lead* is the path from AS to A, not the
            # one from A to AS. The two are different numbers and reading the
            # wrong one gives an answer that looks plausible.
            for a, b, word in (('AS.assert', 'A.valid', 'address may lag AS'),
                               ('A.valid', 'AS.assert', 'AS may lag address')):
                lim = env.get(a, {}).get(b, float('inf'))
                if lim != float('inf'):
                    print('%-10s %-12s %s by at most %.3f ns'
                          % ('', '', word, lim))

            if args.verbose:
                print('     witness (ns): %s' % ', '.join(
                    '%s=%.3f' % (k, v) for k, v in sorted(result.items())
                    if k != feasible.ZERO and v != 0.0) or '(all zero)')

            if args.envelope:
                u, v = args.envelope.split(',')
                env = feasible.envelope(edges, nodes)
                if u in env and v in env[u]:
                    lim = env[u][v]
                    print('     %s may lead %s by at most %s ns' % (
                        u, v, ('%.3f' % lim) if lim != float('inf') else 'anything'))

        print()
        print('input-side limits, measured (not judged -- these are demands on')
        print('the memory system, and the processor\'s own requirement is')
        print('measured by rd68011_setup_tb):')
        print('-' * 74)
        for kind in ('read', 'write'):
            sample = [c for c in log.cycles if (c.kind == kind)]
            if not sample:
                continue
            c = sample[len(sample) // 2]
            for a in anchors.of_class(anchors.CLASS3):
                if a.cycles not in ('both', kind):
                    continue
                got = log.spacing(a, c)
                if got is None:
                    continue
                try:
                    lo, hi = sp.limits('read-write', a.num, grades[0])
                except KeyError:
                    continue
                lim = ('>=%g' % lo) if lo is not None else ''
                lim += ('  <=%g' % hi) if hi is not None else ''
                print('  %-5s %-5s %-20s -> %-20s %8.3f ns   %s' % (
                    a.num, kind, a.frm, a.to, got[0], lim))

    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
