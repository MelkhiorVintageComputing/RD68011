"""Group a Vivado timing report into path families.

`report_timing -unique_pins` gives one path per endpoint, which is hundreds of
lines each and thousands of lines in total. What an implementer wants to know is
not the individual paths but the *families*: which stretches of logic they have
in common, how many endpoints each family feeds, and -- the number that decides
whether optimising is worth anything -- how tightly the families are stacked.

A design whose second-worst family is a nanosecond behind the worst has no
single fix in it.

    python3 tools/timing/paths.py build/paths_activatable.rpt
    python3 tools/timing/paths.py --detail build/paths_baseline.rpt
"""

import re
import sys
from collections import defaultdict

# The hierarchical units a path is described by. A path is named for the ones it
# passes through, in order, which is enough to tell two families apart without
# drowning in cell names.
UNITS = [
    ('u_seq/u_urom/', 'ucode-rom'),
    ('u_seq/u_ureq_nxt/', 'ureq-rom'),
    ('u_seq/u_decode/', 'decode-rom'),
    ('u_seq/u_alu/', 'alu'),
    ('u_seq/u_shifter/', 'shifter'),
    ('u_seq/u_divider', 'a-mux'),   # the A-source mux places into divider cells
    ('u_seq/u_mul/', 'mul'),
    ('u_seq/u_loop_rom/', 'loop-rom'),
]

# Named waypoints worth seeing in a family name even though they are plain nets.
WAYPOINTS = [
    ('u_seq/req_last', 'req_last'),
    ('u_seq/rq_nxt', 'rq_nxt'),
    ('u_seq/dec_entry', 'dec_entry'),
    ('u_seq/z_flag', 'z_flag'),
    ('u_seq/n_flag', 'n_flag'),
    ('u_seq/z_flag_alu', 'z_flag_alu'),
    ('u_seq/n_flag_alu', 'n_flag_alu'),
    ('u_seq/alu_y', 'alu_y'),
    ('u_biu/req_valid', 'req_valid'),
    ('u_biu/start_new', 'start_new'),
]


class Path(object):
    def __init__(self):
        self.slack = None
        self.src = None
        self.dst = None
        self.delay = None
        self.levels = None
        self.route_pct = None
        self.marks = []


def parse(text):
    """Every path in a report_timing output."""
    paths = []
    cur = None
    for line in text.split('\n'):
        m = re.match(r'\s*Slack \(\w+\) :\s+(-?[\d.]+)ns', line)
        if m:
            cur = Path()
            cur.slack = float(m.group(1))
            paths.append(cur)
            continue
        if cur is None:
            continue
        m = re.match(r'\s*Source:\s+(\S+)', line)
        if m and cur.src is None:
            cur.src = m.group(1)
            continue
        m = re.match(r'\s*Destination:\s+(\S+)', line)
        if m and cur.dst is None:
            cur.dst = m.group(1)
            continue
        m = re.match(r'\s*Data Path Delay:\s+([\d.]+)ns.*route ([\d.]+)ns \(([\d.]+)%', line)
        if m:
            cur.delay = float(m.group(1))
            cur.route_pct = float(m.group(3))
            continue
        m = re.match(r'\s*Logic Levels:\s+(\d+)', line)
        if m:
            cur.levels = int(m.group(1))
            continue
        # The path detail. Record the first time each unit or waypoint appears,
        # in order, which is what makes the family name.
        for pfx, name in UNITS:
            if pfx in line and name not in cur.marks:
                cur.marks.append(name)
        for pfx, name in WAYPOINTS:
            # Anchored, because `u_seq/n_flag` is a prefix of
            # `u_seq/n_flag_alu` and they are different signals -- one of them
            # was excluded from a report and the other was not, which is
            # exactly the confusion this would have caused.
            if re.search(re.escape(pfx) + r'(?!\w)', line) \
                    and name not in cur.marks:
                cur.marks.append(name)
    return paths


def family(p):
    return ' -> '.join(p.marks) if p.marks else '(no named waypoint)'


def short(pin):
    return re.sub(r'_reg(\[\d+\])?/[A-Z]+$', r'\1', pin or '?')


def main(argv):
    detail = '--detail' in argv
    files = [a for a in argv if not a.startswith('--')]
    if not files:
        print(__doc__)
        return 1

    for fn in files:
        with open(fn) as f:
            paths = parse(f.read())
        if not paths:
            print('%s: no timing paths in this report' % fn)
            continue

        worst = min(p.slack for p in paths)
        print('== %s: %d paths, worst slack %.3f ns ==' % (fn, len(paths), worst))

        fams = defaultdict(list)
        for p in paths:
            fams[family(p)].append(p)

        print('%-9s %-7s %5s  %s' % ('slack', 'behind', 'ends', 'family'))
        for name, ps in sorted(fams.items(), key=lambda kv: min(p.slack for p in kv[1])):
            w = min(ps, key=lambda p: p.slack)
            print('%8.3f %+7.3f %5d  %s' % (w.slack, w.slack - worst, len(ps), name))
            if detail:
                print('%22s%s -> %s  (%.3f ns, %d levels, %.0f%% route)'
                      % ('', short(w.src), short(w.dst),
                         w.delay or 0.0, w.levels or 0, w.route_pct or 0.0))

        # How tightly the whole report is stacked. If most endpoints sit within
        # a nanosecond of the worst, no single change moves the design.
        for band in (0.5, 1.0, 2.0, 3.0):
            n = sum(1 for p in paths if p.slack < worst + band)
            print('   %4d of %d endpoints within %.1f ns of the worst'
                  % (n, len(paths), band))
        print('')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
