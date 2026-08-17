# The Suska cross-check

`Inputs/Suska_Configware/68K10/` is another MC68010-compatible design, in VHDL,
by somebody else. `CLAUDE.md` is exact about what it is for:

> It exists here **only** to help validate testbenches — you may run it under
> ghdl and compare testbench behaviour against it. You may **not** read it to
> work out how to write our RTL.

This is the running of it. `make suska` builds a small program, runs it on both
processors, and compares the bus transactions.

**What was read.** The entity declaration of `wf68k10_top.vhd` — the port list,
which is what instantiating it requires and is the whole of the sanctioned use.
No architecture body was opened, and nothing in `rtl/` or in any testbench was
written from Suska's source. What appears below came from running it.

## What it was supposed to answer, and why it cannot

The hope was that Suska could corroborate the bus timing. Our bus testbenches
assert where each signal moves inside the S0–S7 ruler — AS at the rising edge
entering S2, the data strobes a half clock later on a read and two clocks later
on a write, read data latched on the falling edge of S6. Those assertions were
written from UM section 5 and figure 10-4. **If they were misread, every one of
our bus tests would agree with the misreading and pass.** An independent
implementation cannot make the same mistake by accident.

It cannot answer that, because its bus cycle is not the manual's:

| | MC68010 (UM section 5) | Suska WF68K10 |
|---|---|---|
| Cycle length, no wait states | 4 clocks (S0–S7) | **2 clocks** |
| AS asserts on | the rising edge entering S2 | **a falling edge** |
| AS low for | 3 clocks | 2 clocks |

Measured, not inferred: a read at address 0 asserts AS on the falling edge of
the sixth half-clock after reset completes and negates it four half-clocks
later. So nothing about the S0–S7 ruler can be corroborated from it. That is
the most useful thing this cross-check established, and it is why
`doc/bus-timing-compliance.md` rests entirely on the manual's own figures and
the machine-readable AC specification table instead.

It also needs a longer reset than the manual's minimum: ten clocks of RESET and
HALT together is not enough to start it, and twenty is.

### That conclusion held for the ruler, and no longer holds for the specifications

The paragraph above is right that the S0–S7 ruler cannot be compared. It was
wrong to leave it there, and `doc/ac-timing.md` is the sequel.

The AC specifications are stated in **nanoseconds against clock edges**, not in
bus states. Nothing in them mentions S2. So an instrument that measures pin
events in nanoseconds and never refers to a bus state can be pointed at both
processors, and `make xsim-timing` does exactly that: the same SystemVerilog
testbench, the same pads, the same slave and the same program, with the Suska
core instantiated through `sim/tb/timing/wf68k10_pins.vhd` under Vivado's
mixed-language simulator.

What it found is a fact about the manual as much as about either design.
Suska's two-clock bus cycle is **20 ns short of specification 14's minimum AS
width at 8 MHz** — 250 ns against 270 — and **exactly equal to it** at 12.5,
16.67, 16 and 20 MHz. Specification 14's minimum turns out to be precisely two
clock periods at every grade except the slowest, where it is not. So a two-clock
cycle is not a liberty taken with the manual; it is the tightest reading the
manual allows, exactly, and at 8 MHz it is one the manual forbids.

Ours holds AS for two and a half clocks and has 25 to 55 ns of room on the same
constraint at every grade.

`make xsim-setup` goes further and asks where each core samples its inputs, by
moving one a little later on each run until the behaviour changes. That is
black-box -- the observable is the transaction list -- so it needs no ruler at
all:

| | RD68011 | Suska WF68K10 |
|---|---|---|
| DTACK sampled | 187.5 ns after AS = 1.50 clocks | 125.0 ns = 1.00 clock |
| Read data latched | 312.5 ns = 2.50 clocks | 250.0 ns = 2.00 clocks |
| Stale DTACK tolerated | 375.0 ns | 250.0 ns |

Both are conformant, and one of them barely: specification 28 allows the system
240 ns to negate DTACK after the strobes, and this core tolerates 250.

**And it found a bug in ours.** Measuring how late a bus error may arrive and
still be recognised, this core's answer *moved* with the acknowledge -- 125 ns
after AS when DTACK was early, 250 ns when it was late, which is a second and
later recognition edge. Ours did not move, which is the signature of having no
late window at all. That was the clue that sent us to look, and what we found
was that our bus unit recognised every late bus error and never told the
sequencer. `doc/ac-timing.md` has the account.

This is the most useful thing the cross-check has produced, and it is worth
noting what kind of use it was: not agreement, which confirms little, but a
*difference in shape* that made one design's behaviour look odd beside the
other's.

## What it can and does answer

The *transaction list* is protocol-independent: which addresses, in which
order, read or written, in which address space. Two implementations of the same
instruction set have to agree about that whatever their bus timing is. Running
`sim/suska/bus_probe.S` — moves at all three sizes, `(An)`, `(An)+`, `-(An)`,
a displacement, a block-copy loop and stack traffic — on both:

```
suska: 79 data accesses, same addresses in the same order, read and written the same way
suska: 6 long writes through -(An) in the opposite word order, which is a known divergence
suska: 47 program reads in common; 0 only ours, 1 only Suska (the pipes are different depths)
```

That is an independent confirmation that the addressing modes compute the same
addresses, in the same order, at the same sizes, in the same address space.

### The two differences, and what settles them

**A long written through `-(An)` goes low word first here and high word first
on Suska.** `MOVE.L D4,-(SP)` with SP at $800 writes $7FE then $7FC here, and
$7FC then $7FE there. The reference vectors settle it: the SingleStepTests
compare the whole transaction list cycle by cycle, and the entire `MOVE.l` file
passes, so low word first is what the hardware the vectors were generated from
does. `doc/divergences.md` records the same order for `PEA` and for the
exception frame, which were established the same way.

**The prefetch pipes are different depths.** Suska runs one word further ahead,
so program reads interleave differently with data accesses even though the same
words are fetched. Ours is fixed by the vectors — 23492 tests compare the
transaction list exactly — and Suska's entity carries a `NO_PIPELINE` generic,
so it is a design choice there rather than a divergence in the ordinary sense.
The comparison therefore treats program reads as a set and data accesses as a
sequence.

## Where this leaves the testbenches

The original worry — that our bus tests might all agree with a misreading of
section 5 — is not resolved by Suska and cannot be. What resolves it instead:

- the recovered state ruler in `figure-10-04-read-cycle.md` and its siblings,
  which are redrawn from the manual with the numbers attached;
- `ac-electrical-specifications.csv`, 158 rows of machine-readable limits, which
  `doc/bus-timing-compliance.md` cites row by row;
- and the SingleStepTests transaction lists, which fix the *number and order* of
  cycles per instruction exactly, even though they say nothing about where the
  edges fall inside one.

Between them the ruler is pinned at both ends: the manual says where the edges
go within a cycle, and the vectors say which cycles happen. Suska corroborates
the second of those and contradicts nothing.
