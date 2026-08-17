#!/usr/bin/env python3
"""Is there a set of pad delays that meets every AC limit at once?

The measurement in a delay-free simulation gives, for each specification, the
spacing between the two events it names with no pad delay in the way. A real
implementation adds a delay to each pin, and section 10 says two different
kinds of thing about those delays:

  * how large each may be on its own -- the clock-to-output limits, class 1,
    which have a ceiling and sometimes a floor (specification 9 is never less
    than 3 ns, at any grade);
  * how far apart two pins must end up -- the output-to-output limits, class 2,
    which the design's edge assignment mostly decides but which pad delays can
    still break, because a late address and an early AS eat the gap between
    them.

Write d_e for the unknown delay on event e and m for the measured spacing. The
event happens at m + d_e, so every limit turns into

    (m + d_to) - (m_from + d_from)  >=  L        or  <= U

which rearranges to `d_x - d_y <= w`. A system of those is a *difference
constraint system*, and it is feasible exactly when its constraint graph has no
negative cycle. Bellman-Ford decides that, and when it fails the cycle it finds
is a proof: a short list of specifications that cannot all hold, with the number
of nanoseconds by which they miss.

That is a stronger answer than simulation can give. A simulation shows that one
chosen set of delays works or does not; this shows whether *any* set works.

WHAT FEASIBLE DOES AND DOES NOT MEAN

Each transition gets its own variable: d_AS_assert and d_AS_negate are
independent here, where a real pad's rise and fall delays are related. That is a
relaxation -- it admits assignments a real pad could not deliver. So:

    INFEASIBLE is a proof. FEASIBLE is conditional on the relaxation.

Both are worth having, and the asymmetry has to be stated wherever the results
are.
"""

import sys

import anchors

# Every specification measured in a delay-free run carries the pad model's
# nominal delay, which is one picosecond rather than zero so that its inertial
# filtering still removes delta-cycle glitches. It is subtracted back out.
PAD_EPS = 0.001

ZERO = '0'      # the reference node, d_0 == 0


class Edge(object):
    def __init__(self, u, v, w, spec, kind, grade, m, limit, cycle):
        self.u = u          # d_v - d_u <= w
        self.v = v
        self.w = w
        self.spec = spec
        self.kind = kind    # 'max', 'min' or 'physical'
        self.grade = grade
        self.m = m
        self.limit = limit
        self.cycle = cycle

    def describe(self):
        if self.kind == 'physical':
            return 'pad delay %s >= 0' % self.v
        if self.kind in ('same-edge', 'pad-skew'):
            return ('%-9s %s and %s are %s'
                    % (self.kind, self.u, self.v,
                       'one transition' if self.kind == 'same-edge'
                       else 'the same pin'))
        a = anchors.BY_NUM[self.spec]
        return ('spec %-4s %-3s  %-20s -> %-20s  measured %8.3f  limit %7s'
                % (self.spec, self.kind, a.frm, a.to, self.m, self.limit))


def var(anchor):
    """The delay variable an anchor end contributes, or the reference node."""
    if anchor.kind == 'clk':
        return ZERO
    return '%s.%s' % (anchor.a, anchor.b)


# Two transitions that are one and the same event on the pins. The address and
# the function code switch straight from one valid value to the next, so "the
# old going invalid" and "the new becoming valid" are one edge and must carry
# one delay. Without this they drift apart and the system is looser than reality.
SAME = [('A.valid', 'A.invalid'), ('FC.valid', 'FC.invalid')]

# Two transitions of the same pin in opposite directions. A pad's rise and fall
# delays are related; how closely is a technology question, so it is a knob.
# Leaving it unconstrained is a relaxation that admits assignments no real pad
# could deliver -- and it matters: a two-clock bus cycle can be made to satisfy
# specification 14's minimum AS width by negating AS much later than it asserts
# it, which is arithmetic rather than engineering.
PAIRED = [('AS.assert', 'AS.negate'), ('DS.assert', 'DS.negate'),
          ('RW.low', 'RW.high'), ('DOUT.valid', 'DOUT.invalid')]


def build(log, sp, grade, cycles=None, pad_skew=None):
    """Every constraint the log and the CSV imply at one speed grade.

    pad_skew is how far the two transition delays of one pin may differ, in ns.
    None leaves them independent, which is the loosest reading; 0 makes each pin
    have a single delay, which is the most conservative.
    """
    edges = []
    seen = set()
    cycles = cycles if cycles is not None else log.cycles

    # The tightest instance of each constraint is the one that has to hold, so
    # measurements are folded across every cycle in the log before any edge is
    # made. A run of thirty cycles is thirty chances for a gap to be at its
    # narrowest.
    tight = {}
    for c in cycles:
        for a in anchors.for_cycle(c.kind):
            if a.cls == anchors.CLASS3:
                continue
            got = log.spacing(a, c)
            if got is None:
                continue
            m = got[0]
            if a.cls == anchors.CLASS1:
                m -= PAD_EPS
            key = (a.num, c.kind)
            if key not in tight or m < tight[key][0]:
                tight[key] = (m, c)
            key_hi = (a.num, c.kind, 'hi')
            if key_hi not in tight or m > tight[key_hi][0]:
                tight[key_hi] = (m, c)

    for a in anchors.ANCHORS:
        if a.cls == anchors.CLASS3:
            continue
        u, v = var(a.frm), var(a.to)
        if u == v == ZERO:
            continue
        for kind in ('read', 'write'):
            if a.cycles not in ('both', kind):
                continue
            if (a.num, kind) not in tight:
                continue
            try:
                lo, hi = sp.limits('read-write', a.num, grade)
            except KeyError:
                continue
            unit = sp.unit('read-write', a.num)
            if unit != 'ns':
                continue

            # A minimum has to survive the narrowest measured gap, a maximum
            # the widest.
            if lo is not None:
                m, c = tight[(a.num, kind)]
                edges.append(Edge(v, u, m - lo, a.num, 'min', grade, m, '>=%g' % lo, c))
            if hi is not None:
                m, c = tight[(a.num, kind, 'hi')]
                edges.append(Edge(u, v, hi - m, a.num, 'max', grade, m, '<=%g' % hi, c))
            seen.add(u)
            seen.add(v)

    # A delay cannot be negative. Without this the system is trivially
    # satisfiable by letting a pin move backwards in time, and specification 9's
    # 3 ns floor -- which is what actually decides some of the interesting
    # cases -- would never bite.
    for nodename in sorted(seen):
        if nodename != ZERO:
            edges.append(Edge(nodename, ZERO, 0.0, None, 'physical',
                              grade, 0.0, '>=0', None))

    def tie(x, y, slack, why):
        if x in seen and y in seen:
            edges.append(Edge(x, y, slack, None, why, grade, 0.0,
                              '|dx-dy|<=%g' % slack, None))
            edges.append(Edge(y, x, slack, None, why, grade, 0.0,
                              '|dx-dy|<=%g' % slack, None))

    for x, y in SAME:
        tie(x, y, 0.0, 'same-edge')
    if pad_skew is not None:
        for x, y in PAIRED:
            tie(x, y, float(pad_skew), 'pad-skew')

    return edges, sorted(seen | {ZERO})


def solve(edges, nodes):
    """Bellman-Ford. Returns (True, potentials) or (False, cycle_edges)."""
    # All nodes start at zero, which is the same as a virtual source with a
    # zero-weight edge to each: needed, because the reference node does not
    # reach every variable through the constraint edges alone.
    dist = dict((n, 0.0) for n in nodes)
    pred = dict((n, None) for n in nodes)

    changed_edge = None
    for i in range(len(nodes) + 1):
        changed_edge = None
        for e in edges:
            if dist[e.u] + e.w < dist[e.v] - 1e-9:
                dist[e.v] = dist[e.u] + e.w
                pred[e.v] = e
                changed_edge = e
        if changed_edge is None:
            return True, dist

    # Still relaxing after |V| passes: walk back into the cycle and round it.
    node = changed_edge.v
    for _ in range(len(nodes) + 1):
        if pred[node] is None:
            break
        node = pred[node].u

    cycle = []
    at = node
    while True:
        e = pred[at]
        if e is None:
            break
        cycle.append(e)
        at = e.u
        if at == node:
            break
    cycle.reverse()
    return False, cycle


def envelope(edges, nodes):
    """Floyd-Warshall: the tightest implied bound on every d_v - d_u.

    This is the part a pad designer would actually read. "At 10 MHz the address
    pad may lead the AS pad by at most 30 ns" is a number; "feasible" is not.
    """
    inf = float('inf')
    d = dict((u, dict((v, (0.0 if u == v else inf)) for v in nodes))
             for u in nodes)
    for e in edges:
        if e.w < d[e.u][e.v]:
            d[e.u][e.v] = e.w
    for k in nodes:
        for u in nodes:
            duk = d[u][k]
            if duk == inf:
                continue
            for v in nodes:
                if duk + d[k][v] < d[u][v]:
                    d[u][v] = duk + d[k][v]
    return d


def report(log, sp, grade, out=sys.stdout, cycles=None, pad_skew=None):
    edges, nodes = build(log, sp, grade, cycles, pad_skew)
    ok, result = solve(edges, nodes)
    if ok:
        base = result[ZERO]
        witness = dict((n, result[n] - base) for n in nodes)
        return True, witness, edges, nodes
    return False, result, edges, nodes


def print_cycle(cycle, grade, out=sys.stdout):
    total = sum(e.w for e in cycle)
    out.write('INFEASIBLE at %s MHz -- these cannot all hold, by %.3f ns:\n'
              % (grade, -total))
    for e in cycle:
        out.write('  %s\n' % e.describe())
    out.write('  sum of the cycle = %.3f ns (negative means impossible)\n' % total)
