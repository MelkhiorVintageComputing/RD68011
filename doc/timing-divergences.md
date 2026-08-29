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

`sim/tb/core_timing_tb.sv` is where the numbers below come from: it runs one
instruction at a time from reset and reports the clocks between the
instruction boundary before it and the one after, which is how the reference
counts. Four instructions whose section 9 entry is not in doubt -- NOP, MOVEQ,
ADD.W Dn,Dn and RTS -- are measured first, so a disagreement further down is
the instruction and not the harness.

**Every row is a regression check, not a report.** It carries what this design
takes as well as what section 9 gives, and the test fails if the first number
moves. Being a report rather than a check is what once let four rows quietly
measure an exception instead of the instruction they name: RTS and RTD popped a return
address out of memory the harness never wrote, and DIVU and DIVS divided by a
register that was zero. Each row now sets up what it needs.

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

which for most of what is implemented matches the reference exactly. NOP is 4,
a taken branch is 10, MOVE.W (A0)+,D0 is 8, MOVE.L (A0),(A1) is 20, and every
form of MOVEM and MOVEP is on the number. Those are not approximations: the
microcode was structured to produce them, because getting them right is what
forced the prefetch pipe and the addressing modes into the shape the reference
has.

The divergences are the sections that follow, and they are of two kinds. Most
are places where a whole operation happens in one microword instead of a loop
the original ran -- shifts, multiplies, the decimal correction -- and are
deliberate. One, the extra cycle every program-counter reload costs, is an
artefact and is written up as such.

### Multiply and divide: fixed cost, and much faster

The originals are data-dependent and take up to 40 (MULU), 42 (MULS), 108
(DIVU) and 122 (DIVS) clocks. Ours do not vary with the data at all.

| | Section 9 | RD68011 |
|---|--:|--:|
| MULU.W D1,D0 | 40 max | 5 |
| MULS.W D1,D0 | 42 max | 5 |
| DIVU.W D1,D0 | 108 max | 45 |
| DIVS.W D1,D0 | 122 max | 45 |

**Why.** Both are units of their own with registered operands and a registered
result, started by one microword and read by the next. The multiplier began as
a single ALU operation, and moving it out is what recovered about ten
nanoseconds of clock period: the ALU's result feeds the zero flag, which feeds
a conditional microword's address, which feeds the microcode store, whose
output has to reach the bus request pins inside half a clock -- and a
multiplier in that chain puts a DSP in it, whether or not any multiply ever
takes its operands from read data. `rtl/rd68011_mul.sv` has the argument.

The divider was sequential from the start, for the more ordinary reason that a
32-by-16 divide is large; `rtl/rd68011_divider.sv` explains. It takes 33 clocks
whatever the operands, plus the microcode loop that waits on it. That loop
polls every two clocks, so the cost is 45 rather than 41; making it one would
need a wait state in the sequencer of the kind bus cycles already have, and
nothing has yet been worth spending one on.

**What it costs.** Nothing a program can observe except elapsed time: no bus
cycle happens during either, so the transaction list is the reference's, which
is what the sweep checks.

### The BCD group and long ADDX/SUBX: register speed

| | Section 9 | RD68011 |
|---|--:|--:|
| ABCD Dy,Dx | 6 | 4 |
| SBCD Dy,Dx | 6 | 4 |
| NBCD Dn | 6 | 4 |
| ADDX.L Dy,Dx | 8 | 4 |

The same reason again: each is a single ALU operation here, where the original
takes extra internal cycles -- two for the decimal correction, and two more for
the second half of a long. The memory forms of all of them, which are where the
bus behaviour is, match exactly.

### RTS, RTR, RTE and RTD: one cycle more

| | Section 9 | RD68011 |
|---|--:|--:|
| RTS | 16 | 17 |
| RTD #0 | 16 | 18 |

Every instruction that loads the program counter from somewhere and then
refills the pipe spends a microword doing the load, because the prefetch that
follows takes its address from the program counter and so cannot be the
microword that writes it. RTD spends a second one adding its displacement to
the stack pointer.

This is the only divergence in the list that is an artefact rather than a
decision, and it would go away with a destination that wrote the program
counter from the two halves of a popped long directly. It is left as it is
because the bus cycles are unaffected and the sweep compares those.

### MOVEC and MOVES

| | Section 9 | RD68011 |
|---|--:|--:|
| MOVEC Rc,Rn | 10 | 12 |
| MOVEC Rn,Rc | 12 | 12 |
| MOVES.B (An),Rn | 18 | 15 |
| MOVES.L (An),Rn | 22 | 19 |

MOVEC pays for two microcode branches -- the supervisor check and the test
that the control register code names a register this part has -- where the
original folds at least one of them into work it was doing anyway. MOVES pays
for one and saves three, because its addressing-mode work is the same as every
other instruction's here.

### What matches exactly

Worth recording because it is most of the multi-cycle group: MOVEM at every
size, direction and mode; MOVEP at both sizes and both directions; CMPM; EXG;
and the byte and word forms of ADDX and SUBX all measure exactly what section 9
gives them. MOVEM is
the one that took design work to achieve -- 8+4n and 12+4n leave no room for
per-register overhead at all, which is why its register number comes from a
priority encoder over the mask and its loop branch rides the transfer
microword.

## Divergences that are not timing

Recorded here only because they are easy to mistake for timing:

- **CLR does not read its operand**, so it is two cycles faster than the
  MC68000 on every memory destination. That is the MC68010 behaving correctly
  (UM section 9), not a divergence. `doc/divergences.md` covers it.
- **The E clock's phase at power-on** is defined here and arbitrary on the real
  part, so a synchronous M6800 cycle's length is reproducible here and is not
  on the real part. The range of lengths is identical — six to fifteen wait
  states, which is exactly what figures B-4 and B-5 draw.

### Loop mode: exact where the manual gives a number

Loop mode (UM appendix A) exists to remove instruction fetches, so its cycle
counts are the ones most worth getting right -- and they come out right:

| | Section 9 | RD68011 |
|---|--:|--:|
| MOVE.W (An)+,(An)+, loop continued | 14 (table 9-3) | 14 |
| CMPM.W (An)+,(An)+, loop continued | 14 (table 9-17) | 14 |
| CLR.W (An)+, loop continued | 10 (table 9-11) | 10 |
| TST.W (An)+, loop continued | 10 | 10 |

That is not a coincidence and it is not tuning. A loop mode iteration here is
the looped instruction's bus cycles, plus one clock for the prefetch microword
whose fetch is suppressed, plus five for the DBcc -- test the condition,
decrement, test the result, and put the looped instruction back in `ir`. Four
plus one plus five is nine, and MOVE.W (An)+,(An)+ has two operand cycles: 14.

Where it does diverge is leaving the loop on an expired count, which costs four
more here than section 9's 18: the counter test is a microword and its branch
arm is another, where the original folds them into work it was doing anyway.
Leaving on the condition matches exactly, at 20.

### Fault processing and RTE with a long frame

Section 9 gives RTE 112(27/10) for "Long, Retry Read", 112(26/1) for "Long,
Retry Write" and 110(26/0) for "Long, No Retry" -- read counts of 26 and 27
against ours of 26, because the accessibility probe at SP+56 and the version
word at SP+26 are read separately here before the walk that reads them again.
That makes ours 28 reads and a few internal microwords longer than the
original's, in exchange for doing UM 6.4's three checks in the order it
specifies them.

Building a frame is 26 writes and a two-word vector fetch either way. Neither
number is measured against a reference, because none exists: the vectors are an
MC68000 with a seven-word frame.

## What changed the clock and not these numbers

Three things came off the critical path while the frequency was being chased --
the multiplier moved into a unit of its own, the decoder stopped taking its
address through the ALU, and the late second read of the microcode store gave
way to previews carried in the microword. None of them changed a cycle count,
which is what
`sim/tb/core_timing_tb.sv` is there to say: every row of it was measured again
afterwards and none moved. `doc/implementation.md` has what they did change.
