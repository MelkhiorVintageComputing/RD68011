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

One register has no reset, and it is named here
-----------------------------------------------
The microcode store's output register, `uw_q` in rtl/gen/rd68011_ucode_rom.sv,
takes no reset value. It cannot: a block memory's read register is inside the
memory primitive, so requiring a reset on it requires the store to be logic --
6665 LUTs on the Artix-7 and 23604 logic elements on the MAX 10, which
doc/size-and-speed.md measures.

What the rule exists to prevent is a design that depends on power-on state.
This one does not. The store is addressed by `upc_nxt`, which rd68011_seq.sv
forces to ENTRY_RESET whenever `rst_n` or `reset_sync_n` is asserted, so one
clock edge during reset leaves the register holding ROM[ENTRY_RESET] -- the
same microword `upc`'s own reset branch selects, so the pair is consistent from
that edge onwards. The register's value is determined by reset, by a different
mechanism from every other register in the design; it is not undefined, and it
is not relied upon before it is written.

The obligation this creates is that the clock runs for at least one edge while
reset is asserted. Every testbench does: core_reset holds it for four and
harte_tb for one.

The exemption is enforced rather than merely allowed. The netlist check asserts
that no resetless flop exists anywhere outside this instance, so the exemption
cannot silently widen; the count inside it is reported, not gated, because
yosys const-folds whichever of the microword's always-zero bits survive and
pinning an exact number would be brittle for no benefit.
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

# The one module allowed to hold a register without a reset -- see the module
# docstring for why, and doc/implementation.md for the same argument in prose.
#
# Named by module rather than by instance because a flattened netlist cannot be
# asked: `flatten` hands the flops to yosys's `ff` pass, which renames them to
# `$auto$ff.cc:266:slice$41200` and drops the `src` attribute, so neither the
# hierarchy nor the source file survives to select on. Both were tried. A
# hierarchical `stat -top` keeps the attribution, multiplies instance counts
# into the design total by itself, and runs faster.
EXEMPT = 'rd68011_ucode_rom'

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
    """Synthesise to gates and read back what kind of flops came out.

    Two statistics blocks are asked for: the whole design, and the exempt
    instance alone. A cell type is a problem when the design holds more of it
    than the exemption accounts for, which enforces the exemption by location
    without having to enumerate yosys's resetless cell types -- a type nobody
    thought of still fails, which is the safe direction.
    """
    yosys = os.environ.get('YOSYS', 'yosys')
    script = ('read_verilog -sv %s; hierarchy -check -top %s; '
              'synth -top %s; stat -top %s'
              % (' '.join(paths), top, top, top))
    try:
        out = subprocess.run([yosys, '-p', script], capture_output=True,
                             text=True, check=True).stdout
    except FileNotFoundError:
        return None, ['yosys not found; set YOSYS to it']
    except subprocess.CalledProcessError as e:
        return None, ['yosys failed:\n' + e.stderr[-2000:]]

    # `stat -top` prints one block per module, then `=== design hierarchy ===`
    # and a single aggregate with every instance counted -- which is the total,
    # and is why the modules above it must not be added up as well. Reading
    # more than one block as the design counted every flop twice once before:
    # the audit reported 2758 where the design has 1379, which Vivado (1340 FF
    # placed) and Quartus (1357 registers) both contradict.
    def floplike(block):
        got = {}
        for line in block.splitlines():
            m = re.match(r'\s+(\$_\w+_)\s+(\d+)\s*$', line)
            if m and FLOPLIKE.match(m.group(1)):
                got[m.group(1)] = got.get(m.group(1), 0) + int(m.group(2))
        return got

    # `synth` prints statistics of its own before the explicit `stat -top`, so
    # only the last block is the one asked for.
    final = out.rsplit('Printing statistics.', 1)[-1]
    if '=== design hierarchy ===' not in final:
        return None, ['yosys printed no design hierarchy, so nothing can be '
                      'attributed to a module']
    hier = final.split('=== design hierarchy ===', 1)[1]
    counts = floplike(hier)

    # The exempt module's own block, and it must be instantiated exactly once
    # or its per-module counts would not be its contribution to the total.
    marker = '=== %s ===' % EXEMPT
    if marker not in final:
        return None, ['%s is not in the netlist, so the exemption names '
                      'nothing' % EXEMPT]
    ninst = sum(int(m) for m in
                re.findall(r'^\s+%s\s+(\d+)\s*$' % re.escape(EXEMPT), hier,
                           re.M))
    if ninst != 1:
        return None, ['%s is instantiated %d times; the exemption assumes one'
                      % (EXEMPT, ninst)]
    exempt = floplike(final.split(marker, 1)[1].split('=== ', 1)[0])
    if not counts:
        return None, ['no flops in the netlist, which cannot be right']

    # A resetless type is only allowed where the exemption accounts for every
    # one of it. One more than that anywhere else and the audit fails.
    bad = ['%s: %d, of which %d are in %s'
           % (k, v, exempt.get(k, 0), EXEMPT)
           for k, v in sorted(counts.items())
           if not RESET_OK.match(k) and v > exempt.get(k, 0)]
    return (counts, exempt), bad


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

    got, problems = netlist_check(args, top)
    if problems:
        for p in problems:
            print('error: register without a reset: ' + p)
        return 1
    counts, exempt = got
    total = sum(counts.values())
    nex = sum(exempt.values())
    print('reset audit: %d flip-flops in the netlist, every one of them with '
          'a reset' % (total - nex))
    for k in sorted(counts):
        n = counts[k] - exempt.get(k, 0)
        if n:
            print('    %-16s %5d' % (k, n))
    if nex:
        # Reported, not gated: yosys const-folds whichever of the microword's
        # always-zero bits survive, so an exact number would be brittle.
        print('reset audit: %d more in %s, which the module docstring exempts '
              'and explains' % (nex, EXEMPT))
    return 0


if __name__ == '__main__':
    sys.exit(main())
