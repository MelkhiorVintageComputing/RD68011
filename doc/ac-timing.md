# AC-specification conformance

What section 10's nanosecond limits say about this design, about the Suska
WF68K10, and about a variant that asserts AS half a clock later than we do.

```sh
make timing        # measure and judge this design; part of `make check`
make xsim-timing   # the same instrument applied to the Suska core, under xsim
```

## Why this exists, and what was wrong before

Every other bus testbench here asserts **edge placement**. `sim/tb/bus_rw_tb.sv`
says `expect_window(tag, t0, OB_ASN, 1'b0, 2, 6)` — AS asserted from S2 through
S6 and nowhere else — and that ruler comes from UM section 5 and figure 10-4.

`doc/bus-timing-compliance.md` used to draw a further conclusion from the fact
that the RTL is delay-free: that the nanosecond limits are *"not simulated, and
not simulable… an invented delay that passes proves nothing"*. The first half of
that is right and the second half is not. One invented delay proves nothing. The
question is not whether some delay assignment passes but whether **any** does,
and that question has an exact answer.

The prompt was an observation about the specification's own arithmetic. At
10 MHz specification 6 lets the address become valid up to 50 ns after the clock
goes low — a whole half period — and specification 11 then demands 20 ns between
address-valid and AS-asserted. So the address at its worst case arrives just as
the S2 rising edge does, and AS cannot follow for another 20 ns. The window the
specification actually allows is wider than the figure draws, and possibly wide
enough to admit designs our testbenches reject.

## The three classes

Every limit is one of three things, and only one of them is a property of an
RTL model at all.

| Class | Specifications | What it is |
|---|---|---|
| **1 — clock to output** | 6, 6A, 7, 8, 9, 12, 18, 20, 23, 53 | Zero in a delay-free model. A **budget** on an unknown pad delay — with a ceiling *and sometimes a floor*: specification 9 is never below 3 ns at any grade |
| **2 — output to output** | 11, 11A, 13, 14, 14A, 15, 17, 20A, 21, 21A, 22, 25, 26, 55 | The design's edge assignment, scaled by the clock period. This is the class that can be decided |
| **3 — input** | 27, 27A, 28, 29, 29A, 30, 31, 47, 48 | Demands on the memory system, not on the processor. Measured, not judged |

Class 1 having a *floor* matters and is easy to miss. Treating those limits as
ceilings alone makes every design conformant and the tool useless.

## How the question becomes exact

Write `d_e` for the unknown pad delay on event `e`, and `m` for the spacing
measured with no delays in the way. The event happens at `m + d_e`, so a limit

    (m + d_to) - (m_from + d_from)  >=  L

rearranges to `d_from - d_to <= m - L`. Every limit in classes 1 and 2 has that
shape. A system of them is a **difference constraint system**, feasible exactly
when its constraint graph has no negative cycle — which Bellman–Ford decides,
and when it fails, the cycle it returns *is the proof*: the specifications that
cannot all hold, and the number of nanoseconds by which they miss.

`tools/timing/feasible.py` does this. `tools/timing/analyse.py` reports it.

**INFEASIBLE is a proof. FEASIBLE is conditional**, on how tightly the two
transition delays of one pin are tied together. `--pad-skew 0` gives each pin a
single delay, which is the conservative reading and the default for `make
timing`; omitting it leaves them independent, which is the loosest. The
difference is not academic — see Suska below.

## Where the anchors come from

A limit is useless without knowing which two events it separates, and the CSV
does not say. The figures do, and they have a machine-readable source:
`Inputs/doc/…/MC68000UM_split/make-figure-svg.py`, whose `f.span()` calls place
every callout on the redrawn read and write cycles.
`tools/timing/anchors.py` transcribes all thirty, citing the line each came
from.

Several specifications say "clock high" or "clock low" without saying which
edge. Resolving that mattered, and the measurement settled it against the
obvious reading:

> **A clock anchor is the nearest clock edge of *either* polarity**, preceding
> the pin event for an output delay and following it for an input setup.

That is not the literal text, which names a polarity. It is nevertheless the
right rule, for a reason the data supplied. A clock-to-output limit bounds how
long a pin takes to settle after the edge that *caused* it. Ours drives the
address from the falling edge entering S1 on a cycle that follows another, and
from a rising edge on a cycle that follows an idle bus. Measured to the nearest
preceding *falling* edge, that second case charges the design a half period it
never spent and reports specification 6 as violated by 0.5 ns at 8 MHz — when
the address in fact arrived **early**. Being early is not a violation of a
maximum.

`anchors.py`'s self-check confirms the licence for the substitution: on the
ruler the manual's own figure was drawn on, both rules pick the same edge for
all twelve clock anchors. They differ only for a design whose events fall
elsewhere — which is exactly the case the polarity rule gets wrong.

`--strict-polarity` computes the literal reading anyway, because for the AS
placement question the two readings genuinely disagree and both are worth
seeing.

## This design

`make timing`, one measurement run per grade — the spacings scale with the
period, so an 8 MHz recording is evidence about 8 MHz and nothing else.
Conservative reading, one delay per pin:

| Grade | Verdict | Binding constraint |
|---|---|---|
| 8 MHz | feasible | spec 14 min, 42.5 ns of room |
| 10 MHz | feasible | spec 18 max, 45.0 ns of room |
| 12.5 MHz | feasible | spec 9 min, 37.0 ns of room |
| 16.67 MHz (12F) | feasible | spec 14 min, 30.0 ns of room |
| 16 MHz | feasible | spec 9 min, 27.0 ns of room |
| 20 MHz | feasible | spec 9 min, 22.0 ns of room |

Conformant at every grade in the table, with room to spare at all of them. That
is a stronger statement than the edge-placement tests could make, and a
different one: it says a real implementation of this state machine could be
built to the specification, not merely that the state machine matches a drawing.

### The skew envelope

The number an implementer actually wants is not the verdict but how much the
pads may drift apart. Floyd–Warshall over the same constraint graph gives the
tightest implied bound on every pair:

| Grade | Address may lag AS by | AS may lag address by |
|---|---|---|
| 8 MHz | 32.5 ns | 60 ns |
| 10 MHz | 30 ns | 50 ns |
| 12.5 MHz | 25 ns | 40 ns |
| 16.67 MHz | 15 ns | 40 ns |
| 16 MHz | 15 ns | 30 ns |
| 20 MHz | 15 ns | 25 ns |

The 10 MHz figure of 30 ns is the closed form of the original observation:
measured spacing 50 ns, specification 11's minimum 20 ns, so `d_address −
d_AS ≤ 30`. The solver reproduces the hand derivation, which is the cheapest
check available that it is computing what it claims to.

## Asserting AS half a clock later

The question that prompted all this. A half-period pad delay on AS puts it on
the S2/S3 falling edge, which from the bus's side is indistinguishable from a
design that asserts it there — so no RTL change is needed to ask:

```sh
python3 tools/timing/corners.py late-as 8      # the -P options that do it
```

Three readings, three answers, all measured:

| Reading | Verdict at 8 MHz |
|---|---|
| Literal — specification 9 anchored to a rising edge | **INFEASIBLE**, short by 2.5 ns: spec 9 max, measured 62.5 against ≤ 60 |
| Causal, one delay per pin | **INFEASIBLE**, short by 20.0 ns: spec 14 min, measured 250.0 against ≥ 270 |
| Causal, transition delays independent | feasible, spec 9 min, 39.0 ns of room |

**Under the literal reading** AS lands a full half period after the reference it
is measured from, against a 60 ns maximum. That holds at 8, 10, 12.5, 16 and
20 MHz; only the 16.67 MHz 12F grade, whose 40 ns maximum exceeds its 30 ns half
period, admits it.

**Under the causal reading** the answer changes, because AS is now caused by the
falling edge and specification 9 re-anchors to it. What binds instead is
specification 14: AS asserts a half clock later and still negates when it did,
so its asserted width falls from 312.5 ns to 250 ns against a 270 ns minimum. It
comes back only if the AS pad negates 20 ns later than it asserts — which the
independent-delay relaxation permits and one delay per pin does not.

So the honest answer to "does asserting AS on the S2/S3 negedge break the AC
specifications" is: **not obviously, and not for the reason one would expect.**
Specifications 6 and 11 do not forbid it — that part of the original reasoning
is right, and they do push AS into the second half of S2. What forbids it is
specification 9's maximum under a literal reading, or specification 14's minimum
width under a causal one. Either way it costs the half clock somewhere.

Because the placement is defensible under one reading and not the other, and
because the manual's own figure draws AS at 0.8 of a state into S2 rather than
at either boundary, this design keeps its S2 rising edge and the finding is
recorded rather than acted on.

## The clock is not necessarily symmetric

Specification 1 fixes the cycle time at 125 ns for the 8 MHz part and
specifications 2 and 3 the pulse width at 55 to 125 ns, so each half may be
anywhere from 55 to 70 ns: a duty cycle of 44 to 56 per cent. This design puts
one bus state in each half period, so an asymmetric clock moves half of its
state boundaries — and no other testbench here can express that, since they all
index observations by half-clock tick and a tick is not a fixed length.

```sh
vvp ac.vvp +image=bus_probe.hex +period=125 +clk_hi=55   # 44 per cent
```

At 8 MHz, across the whole legal range:

| Duty | Binding constraint | Address may lag AS by |
|---|---|---|
| 44 % (hi 55, lo 70) | spec 14 min, 35.0 ns of room | 40.0 ns |
| 50 % (hi 62.5, lo 62.5) | spec 14 min, 42.5 ns of room | 32.5 ns |
| 56 % (hi 70, lo 55) | spec 14 min, 50.0 ns of room | 25.0 ns |

Conformant throughout, and the two constraints move in opposite directions,
which is what one would want to be able to check. S1 occupies the low half, so
the address-to-AS gap *is* `clk_lo` and the envelope is exactly `clk_lo` minus
specification 11's 30 ns. AS is asserted across S2 to S6, three high halves and
two low ones, so its width is `3·hi + 2·lo` — 320 ns at the high-duty end and
305 at the low. A skewed clock therefore costs margin on specification 11 at one
end and on specification 14 at the other, and the symmetric clock is not the
worst case for either.

## The Suska WF68K10, measured on the same instrument

`doc/suska-crosscheck.md` records that the timing of that core could not be
compared with ours at all: its bus cycle is two clocks where the manual's is
four, and its AS asserts on a falling edge, so the S0–S7 ruler has nothing to
say about it. **That conclusion stands for the ruler and is now obsolete for the
specifications**, because the AC limits are stated against clock edges rather
than bus states, and `tools/timing/` never mentions a bus state.

`make xsim-timing` runs it under Vivado xsim — the same SystemVerilog
testbench, the same pads, the same slave, the same program — and judges it with
the same code:

| Grade | Verdict | Binding constraint |
|---|---|---|
| 8 MHz | **INFEASIBLE**, short by 20.0 ns | spec 14 min: measured 250.0 ns, limit ≥ 270 |
| 10 MHz | feasible | spec 14 min, 5.0 ns of room |
| 12.5 MHz | feasible | spec 14 min, **0.0 ns of room** |
| 16.67 MHz | feasible | spec 14 min, **0.0 ns of room** |
| 16 MHz | feasible | spec 14 min, **0.0 ns of room** |
| 20 MHz | feasible | spec 14 min, **0.0 ns of room** |

Its two-clock bus cycle is exactly as long as specification 14's minimum AS
width at four of the six grades, and 20 ns short of it at 8 MHz. The reason is
in the specification rather than in either design: specification 14's minimum is
**exactly two clock periods** at 12.5, 16.67, 16 and 20 MHz — 160 ns on an 80 ns
cycle, 120 on 60, 100 on 50 — and 8 MHz is the one grade where it is not, at
270 ns against a 250 ns two-clock cycle.

So a two-clock bus cycle is not an aggressive reading of the manual. It is the
tightest one the manual permits, exactly, at every grade but the slowest — and
at the slowest it is not permitted at all. That is a fact about the MC68010's
AC table that neither the transaction cross-check nor the state-ruler tests
could have found, and it is what this instrument was built to be able to say.

Our own design has 25 to 55 ns of room on the same constraint, because it holds
AS for two and a half clocks rather than two.

## Where each processor samples its inputs

The class-3 limits constrain the memory system, so `make timing` can only report
what the slave happened to do. What the *processor* requires is a different
question, and `make timing-setup` answers it by moving one input a little later
on each run and finding where the behaviour changes.

The observable is black-box on purpose: the same program from reset each time,
and the transaction list it produces. An input latched too late gives a wrong
value and the addresses diverge; an acknowledge that misses its edge costs a
wait state and the run lengthens; a stale acknowledge terminates the next cycle
early and it shortens. Nothing looks inside the processor, which is what lets
the identical measurement run against the other core.

**RD68011 at 8 MHz** — `make timing-setup`, part of `make check`:

| Spec | | Measured | Limit | |
|---|---|---|---|---|
| 47 | DTACK setup it needs | 0.028 ns | ≤ 10 | ok |
| 27 | read-data setup it needs | 0.025 ns | ≤ 10 | ok |
| 29 | read-data hold it needs | 0.000 ns | ≤ 0 | ok |
| 28 | stale DTACK it tolerates | 375.0 ns | ≥ 240 | ok |

The measured setups are the bisection's own resolution, which is the right
answer for a delay-free model: it needs no setup, and what matters is that its
requirement is nowhere near the 10 ns the specification allows the system.

### The sampling instants, and the comparison

The numbers worth putting side by side are not the verdicts but *where in the
cycle each input is acted on*, in nanoseconds from AS asserting:

| | RD68011 | Suska WF68K10 |
|---|---|---|
| DTACK sampled | **187.5 ns** = 1.50 clocks | **125.0 ns** = 1.00 clock |
| Read data latched | **312.5 ns** = 2.50 clocks | **250.0 ns** = 2.00 clocks |
| Stale DTACK tolerated | 375.0 ns | 250.0 ns |

Ours confirms, black-box and in nanoseconds, exactly what
`doc/bus-timing-compliance.md` claims from reading the manual: 1.5 clocks after
AS is the falling edge ending S4, where DTACK is sampled, and 2.5 clocks is the
falling edge ending S6, where read data is latched. That the documentation and
an experiment which never mentions a bus state agree is worth more than either
alone.

Suska samples both a half clock earlier in its own shorter cycle, and both cores
are conformant — but not equally. Specification 28 permits the system 240 ns to
negate DTACK after the strobes; Suska tolerates 250.0 ns, a margin of 10 ns,
where ours has 135. A slave that took the 240 ns the manual explicitly allows
would come within ten nanoseconds of breaking that core.

### The late bus error, and the bug it found

Specification 48\* is the only line in the whole AC table that names the MC68010
alone: *DTACK Asserted to BERR Asserted*, **maximum 80 ns at 8 MHz**. It is the
timing side of UM 5.4.1's late bus error — table 5-1 cases 4 and 6, where a BERR
arriving within a clock *after* the acknowledge still faults the cycle, which an
MC68000 would have completed normally. Being a maximum on the system, it obliges
the processor to accept a window at least that wide.

Measured, with the fault confined to a single access, this design accepted 7.5 ns
against the required 80 — and the recognition instant did not move when the
acknowledge did, which is the signature of there being no late window at all.
`sim/tb/bus_error_tb.sv` case 4 nevertheless passed. Probing the interface
between the two units settled it in one line:

```
EV    5845.001 BERR assert
PROBE 6000.000 req_end=2          <- CE_BERR: the bus unit saw it
                                  <- req_fault never asserted
```

**The bus unit recognised every late bus error and told nobody.** `req_end` is a
report; `rd68011_biu.sv`'s own port comment says it arrives a clock later than a
microword can act on, which is why the sequencer keys off `req_fault` instead.
The early-BERR path set `term_berr`, which drives `req_fault`. The late path set
`end_code` and nothing else. So `req_fault` never rose, the sequencer never
faulted, and cases 4 and 6 were effectively unimplemented — while the directed
test passed, because it checked `req_end`, which *was* set.

The fix could not simply set `term_berr`: that signal also sends the state
machine on to S9, and a late bus error must still end in S7 because the transfer
already completed (figure 5-26). It needed its own `term_berr_late`, feeding
`req_fault` and nothing else.

| | Before | After | Required |
|---|---|---|---|
| Window, acknowledge early | 167.5 ns | 292.5 ns | — |
| Window, acknowledge late | **7.5 ns** | **132.5 ns** | ≥ 80 |
| Recognised at | 187.5 ns (the DTACK edge) | 312.5 ns (the S6 edge) | — |

Both cases now recognise at the falling edge ending S6, which is exactly where
UM 5.4.1 and `doc/bus-timing-compliance.md` say the late window is. The measured
132.5 ns clears specification 48\* with 52.5 ns to spare, so this row is now
judged rather than merely reported.

`sim/tb/bus_error_tb.sv` gained the assertion it was missing — that the fault
reached the sequencer, and not merely that it was recorded. Reverting the
one-line fix makes it fail, which is the only evidence worth having that a
regression test tests anything.

**What is worth taking from this.** The bug survived the reference vectors, the
directed bus tests, real programs and co-simulation against Musashi. None of
them could have caught it: the vectors are an MC68000 and have no late bus
error, Musashi has no bus at all, and the directed test checked the signal that
was set instead of the one that mattered. It took a measurement that asked the
specification's own question — *how late may this arrive and still work* — and
then took disagreement between two of this project's own testbenches seriously
enough to go and look.

The other core, measured identically, had a recognition instant that moved with
the acknowledge where ours did not. That was the clue that the mechanism was
real and ours was missing it, and it is the most useful thing the Suska
cross-check has produced.

### What is asserted, and what is not

Not that an input arriving *later* than the threshold is refused. Specification
47 obliges the system to be early; it does not oblige the processor to reject a
late input, and a real part very likely accepts one. A test written that way
would encode this implementation's flop into the suite and fail the day somebody
added a synchroniser — a false alarm on a correct change. So the threshold is
reported and the assertion is one-directional: the requirement is no worse than
the specification allows.

## What the instrument is

| | |
|---|---|
| `sim/models/rd68011_pads.sv` | Output pads with sixteen settable delays. Reports any transition its own inertial delay swallows, so a lost pulse is loud rather than silent |
| `sim/models/rd68011_slave_ac.sv` | A slave whose answers are timed in nanoseconds from the strobes rather than on clock edges |
| `sim/tb/timing/rd68011_timing_harness.svh` | Clock (with independently settable halves), pads, slave, and the event log. Instantiates no processor |
| `sim/tb/timing/rd68011_ac_tb.sv`, `wf68k10_ac_tb.sv` | The same harness with each processor in it |
| `sim/tb/timing/wf68k10_pins.vhd` | The Suska core behind our pin bundle |
| `tools/timing/specs.py` | The CSV, with the manual's known defects corrected and cited |
| `tools/timing/anchors.py` | What each specification measures between, from the figure generator |
| `tools/timing/events.py` | The log, and the spacings in it |
| `tools/timing/feasible.py` | The constraint system and Bellman–Ford |
| `tools/timing/analyse.py` | The verdict |

The testbenches emit times and nothing else — no testbench knows what a
specification is. That split is what lets an anchor be corrected without
re-elaborating anything, and what let the Suska core be judged by exactly the
same code as ours.

## What the measurement does not cover

- Arbitration and M6800 cycles. Their limits are in clocks rather than
  nanoseconds and `sim/tb/bus_arb_tb.sv` and `sim/tb/bus_m6800_tb.sv` already
  check them; the anchor table is arranged so adding figures 10-6 to 10-11 is a
  table entry rather than new code.
- Real pad models. Every delay here is a free variable bounded by the manual,
  not a number from a process.
- Setup and hold at the other five grades. `make timing-setup` measures them at
  8 MHz, which is the grade the thresholds are judged against; the bisections
  are per-grade already, so the rest is runs rather than code.
- Specifications 29A and 31, which are measured and reported but not judged.
