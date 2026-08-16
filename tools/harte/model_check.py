#!/usr/bin/env python3
"""Check the prefetch model against the reference vectors.

Before writing a line of microcode, the model of the prefetch pipe has to be
right, because every instruction's bus behaviour is built on it. This script
states the model and tests it against every vector for the opcodes it claims to
cover -- thousands of randomised cases each.

THE MODEL

Three pieces of visible state at an instruction boundary:

    ir      the opcode word of the instruction about to execute
    irc     the next word from memory, already fetched
    pc      the address of the word *after* irc, i.e. the next fetch address

so at the start of an instruction at address A:  ir = [A], irc = [A+2],
pc = A+4. The vectors expose ir and irc as prefetch[0] and prefetch[1], and
their 'pc' is MAME's m_au, which the test repository's README describes as
"next prefetch address [...] +4 from where the test starts executing".

Two primitives:

    PF    irc <- [pc]; pc <- pc + 2          one bus read, program space
    ADV   ir  <- irc                         no bus cycle

An instruction with N extension words consumes each one out of irc, doing a PF
after each to refill it, and ends with ADV+PF. That is N+1 reads in all, and it
leaves ir and irc holding the next instruction's first two words.

A taken branch loads pc with the target and then does PF, ADV, PF -- two reads,
because both ir and irc have to be refilled from the new stream.

Run:  python3 tools/harte/model_check.py
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reader                                          # noqa: E402


def reads(t):
    """The program-space reads a test performed, as (addr, data)."""
    return [(x[3], x[5]) for x in t['transactions']
            if x[0] == 'r' and x[2] in (2, 6)]


def clean(t):
    """True if nothing went wrong -- no address error, no exception."""
    return not any(x[0] in ('re', 'we') for x in t['transactions'])


def check_straight_line(op, ext_words, limit=None, supervisor_only=False):
    """An instruction that falls through: N+1 reads, ir/irc shifted along."""
    n = bad = 0
    for t in reader.read_opcode(op):
        if not clean(t):
            continue
        if supervisor_only and not (t['initial']['sr'] >> 13) & 1:
            continue
        if limit and n >= limit:
            break
        ini, fin = t['initial'], t['final']
        n += 1

        want_reads = ext_words + 1
        got = reads(t)
        if len(got) != want_reads:
            bad += 1
            if bad < 4:
                print('  %s: %d program reads, model says %d'
                      % (t['name'], len(got), want_reads))
            continue

        # The reads march up from the starting pc, two bytes at a time.
        for i, (addr, _) in enumerate(got):
            if addr != (ini['pc'] + 2 * i) & 0xFFFFFFFF:
                bad += 1
                if bad < 4:
                    print('  %s: read %d at %06x, model says %06x'
                          % (t['name'], i, addr, ini['pc'] + 2 * i))
                break
        else:
            # pc advances by one word per read.
            if fin['pc'] != (ini['pc'] + 2 * want_reads) & 0xFFFFFFFF:
                bad += 1
                if bad < 4:
                    print('  %s: pc %08x -> %08x, model says %08x'
                          % (t['name'], ini['pc'], fin['pc'],
                             ini['pc'] + 2 * want_reads))
                continue
            # ir and irc end holding the last two words read, except with no
            # extension words, where irc came in already holding the next one.
            want_ir = ini['prefetch'][1] if ext_words == 0 else got[-2][1]
            want_irc = got[-1][1]
            if fin['prefetch'][0] != want_ir or fin['prefetch'][1] != want_irc:
                bad += 1
                if bad < 4:
                    print('  %s: prefetch -> %04x %04x, model says %04x %04x'
                          % (t['name'], fin['prefetch'][0], fin['prefetch'][1],
                             want_ir, want_irc))
    return n, bad


def check_branch():
    """Bcc: taken loads pc and refills both words; not taken falls through."""
    n = taken = nottaken = bad = 0
    for t in reader.read_opcode('Bcc'):
        if not clean(t):
            continue
        ini, fin = t['initial'], t['final']
        n += 1
        got = reads(t)

        # An 8-bit displacement of zero means a 16-bit one follows.
        opcode = ini['prefetch'][0]
        disp8 = opcode & 0xFF
        long_form = (disp8 == 0)
        if long_form:
            disp = ini['prefetch'][1]
            if disp & 0x8000:
                disp -= 0x10000
        else:
            disp = disp8 - 0x100 if disp8 & 0x80 else disp8

        # The instruction is at pc - 4; a displacement is measured from the
        # word after the opcode, which is pc - 2.
        target = (ini['pc'] - 2 + disp) & 0xFFFFFFFF

        # Taken: two reads, at the target and target+2, pc ends target+4.
        if len(got) == 2 and got[0][0] == target:
            taken += 1
            if fin['pc'] != (target + 4) & 0xFFFFFFFF:
                bad += 1
                if bad < 4:
                    print('  %s: taken, pc -> %08x, model says %08x'
                          % (t['name'], fin['pc'], target + 4))
            elif (fin['prefetch'][0] != got[0][1] or
                  fin['prefetch'][1] != got[1][1]):
                bad += 1
                if bad < 4:
                    print('  %s: taken, prefetch -> %04x %04x, read %04x %04x'
                          % (t['name'], fin['prefetch'][0], fin['prefetch'][1],
                             got[0][1], got[1][1]))
        else:
            # Not taken: the short form falls straight through with one read,
            # the long form has an extension word, so two.
            nottaken += 1
            want = 2 if long_form else 1
            if len(got) != want or got[0][0] != ini['pc']:
                bad += 1
                if bad < 4:
                    print('  %s: not taken, %d reads from %06x, model says '
                          '%d from %06x' % (t['name'], len(got),
                                            got[0][0] if got else 0,
                                            want, ini['pc']))
    return n, taken, nottaken, bad


def main():
    total_bad = 0

    print('Prefetch model against the SingleStepTests vectors')
    print()

    for op, ext in [('NOP', 0), ('SWAP', 0), ('EXT.w', 0),
                    ('MOVE.q', 0), ('EXG', 0)]:
        n, bad = check_straight_line(op, ext)
        total_bad += bad
        print('  %-10s %5d clean vectors, %d disagree' % (op, n, bad))

    # RESET is privileged, so only the supervisor-mode vectors fall through;
    # the rest take a privilege violation and are a different shape entirely.
    # (Those user-mode vectors are worth a look on their own: they push SR and
    # PC as three words, where an MC68010 pushes four -- format and vector
    # offset as well. That is one entry in the divergence filter, confirmed
    # against the reference rather than assumed.)
    n, bad = check_straight_line('RESET', 0, supervisor_only=True)
    total_bad += bad
    print('  %-10s %5d clean supervisor vectors, %d disagree' % ('RESET', n, bad))

    n, taken, nottaken, bad = check_branch()
    total_bad += bad
    print('  %-10s %5d clean vectors (%d taken, %d not), %d disagree'
          % ('Bcc', n, taken, nottaken, bad))

    print()
    if total_bad:
        print('MODEL DISAGREES with the reference in %d cases' % total_bad)
        return 1
    print('Model agrees with the reference everywhere it was checked.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
