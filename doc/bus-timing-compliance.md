# Bus timing compliance

What `rd68011_biu` does on the pins, where each behaviour comes from in the
manual, and which of Section 10's 1092 AC limits this project can and cannot
check.

Sources, all under `Inputs/doc/MC68030_Doc_More_Readable/MC68000UM_split/`:
§3 signal description, §5 16-bit bus operation, appendix B M6800 peripheral
interface, `ac-electrical-specifications.csv`, and the thirteen redrawn
`figure-10-*.md`.

## What is checked, and what cannot be

The RTL is delay-free: an output changes exactly on the clock edge that causes
it. So there are two very different kinds of limit in Section 10, and only one
of them is a property of this design at all.

**Edge placement in bus states — checked in simulation.** "AS asserts on the
rising edge of S2" is a fact about the state machine. It is also recoverable
from the source: figure 10-4's horizontal axis is the manual's own S0–S7 ruler,
measured off the 300 dpi scan (the printed labels sit 89 px apart, each centred
on a clock plateau). Every testbench under `sim/tb/` indexes its observations by
half-clock tick from the S0 rising edge and asserts against that ruler.

**Nanosecond minima and maxima — not measurable here, but decidable.** "Clock
Low to Address Valid ≤ 62 ns at 8 MHz" (spec 6) is a property of the pad, the
process and the place-and-route, not of the RTL, and no simulation of a
delay-free model can measure it. That much this document said from the start and
it is still true.

What it went on to say — that such limits are therefore "not simulable", because
"an invented delay that passes proves nothing" — was wrong, and
`doc/ac-timing.md` is the correction. One invented delay proves nothing. But the
limits split into a *budget* on each pad delay and a set of required *separations*
between pins, the separations are the design's own edge assignment, and the
question "is there any assignment of delays inside the budget that meets every
separation" is a system of difference constraints with an exact answer. It is
decided by Bellman–Ford, and an infeasible system names the specifications that
conflict.

Run as `make timing`, which is part of `make check`. This design is conformant
at all six speed grades, with 22 to 45 ns of room on the binding constraint. The
same instrument applied to the Suska WF68K10 finds its two-clock bus cycle
20 ns short of specification 14's minimum AS width at 8 MHz and exactly equal to
it at four of the other five grades.

**Clock-counted limits — checked in simulation.** A handful of specifications
are given in `Clks` rather than nanoseconds: the arbitration handshake (35, 36,
37, 37A, 39, 46, 57, 57A, 58, 58A) and the HALT/RESET pulse width (56). Those
*are* properties of the state machine, and `sim/tb/bus_arb_tb.sv` measures them.

## The state ruler

Even-numbered states begin on a rising clock edge, odd-numbered ones on a
falling edge. This is not an assumption: UM 5.1.1 asserts AS "on the rising edge
of S2" and drives the address "entering S1", and the figure generator that
redrew figure 10-4 records `CLK_HI0 = 0.0` as the S0 rising edge with
`AS_ASSERT = 2.80` and `ADDR_VALID = 1.50` on the same scale.

| Edge | Event | UM | Spec |
|---|---|---|---|
| S0 rising | function code valid; R/W driven high | 5.1.1 state 0 | 6A, 18 |
| S1 falling | address valid | 5.1.1 state 1 | 6 |
| S2 rising | AS asserted; data strobes on a **read**; R/W low on a **write** | 5.1.1/5.1.2 state 2 | 9, 11, 20 |
| S3 falling | write data driven out of high impedance | 5.1.2 state 3 | 23 |
| S4 rising | data strobes on a **write** | 5.1.2 state 4 | 9 |
| S4 falling | DTACK, BERR, VPA, HALT sampled; wait states if none | 5.1.1 state 4 | 47 |
| S6 falling | read data latched; AS and data strobes negated | 5.1.1 state 7 | 12, 27, 29 |
| S7 rising | data bus released; R/W driven high | 5.1.2 state 7 | 7, 17 |

A wait state is a whole clock inserted between S4 and S5, so *n* wait states
make the cycle `8 + 2n` bus states long. Figure 5-3 draws a two-wait read as
`S0 S1 S2 S3 S4 w w w w S5 S6 S7`, and `sim/tb/bus_wait_rmw_tb.sv` sweeps zero
through four.

## Sampling

Two different paths, and conflating them would cost a clock in the wrong place.

**DTACK, BERR, VPA, HALT** are sampled directly by the falling-edge next-state
logic — one flop, no extra latency. Figure 10-4 places `DTACK_ASSERT` at 4.55 on
the state ruler and has S5 entered at 5.0, so an acknowledge that meets
specification 47 (10 ns setup at 8 MHz) before the falling edge ending S4 is
acted on at that very edge.

**BR, BGACK, RESET, IPL** go through `rd68011_sync`, the two-stage falling-edge
path of UM 5.3 figure 5-17: "sampled on the falling edge of the clock and valid
internally after the next falling edge." Combined with UM 5.3's rule that
arbitration outputs change on rising edges, this lands BR-asserted to
BG-asserted at 2.0 clocks — inside specification 35's 1.5–3.5 window, and by
construction never below its minimum.

## Termination — UM table 5-1

All six cases, `sim/tb/bus_error_tb.sv`. Cases 4 and 6 are the MC68010's late
bus error, "asserted within one clock cycle after the assertion of data transfer
acknowledge" (UM 5.4.1) — an MC68000 treats both as a normal termination, so
these are a genuine behavioural difference between the parts and not merely a
timing one. The late window is the falling edge ending S6, exactly one clock
after the falling edge ending S4 that recognised DTACK.

| Case | Signals | Result |
|---|---|---|
| 1 | DTACK | normal termination, cycle ends in S7 |
| 2 | DTACK + HALT | normal termination, then halted until HALT is negated |
| 3 | BERR, no DTACK | cycle runs on to **S9**, bus error reported |
| 4 | BERR one clock after DTACK | bus error reported, cycle still ends in S7 |
| 5 | BERR + HALT, no DTACK | buses released, cycle rerun when HALT is negated |
| 6 | BERR + HALT one clock after DTACK | as case 5 |

A retry is invisible to the sequencer: the bus unit reruns the cycle itself with
the same function code, address and data, and does not acknowledge the attempt
that failed (UM 5.4.2). A read-modify-write is never retried — UM 5.4.2's note
makes a bus error during one a bus error "whether or not HALT is asserted", so
that the write half can never be separated from the read half.

## Read-modify-write — UM 5.1.3

S0–S7 read, S8–S11 internal modification, S12–S19 write, with AS asserted from
S2 straight through to the falling edge entering S19. R/W goes low on the rising
edge of S14, data is driven in S15, the data strobes reassert on the rising edge
of S16. `sim/tb/bus_wait_rmw_tb.sv`.

A slave that keys DTACK off AS holds it asserted across the whole indivisible
cycle, so the write half takes no wait states even when the read half does —
which is precisely the shape figure 5-9 draws.

## M6800 cycles — appendix B

After VPA is recognised, VMA is asserted once E is low with **at least three
clocks left before it rises**; asserting later cannot meet specification 43
(VMA asserted to E high, ≥ 200 ns at 8 MHz = 1.6 clocks), so the cycle waits out
a whole E period instead. That is what makes the manual's "worst case" — VPA
recognised *two* clocks before E rises — worse than its "best case" three clocks
before, despite being later.

The cycle then ends with S7 on the falling edge at which E goes low.

`sim/tb/bus_m6800_tb.sv` sweeps the start of the cycle across a full E period
and gets a monotone staircase of 6, 7, 8, … 15 wait states. The two ends are the
manual's own drawings: **six wait states in figure B-4 (best case) and fifteen
in figure B-5 (worst case)**, which is as direct a confirmation of the
synchronisation rule as the source can give.

E itself is ten clock periods, six low then four high (UM 3.7), free-running and
generated in the falling-edge domain because specification 41 measures the
transition from CLK low. At 8 MHz that is 500 ns high and 750 ns low, against
specification 50's ≥ 450 ns and 51's ≥ 700 ns.

## Arbitration — UM 5.2, 5.3, figure 5-18

Measured by `sim/tb/bus_arb_tb.sv`, three-wire and two-wire:

| Spec | Limit | Measured |
|---|---|---|
| 35 | BR asserted → BG asserted, 1.5–3.5 clks | 2.0 |
| 36 | BR negated → BG negated, 1.5–3.5 clks | 2.0 |
| 37 | BGACK asserted → BG negated, 1.5–3.5 clks | 2.0 |
| 57 | BGACK negated → AS, DS, R/W driven, ≥ 1.5 clks | 2.0 |
| 57A | BGACK negated → FC, VMA driven, ≥ 1 clk | 2.0 |
| 58, 58A | the same two for the two-wire protocol | 2.0 |
| 39 | BG width negated, ≥ 1.5 clks | 2.0 |

The output enables are registered from the arbitration unit's **next** state, so
they change on the same rising edge as the state itself. Registering them from
the current state instead costs an extra clock at each end of the handover;
that would still satisfy 57 and 57A, which have no maximum, but it would not be
what the part does.

Figure 5-18 note 1 — the arbitration state machine does not advance while the
bus is in S0 or S1 — is implemented and delays BG by one rising edge in that
window (figure 5-21).

## Output enables — UM table 3-4

Table 3-4's two high-impedance columns give three distinct behaviours, which is
why `doc/pinout.md` defines seven enables rather than one.

| Enable | Released on |
|---|---|
| `a_oe`, `d_oe` | bus relinquish, RESET asserted, HALT, and retry (UM 5.4.2, 5.4.3) |
| `as_oe`, `rw_oe`, `ds_oe`, `vma_oe`, `fc_oe` | bus relinquish only |
| `reset_n_oe`, `halt_n_oe` | open drain — asserted only to pull low |

## Where the manual contradicts itself

**The address bus between cycles.** UM 5.1.1 state 7, 5.1.2 state 7, 5.1.3 state
19 and appendix B all say the processor "places the address bus in the
high-impedance state" as the clock rises at the end of the cycle. Table 3-4 says
the address bus goes high-impedance on RESET and on bus relinquish, and lists
nothing else; figure 5-3 draws the address as a continuously valid bus across
back-to-back cycles, changing value at S0/S1 rather than floating; and the
systems this part went into rely on the address staying driven.

This core follows table 3-4 by default. The `ADDR_HIZ_BETWEEN_CYCLES` parameter
on `rd68011_biu` selects the other reading for anyone who needs it. Both are
defensible; what is not defensible is picking one silently.

**Specification 7 versus 8.** The figure generator places both at 0.60 states
after the S0 rising edge, so figure 10-4 cannot distinguish "address goes
high-impedance" from "address becomes invalid". Under the default reading, spec
8 (address invalid) is what the address bus does between cycles and spec 7 is
what the *data* bus does at the end of a write.

`MC68000UM_split/README.md` documents fourteen further contradictions in the
source — spec 23's 550 ns, spec 47's three different values, the two rows
numbered 48, and the rest. Consult it before treating any single printed value
as authoritative.

## Divergences from the part

| | |
|---|---|
| **E's power-on phase.** UM 3.7: the ring counter "may come up in any state. (At power-on, it is impossible to guarantee phase relationship of E to CLK.)" Ours starts from a defined reset state. | Deliberate. Deterministic simulation is worth more than reproducing an indeterminacy, and no correct system can depend on the phase. |
| **`rst_n`.** Not an MC68010 pin. Every register needs a defined value without power-on initialisation, because ASIC is a target. | Additive: architectural reset is still RESET+HALT on the real pins. |
| **Nanosecond output delays.** None are modelled in the RTL. | Correct for an RTL model, and unchanged. What has changed is that the *budget* they imply is now analysed exactly and simulated at named corners — `doc/ac-timing.md`. |

## What clock rate this runs at

Bus *shape* is exact; bus *speed* is a synthesis result, and it is worth being
explicit about it because the half-clock is a real budget in this design rather
than a convention. One bus state is half a clock period, so anything that
starts at a falling-edge flop and ends at a rising-edge one has half a period
to get there -- which is where every hard path in the design lives.

Measured on the Artix-7 part, through place and route: **60 ns, which is
16.9 MHz**, against 12.5 MHz for the fastest MC68010 Motorola shipped. The
period moved as the design grew and then came back as the three things on the
critical path were dealt with -- `doc/implementation.md` is the full account,
including what it would cost to go further and why this is where it stops.

The critical path is written out in `scripts/rd68011.xdc`, at the constraint
itself, because that is where anyone changing the number will look.

## Not yet implemented

The bus unit is complete; the parts of §5 and §6 that belong to the sequencer
were finished in P4 and P6, and are listed here with where they landed:

- The reset *exception* — reading the initial SSP from $000000 and PC from
  $000004, setting the interrupt mask to 7 and clearing VBR (UM 5.5). Done in
  P4.
- Double bus fault detection. Done in P6: the sequencer tracks whether it is
  inside group 0 exception processing and drives `dbf` when a fault arrives
  while it is, which the bus unit turns into HALT out (UM 5.4.4). Only an
  external reset clears it.
- Interrupt recognition and priority. Done in P4.
- Breakpoint acknowledge cycles are wired as a cycle kind (`CT_BKPT`); BKPT
  issues one as of P5, with function codes all ones and zeros on every address
  line, as PRM section 4 specifies for this part.
