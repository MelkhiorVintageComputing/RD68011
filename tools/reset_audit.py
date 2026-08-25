#!/usr/bin/env python3
"""Prove that nothing in rtl/ initialises outside reset.

    python3 tools/reset_audit.py rtl/*.sv rtl/gen/*.sv

ASIC is a target, so there is no power-on register state: every register has to
take its value from the reset branch of its always_ff, and nothing may rely on
an initial block, a declaration-site initialiser, or 'x resolving to something
useful. CLAUDE.md calls that a hard rule, and a hard rule that is not checked is
a preference.

Two checks, because either alone would miss things:

  Source     no `initial`, no `always_latch`, and no initialiser on a
             declaration that could infer a register. Fast, and says exactly
             which line.
  Netlist    yosys is asked to synthesise the whole design to gate-level flops
             and the cell types are read back. A flop with no reset is a
             distinct cell type there -- $_DFF_P_ rather than $_DFF_PN0_ -- so
             one that slipped through the source check by some route nobody
             thought of still shows up. Latches show up the same way.

The netlist check is the one that matters and the slow one; --source-only skips
it for a quick pass during editing.
"""

import os
import re
import subprocess
import sys

# A declaration that gives a variable a value where it is declared. `assign`
# lines and localparams are not declarations of state, so they are not this.
DECL_INIT = re.compile(r'^\s*(?:logic|reg|bit|integer|int)\b[^;=]*=')
INITIAL   = re.compile(r'^\s*initial\b')
LATCH     = re.compile(r'^\s*always_latch\b')

# Yosys names a flop by what it has: the letters after $_DFF or $_DFFE give the
# clock polarity and then, if there is a reset, its polarity and the value it
# forces. No reset means no such letters -- $_DFF_P_ against $_DFF_PN0_.
RESET_OK = re.compile(r'^\$_(S?DFFE?)_[PN]{1,2}[PN][01]')
FLOPLIKE = re.compile(r'^\$_(S?DFFE?|DLATCH)')


def source_check(paths):
    bad = []
    for path in paths:
        with open(path) as f:
            for n, line in enumerate(f, 1):
                text = line.split('//')[0]
                if INITIAL.match(text):
                    bad.append((path, n, 'initial block', line.rstrip()))
                elif LATCH.match(text):
                    bad.append((path, n, 'always_latch', line.rstrip()))
                elif DECL_INIT.match(text):
                    bad.append((path, n, 'initialiser on a declaration',
                                line.rstrip()))
    return bad


def netlist_check(paths, top):
    """Synthesise to gates and read back what kind of flops came out."""
    yosys = os.environ.get('YOSYS', 'yosys')
    script = ('read_verilog -sv %s; hierarchy -check -top %s; '
              'synth -top %s -flatten; stat' % (' '.join(paths), top, top))
    try:
        out = subprocess.run([yosys, '-p', script], capture_output=True,
                             text=True, check=True).stdout
    except FileNotFoundError:
        return None, ['yosys not found; set YOSYS to it']
    except subprocess.CalledProcessError as e:
        return None, ['yosys failed:\n' + e.stderr[-2000:]]

    # `synth` ends by printing statistics of its own, and the explicit `stat`
    # prints them again, so the output holds two identical blocks. Reading both
    # counted every flop twice -- the audit reported 2758 where the design has
    # 1379, which Vivado (1340 FF placed) and Quartus (1357 registers) both
    # contradict. Only the last block is read.
    tail = out.rsplit('Printing statistics.', 1)[-1]
    counts = {}
    for line in tail.splitlines():
        m = re.match(r'\s+(\$_\w+_)\s+(\d+)\s*$', line)
        if m and FLOPLIKE.match(m.group(1)):
            counts[m.group(1)] = counts.get(m.group(1), 0) + int(m.group(2))
    if not counts:
        return None, ['no flops in the netlist, which cannot be right']

    bad = ['%s: %d' % (k, v) for k, v in sorted(counts.items())
           if not RESET_OK.match(k)]
    return counts, bad


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    source_only = '--source-only' in sys.argv
    top = 'rd68011_top'
    if not args:
        sys.stderr.write(__doc__)
        return 2

    bad = source_check(args)
    for path, n, what, line in bad:
        print('error: %s:%d: %s' % (path, n, what))
        print('       %s' % line.strip())
    if bad:
        return 1
    print('reset audit: %d files, no initial blocks, no latches, '
          'no declaration initialisers' % len(args))

    if source_only:
        return 0

    counts, problems = netlist_check(args, top)
    if problems:
        for p in problems:
            print('error: register without a reset: ' + p)
        return 1
    total = sum(counts.values())
    print('reset audit: %d flip-flops in the netlist, every one of them with '
          'a reset' % total)
    for k in sorted(counts):
        print('    %-16s %5d' % (k, counts[k]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
