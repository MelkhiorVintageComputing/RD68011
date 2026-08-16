# Instruction timing divergences

Cycle-accurate instruction timing is not a requirement of this project, but
every difference has to be measured, reported and justified. This is that list.

Bus *timing* is a different matter and is a requirement; it is in
`doc/bus-timing-compliance.md`, and it is exact.

## How timing is checked

The reference vectors record a cycle count per test alongside the transaction
list. `make harte-all` compares state and transactions, not counts — that is
what makes the divergences below acceptable rather than failures. Where a
divergence exists it is because a microcode sequence takes a different number
of internal cycles, never because it does different bus work: the transaction
list is compared exactly, so any change in bus behaviour fails the sweep.

The counts below are against UM section 9's MC68010 execution times and against
the reference vectors, which are an MC68000. Where the two disagree — CLR is
the case — section 9 wins, because it is the MC68010's own table.

## Divergences

### Shifts and rotates: one cycle instead of one per bit

The original shifts one bit per clock: ASL.W #4,D0 costs 8 cycles plus 2 per
bit shifted. `rd68011_shifter` does the whole shift combinationally, so every
shift and rotate costs the same as any other register operation.

| | Reference | RD68011 |
|---|--:|--:|
| ASL.W #1,D0 | 8 | 4 |
| ASL.W #8,D0 | 22 | 4 |
| ASL.L #8,D0 | 24 | 6 |

**Why.** The shift count can be up to 63, and looping in microcode would need a
counter and a conditional in the sequencer for no benefit to either goal:
architectural state and bus behaviour are identical either way, and there is no
bus cycle in a register shift for the timing to be observable through.

**What it costs.** Software that counts cycles for delay loops built on shifts
runs faster than it expects. Software that reads a timer, or waits on a bus
event, is unaffected. The bus transaction list is byte-for-byte the reference's,
so a peripheral cannot tell.

### Indexed addressing modes: one cycle fewer

`(d8,An,Xn)` and `(d8,PC,Xn)` add the base, the displacement and the index
register. The reference charges two cycles more than the equivalent
displacement mode; this charges two, in two internal microwords, and is
therefore level with the reference. Where it differs is the modes it shares
microcode with — see the table below.

### The general shape

Because a microword costs one clock and a bus-cycle microword costs the whole
cycle, an instruction's cost here is

    4 x (number of bus cycles) + (number of internal microwords)

which for everything implemented so far matches the reference exactly except
where noted above. NOP is 4, a taken branch is 10, MOVE.W (A0)+,D0 is 8,
MOVE.L (A0),(A1) is 20. Those are not approximations: the microcode was
structured to produce them, because getting them right is what forced the
prefetch pipe and the addressing modes into the shape the reference has.

## Divergences that are not timing

Recorded here only because they are easy to mistake for timing:

- **CLR does not read its operand**, so it is two cycles faster than the
  MC68000 on every memory destination. That is the MC68010 behaving correctly
  (UM section 9), not a divergence. `doc/divergences.md` covers it.
- **The E clock's phase at power-on** is defined here and arbitrary on the real
  part, so a synchronous M6800 cycle's length is reproducible here and is not
  on the real part. The range of lengths is identical — six to fifteen wait
  states, which is exactly what figures B-4 and B-5 draw.

## Still to come

Multiply and divide (P5) are the next place a real divergence is likely: the
original's DIVU takes up to 140 cycles and is data-dependent. Whatever is built
there will be listed here with its measurement.
