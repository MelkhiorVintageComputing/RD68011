# Making it smaller, and making it faster

The design filled 72 % of a MAX 10 and a fifth of an Artix-7 while using no memory at
all, because one combinational `case` statement was most of it. This document is what was
measured about that, and what the measurements led to.

```sh
make impl     # place and route, and the checkpoint make paths works from
make paths    # which families limit the clock, and by how much
make quartus  # the MAX 10 fit, and the frequency that is quoted
make audit    # every register's reset, and the one exception
```

Every number here was taken with those. Where a figure is quoted for both parts they come
from the same tree; `doc/implementation.md` explains why that matters and what it cost to
learn.

## What it came to

| | before | after | |
|---|--:|--:|---|
| Artix Slice LUTs | 13,121 (20.7 %) | **6,585 (10.4 %)** | −50 % |
| Artix block RAM | 0 | 7.5 of 135 | |
| Artix setup slack at 48 ns | 1.375 to 2.077 | 2.048 | |
| MAX 10 logic elements | 36,074 (**72 %**) | **13,749 (28 %)** | −62 % |
| MAX 10 M9K blocks | 0 of 182 | 30 (16 %) | |
| **MAX 10 Fmax** | 19.82 MHz | **19.98 MHz** | |
| instruction cycle counts | — | unchanged | every one of them |

Six candidates were measured and four were kept:

| candidate | kept | what it was worth |
|---|:--:|---|
| the store read a microword early, as a memory | yes | −52 % Artix LUTs, −66 % MAX 10 logic; −5 % Fmax |
| two levels for the microword | yes | 3.91x fewer stored bits; 146 M9Ks become 30 |
| one shifter barrel instead of four | yes | −245 Artix LUTs, −600 MAX 10 logic, +0.13 MHz |
| the address register out of the ALU's reach | yes | **+0.82 ns**, and the worst family becomes the third |
| the shifter's two remainders | no | +11 MAX 10 logic, and Fmax below the gate's floor |
| the decoder's forty previews indexed | no | the decoder got *bigger*, 1297 LUTs to 1321 |
| the address-error check moved to the bus unit | no | 0.175 ns, and visible on the pins |

Two hypotheses were refuted along the way and both are written up where they were made: that
taking two thirds of the logic out of a congested part would buy frequency, and that the
M9K count was why it did not.

## Where the area was, and where the time was

Post-route on `xc7a100tcsg324-1` and fitted on `10M50DAF484C7G`, both at the 48 ns
constraint, before any of this:

| module | MAX 10 LEs | Artix LUTs | |
|---|--:|--:|---|
| **`u_urom`** | **23,604** | **6,665** | the microcode store |
| `u_seq` itself | 6,481 | 3,676 | source multiplexers, address unit, register file |
| `u_decode` | 2,876 | 1,081 | 1401 opcode patterns |
| `u_shifter` | 1,757 | 814 | |
| `u_alu` | 833 | 502 | |
| `u_biu` | 314 | 137 | |
| `u_divider` | 196 | 223 | |
| `u_mul`, `u_loop_rom` | 50 | — | plus 3 DSP / 4 nine-bit multipliers |
| total | **36,074 (72 %)** | **13,121 (20.7 %)** | 1391 / 1342 registers |

and **0 of 182 M9Ks, 0 of 135 block RAMs, 0 memory bits** on either part.

The time is one path, the same under both tools -- read data latched on the falling edge
of S6, through the source multiplexers and the shifter, into `ir_nxt`, the address-register
select, the register file, the address unit, the address-error check, `req_valid`, and the
bus unit's `start_new`. Half a period, 24-28 logic levels on Artix and 36 on MAX 10, and
**76.8-79.5 % of the delay is routing rather than gates**. `doc/critical-path.md` is the
full account.

**One sentence governs everything below.** `make paths` groups the endpoints into families,
and the second-worst is 0.49 ns behind the worst:

| slack | ends | family |
|--:|--:|---|
| 2.077 | 34 | `a-mux -> shifter -> req_valid -> start_new` |
| 2.315 | 3 | the same, ending at `req_valid` |
| **2.566** | **59** | **`a-mux -> shifter`, into the sequencer's own registers** |
| 3.806 | 272 | `shifter` |

So no single change to the address path is a frequency change: perfect success on every
one of them moves the worst slack to 2.566, which is +0.49 ns, and two runs of the same
design have come out 1.3 ns apart. What is left after that is the shifter, and what is left
after the shifter is congestion -- which is why the store, which is on no critical path at
all, is the first thing here.

## Can the store be a memory at all?

Everything else depended on this, so it was answered before anything was built. The store
is 6674 microwords of 146 bits held in a combinational `case`, and there is exactly one
other way to write it: an array. An array has to be filled by an `initial` block or
`$readmemh`, which CLAUDE.md bars and `tools/reset_audit.py` checks for. So the question
was whether both tools would infer a memory from a `case` inside an `always_ff`.

| what was tried | Vivado | Quartus, MAX 10 |
|---|---|---|
| registered `case`, no attributes | **32 RAMB36E1, 0 LUTs** | 23,696 LEs, 0 memory bits |
| ... with `rom_style` / `ramstyle` | same | `rom_style` unrecognised; no effect |
| ... with `romstyle = "M9K"` | — | recognised; no effect |
| `ALLOW_ANY_ROM_SIZE_FOR_RECOGNITION` | — | no effect |
| a `localparam` constant array | — | 23,694 LEs, 0 memory bits |
| an array filled by `initial` | — | 23,696 LEs, 0 memory bits |
| a textbook 1024x32 ROM | — | 1,490 LEs, 0 memory bits |
| a 1024x32 **RAM** | — | 0 LEs, 32,768 memory bits |
| the same ROM on Cyclone V | — | 0 ALMs |

The last three rows are what found it. Quartus was not refusing the coding style -- it
refuses *initialised* memory on MAX 10, and only on MAX 10, because the part loads its
embedded RAM from the configuration flash and will only do so when the image is built to
carry the contents. One assignment fixes it:

```tcl
set_global_assignment -name INTERNAL_FLASH_UPDATE_MODE "SINGLE COMP IMAGE WITH ERAM"
```

With that in `scripts/quartus.tcl`, the same source that gave 23,696 logic elements and
zero memory bits gives **62 logic elements and 1,196,032 memory bits**. Nothing about the
RTL changed between those two runs.

This is worth stating plainly because of how it fails: there is no warning. A declined
inference reads as "the change did nothing", and the first four rows of that table are all
the same wrong answer for the wrong reason.

**No synthesis attribute is used, and that is deliberate.** Neither tool needs one, and
without one the RTL asks for a table rather than for a memory: an ASIC flow synthesises
the same `case` as logic, with no memory macro and nothing to initialise. On that target
the register is the only addition, and it is an improvement -- the table used to sit
combinationally between `upc` and the datapath and now ends in a register, so it shares a
clock with the `upc_nxt` multiplexer instead of standing in front of the datapath.

## The store, read a microword early

`upc <= upc_nxt` is unconditional outside reset, so `ROM[upc]` this clock is
`ROM[upc_nxt]` of the last one. A memory addressed by `upc_nxt` whose read is registered
therefore holds exactly the same word at exactly the same time, and costs no clock. That is
the whole argument, and `sim/tb/core_timing_tb.sv` is what confirms it: it fails if any of
its ~40 instruction timings moves in either direction, and none did.

One thing about it is not bookkeeping. `rd68011_sync`'s `RESET_VAL` is 1, so `reset_sync_n`
is inactive-*high* while `rst_n` is asserted, and `upc_nxt`'s existing first arm does not
select the reset entry during reset. Left alone the store would be addressed by a word it
had not loaded yet, and the X feeds back through `retire` and `f_seq` and never clears --
a lock-up, not a cosmetic X. The arm now tests `rst_n` as well.

`sim/tb/harte_tb.sv` needed the matching change and would not have said so: it pokes
`dut.u_seq.upc` between edges to start a vector, and with the word registered the previous
vector's microword stayed current for a clock -- and it can issue a bus cycle. It now
instantiates a second store, addressed at the entry point, exactly as it already
instantiates a second decoder, and copies the word across.

### Watched to fail

| control | result |
|---|---|
| read at `upc` rather than `upc_nxt` | **257 failures** across every core testbench |
| one microword's destination field flipped | 2 of 60 MOVE.b vectors fail |
| the audit's exemption pointed at another module | reports the store's 80 registers |
| an observable resetless flop added to the bus unit | reports it: 81 total, 80 exempt |

The first is the one that matters: it is the difference between the early read and the
plain one, and it is the whole reason the change costs no clock.

## The one register without a reset

CLAUDE.md's rule is that every register takes its value from the reset branch of its
`always_ff`, and `make audit` proves it. The store's output register cannot: a block
memory's read register is inside the primitive, and requiring a reset on it is requiring
the store to be logic.

The rule exists to prevent a design that depends on power-on state, and this one does not.
The store is addressed by `upc_nxt`, which is forced to `ENTRY_RESET` whenever `rst_n` or
`reset_sync_n` is asserted, so one clock edge during reset leaves the register holding
`ROM[ENTRY_RESET]` -- the same microword `upc`'s own reset branch selects. Its value is
determined by reset, by a different mechanism from every other register in the design. The
obligation that creates is one clock edge while reset is asserted; `core_reset` gives four
and `harte_tb` gives one, and the MC68010 requires four.

The exemption is enforced rather than allowed: no resetless register may exist outside that
one module, and both halves of that were watched to fail.

Getting there took two false starts worth recording, because both look like they should
work. `flatten` hands the flops to yosys's `ff` pass, which renames them to
`$auto$ff.cc:266:slice$41200` and drops the `src` attribute, so after flattening neither the
instance name nor the source file survives to select on -- `n:*u_urom*`, `c:*u_urom*` and
`a:src=*rd68011_ucode_rom*` all match nothing. A hierarchical `stat -top` keeps the
attribution, multiplies instance counts into the design total itself, and runs faster.

That changes one published number: the audit counts **1385** registers outside the store
where it used to count 1381, because it no longer flattens and four registers that
cross-module optimisation had removed now survive. The store adds 127 more, of which yosys
gives 47 a synchronous reset of their own accord and 80 none.

## What the store cost, and what it bought

| | before | after | |
|---|--:|--:|---|
| Artix Slice LUTs | 13,121 (20.7 %) | **6,275 (9.9 %)** | −52 % |
| Artix Slice registers | 1342 | 1344 | |
| Artix F7 / F8 muxes | 1490 / 225 | 378 / 64 | the store was what used them |
| Artix block RAM | 0 | 32 of 135 (23.7 %) | |
| Artix setup slack at 48 ns | 1.375 to 2.077 | 2.428 | |
| Artix hold | 0.144 | 0.124 | |
| MAX 10 logic elements | 36,074 (72 %) | **12,306 (25 %)** | −66 % |
| MAX 10 registers | 1391 | 1393 | |
| MAX 10 M9K blocks | 0 of 182 | 146 of 182 (80 %) | |
| MAX 10 memory bits | 0 | 1,196,032 (71 %) | 8192 x 146 |
| **MAX 10 Fmax** | **19.82 MHz** | **18.81 MHz** | **−5.1 %** |

Per module on the Artix, `u_urom` goes from 6665 LUTs to none; `u_seq` itself 3676 to 3519,
`u_decode` 1081 to 1076, `u_shifter` 814 to 812, `u_alu` 502 to 498, `u_biu` 137 to 126 --
which is to say nothing else moved, as nothing else should have.

**The area result is unambiguous and the frequency result is not.** On the Artix the change
is worth nothing measurable: 2.428 ns against a baseline of 1.375 and 2.077 ns is inside the
1.3 ns spread two runs of the same design have already shown, and `doc/implementation.md`
predicted exactly this -- the store is on no critical path, so taking it out of the logic
could not shorten one.

On the MAX 10 it is worth **minus five per cent**, and that was not predicted. The
hypothesis going in was that a design three quarters routing at 72 % occupancy is congestion
limited, so removing two thirds of the logic should buy frequency. It did not. The worst
path is the same one it was -- `req_rdata` to `cyc_addr`, 35 logic levels where it was 36 --
so the critical path did not change; what changed is that 146 M9Ks at 80 % occupancy are a
placement constraint in their own right. The microword now arrives from a hundred and forty
six blocks spread across the die, and that costs more than the congestion it relieved.

That refutes the hypothesis rather than qualifying it, and it makes the microword's encoding
the next thing to measure rather than an optional refinement: the same store re-encoded
would ask for about thirty M9Ks instead of a hundred and forty six.

## Two levels for the microword

6674 microwords of 146 bits is 974,404 bits and almost none of it is distinct. The
successor address is -- 6313 of the 8192 addresses name a different one -- but the 91
control bits take **600** distinct values across the whole microprogram, and the two request
previews, taken as the pair they always travel as, take **126**.

So the store holds an address and two indices, 30 bits, and two small tables hold the
patterns:

```
  8192 x  30   the store
   600 x  91   control patterns
   126 x  42   preview pairs
  ----------
  305,652 bits, against 1,196,032 -- 3.91x
```

`tools/ucode/assemble.py`'s `check_two_level` rebuilds all 8192 words from the tables and
insists each one is unchanged, on every generation, in the same way `check_disjoint` does
for the decoder. Perturbing one table entry fails the build:
`microword 6 rebuilds as ...02007, not ...00007`.

**The second level cannot be registered, and is not meant to be.** Its index only exists
after the store's own register, and making the store combinational is what would stop it
being a memory. It is combinational logic in front of the microword's consumers, and that
is the cost being measured. It is also strictly shallower than what it replaces: a 600-entry
lookup at a 10-bit address instead of an 8192-entry one at 13 bits.

| | flat store | two levels | |
|---|--:|--:|---|
| Artix Slice LUTs | 6,275 | 6,864 | +589, the two tables |
| Artix block RAM | 32 of 135 | 8 | |
| Artix setup slack | 2.428 | 1.524 | both inside the 1.3 ns spread |
| MAX 10 logic elements | 12,306 (25 %) | 14,348 (29 %) | +2,042 |
| MAX 10 M9K blocks | 146 (80 %) | **30 (16 %)** | |
| MAX 10 memory bits | 1,196,032 | 245,760 | |
| MAX 10 Fmax | 18.81 | 18.70 | |

On the Artix, `u_urom` is 589 LUTs and 8 block RAMs where it was 0 and 32; of those 589,
533 are the control table and 56 the previews.

### The second hypothesis, also refuted

The 5 % the MAX 10 lost when the store became a memory was blamed on 146 M9Ks at 80 %
occupancy being a placement constraint of their own. **It was not.** Thirty blocks lose the
same as a hundred and forty six -- 18.70 against 18.81, which is nothing -- and the worst
path's logic levels have been falling the whole time, 36 to 35 to 33, while the frequency
fell with them.

What is left as an explanation is the shape rather than the count: the microword used to
come out of twenty-three thousand logic elements that the placer could scatter beside each
of its consumers, and now all 146 bits radiate from fixed memory columns. That is inherent
to putting a wide store in hard memory blocks and does not depend on how many of them there
are.

### Why it is kept anyway

On both FPGAs this is a trade rather than a win, and on the Artix it is a small loss: 589
LUTs for 24 block RAMs the part was not short of. It is kept for the two places it pays.

On the MAX 10 it returns **84 % of the part's memory** to whatever else shares the chip.
A core that leaves four M9Ks free is a core that has to be the whole design; one that leaves
a hundred and fifty two is not, and four points of logic element is a cheap price for that.

On an ASIC there is no block memory to infer and the store is logic either way -- which is
the right answer there, since a synthesised table is far cheaper than an initialised SRAM
macro. There the 3.91x is 3.91x of the thing you actually pay for. Measured separately
during the inference spike: the 30-bit store alone is 5,493 logic elements on the MAX 10
against 23,694 for the flat 146-bit one, so with the two tables' 2,042 the whole store in
logic is about a third of what it was.

## The shifter: one barrel instead of four

`rd68011_shifter.sv` evaluated five wide shifters unconditionally -- three 64-bit ones for
the plain shifts, a fourth for rotates, and a 72-bit one for rotate-through-X -- and threw
most of the bits away. Four of the five are right shifts differing only in what goes in and
by how much, so a multiplexer in front of one barrel replaces four barrels.

Standalone, out of context, on the Artix:

| | LUTs |
|---|--:|
| as it was | 995 |
| with the rotate and extend barrels deleted (a bound, not a candidate) | 534 |
| one shared barrel, functionally wrong (a structural probe) | 542 |
| **one shared barrel, correct** | **694** |

The bound and the probe agreeing at ~540 is what said the input multiplexers would be
nearly free, and they are: the correct version costs 152 LUTs more than the probe because
the plain shifts need their own alignment, and still saves 301.

The layout is the only subtle part. The plain shifts sit at bits 39:8 of the 72-bit input
with 32 fill bits above and eight below, so `out[39:8]` is the result and `out[7]` is the
bit that fell off the end -- the carry. Filling with the sign is what makes an arithmetic
shift arithmetic, so the separate `>>>` is gone. The amount saturates at 32 because the
operand is never wider, and exactly one carry then needs saying explicitly: past 32 places
a 32-bit operand has gone entirely, and a barrel told to stop at 32 still reports the bit
that left there. Narrower operands need no such correction, because `v` is zero-extended
and `vs` sign-extended and the bit the barrel finds is already the right one.

That is the kind of reasoning that should not be trusted, so it is not. `make harte-all` is
not exhaustive over `count`, so the old and new modules were put through a yosys `miter
-equiv` and `sat -verify -prove-asserts` over all 44 input bits: **proved equivalent**. A
deliberately wrong reduction fails the same proof.

| | two-level store | shared barrel | |
|---|--:|--:|---|
| Artix Slice LUTs | 6,864 | **6,619** | −245 |
| Artix `u_shifter` | 812 | **591** | −27 % |
| Artix setup slack | 1.524 | 1.227 | inside the spread |
| MAX 10 logic elements | 14,348 (29 %) | **13,748 (28 %)** | −600 |
| MAX 10 Fmax | 18.70 | **18.83** | |

It also changes the shape of the path report. `a-mux` has left the top of the family table
altogether -- the source multiplexers were only there because they fed four barrels -- and
what is left is three shifter families inside 0.54 ns:

| slack | behind | ends | family |
|--:|--:|--:|---|
| 1.227 | — | 30 | `shifter -> req_valid -> start_new` |
| 1.498 | +0.271 | 60 | `shifter` |
| 1.764 | +0.537 | 7 | `shifter -> req_valid` |
| 4.228 | +3.001 | 8 | `alu -> alu_y -> ucode-rom` |

## Two candidates that measured worse

Both were proposed on the same premise, and the premise was wrong both times: that
synthesis was leaving redundancy on the table. It was not.

**The shifter's two remainders.** `count % w` with `w` a signal that is only ever 8, 16 or
32 looks like a divider on a combinational path, and `count % (w + 1)` -- modulo 9, 17 or
33 -- looks worse. Replacing the first with a mask and the second with a halving reduction
is provably equivalent and, standalone, saves 34 LUTs of 995. In the design it is worth
−24 Artix LUTs and **+11 MAX 10 logic elements**, and it took the MAX 10 to **18.48 MHz,
below the 18.50 floor `make quartus` gates on**. Both tools were already specialising the
remainder from the three-way case that produces `w`. Not kept.

**The decoder's forty previews.** The 21-bit request preview takes only 40 distinct values
across 1440 opcode patterns, so carrying a 6-bit index and expanding it in a second table
should have narrowed every arm from 35 bits to 20. Standalone on the Artix the decoder went
from 1297 LUTs to **1321** -- it got bigger. Vivado was already sharing those 40 values
across the arms, so the index bought nothing and cost a table. Not kept.

The general lesson, and it is why the standalone screen became the protocol: a table's
redundancy is something synthesis finds on its own. Sharing a *barrel* is not, because that
is physical hardware rather than a pattern in constants -- which is why the one shifter
change that worked is the one that removed hardware rather than restating constants.

## The address register the next microword uses

`ir_nxt` is the opcode the prefetch pipe will hold after this edge, and one arm of it is
RTE reloading `ir` out of a format $8 frame -- `y[15:0]`, straight from the ALU. The next
microword's address register is selected from a field of that opcode, so read data went
through the datapath into a register *number*, into a 16:1 register-file read, into the
address unit, and into `req_valid`, all in half a clock.

Exactly **one** microword in 6674 writes `ir` from the ALU: 5079, in RTE. Its successor
5080 has `aeasel=SP`, so it addresses through A7 -- a constant -- and does not read the
opcode at all. So `n_ea_reg` can read an `ir_pipe_nxt` that carries the pipe's own value
and not that write, and the ALU and shifter leave the address unit's fan-in entirely.

### Bounded first, built second

Both address-path candidates were bounded with throwaway builds before either was written,
because the family table said they could not be worth much:

| | worst slack | |
|---|--:|---|
| as committed | 1.227 | |
| both hacked out (functionally wrong) | 2.624 | +1.397 |
| only `ir_nxt` hacked out | 2.449 | +1.222 |
| **the real `ir_nxt` split** | **2.048** | **+0.821** |

So the address-error check is worth **0.175 ns**, which is inside the router's own spread,
and it is not built -- see below. The `ir_nxt` split is worth most of the rest, and the
family table shows the structural change rather than just the number:

| slack | behind | ends | family |
|--:|--:|--:|---|
| 2.048 | — | 59 | `shifter` |
| 2.408 | +0.360 | 7 | `shifter -> req_valid` |
| **2.551** | **+0.503** | **30** | **`shifter -> req_valid -> start_new`** |
| 4.521 | +2.473 | 8 | `alu -> alu_y -> ucode-rom` |

That family was the worst in the design through every measurement in this document and
every one in `doc/critical-path.md`. It is now third, half a nanosecond behind, and what
limits the clock is the shifter's own delay.

### The invariant, said where it can be checked

Synthesis cannot know that the microword writing `ir` from the ALU is never one whose
successor addresses through a register field, so `tools/ucode/assemble.py`'s `check_ir_dst`
says it and fails the build if the microprogram stops being true -- the same enforcement,
for the same kind of reason, as the bus-steering conditions in `doc/critical-path.md`.
`make ucode` now prints `microwords that write ir from the ALU: 5079`. Both clauses were
watched to fail: a successor given `aeasel=DST` is rejected, and so is a `dst=IR` microword
that enters loop mode, since the loop ROM is read at `ir_pipe_nxt` too.

| | before | after |
|---|--:|--:|
| Artix Slice LUTs | 6,619 | 6,585 |
| Artix setup slack | 1.227 | **2.048** |
| MAX 10 logic elements | 13,748 | 13,749 |
| MAX 10 Fmax | 18.83 | **19.98 MHz** |

## The address error, and what moving it would cost

`doc/critical-path.md` listed the address-error check between `n_addr` and `req_valid` as
the one thing on the critical path that had never been looked at. It has been looked at
now, and it is **worth 0.175 ns** -- the difference between the two throwaway bounds above,
which is a fifth of the router's run-to-run spread.

It would also not be free. The check has to *prevent* the cycle, and recomputing it inside
the bus unit still gates `start_new` -- the same cone in the same clock, for nothing. A
gain needs the cycle to start and be killed a state later, and that is visible on the pins:
`fc_o` takes the new function code on entering S0, before the address and AS ever assert.
Bus behaviour is a hard requirement of this project rather than a soft one, so a
tenth-of-a-nanosecond path change is not a reason to make a cycle that does not happen
observable. Not built.

## How fast it actually goes

48 ns is the constraint every figure in this project is measured against, and it stays
that way so the numbers remain comparable. It is not the limit. Searching for the closing
period, one run each:

| period | setup slack | |
|--:|--:|---|
| 48 ns | 2.048 ns | 20.8 MHz, the constraint in `scripts/rd68011.xdc` |
| 44 ns | 1.394 ns | 22.7 MHz |
| 42 ns | 0.880 ns | 23.8 MHz |
| **40 ns** | **0.864 ns** | **25.0 MHz** |
| 38 ns | 0.292 ns | 26.3 MHz, but inside the router's own spread |
| 36 ns | **−0.543 ns** | does not close |

Read that as *the design closes at 40 ns*, which is the last row with more than the
1.3 ns of run-to-run variation this project has already measured between it and failure.
Before this work it closed at 48 and once, marginally, at 46.

## A defect this study introduced, and how it was found

The shared shifter barrel read `dd`, `rsh_amt`, `xdd` and `xsh_amt` above the lines that
declare them. Vivado reports that as `[Synth 8-6901]`, an **info**; every gate in this
project passed with it present -- lint under three tools, 14 testbenches, 124 opcode files,
93,991 co-simulated instructions, both place-and-route flows. Other tools invent an
implicit one-bit net instead, which is silently the wrong netlist.

`scripts/synth.tcl` and `scripts/impl.tcl` now promote that message to an error, and the
whole RTL is clean under it. Questa rejects the same construct natively, which is what
`make lint-questa` is for and why `doc/coding-standard.md` gained a row.

The general point is the one this document keeps arriving at: a diagnostic nobody has
watched fail is not a gate. This one was not even a diagnostic until it was promoted.

## A second defect, found by unrelated work

This study left the microcode store with no synthesis attribute on purpose, and
`tools/ucode/assemble.py` said why: a registered `case` infers a block memory under both
tools without one, and asking for nothing keeps an ASIC flow synthesising the same case as
logic. Both halves were true and the conclusion was still wrong.

Building the core with the loop buffer's parameter at 16 words -- a change with no
connection to the store at all -- was enough for Vivado to put the store back in logic:
**1900 extra LUTs**, and its own report still said `Block RAM`. The mapping in that report
is preliminary, as the note under the companion DSP table says in as many words, and
`Timing Optimization` runs afterwards and may reverse it. Nothing is printed when it does.

| `LOOP_BUF_WORDS` | | Slice LUTs | block RAM |
|--:|---|--:|--:|
| 16 | inference left to the tool | 8907 | **0** |
| 16 | `(* rom_style = "block" *)` | 7015 | 7.5 |

So the store now carries `rom_style` for Vivado and `ramstyle` for Quartus, which warns
about the other one and is recorded in `doc/coding-standard.md` doing so. Neither is
understood by an ASIC flow, so the reason the attributes were left off still holds; what
does not hold is the idea that a tool's default is a decision the design has made.

It is the same lesson as the one above, arrived at from the other side: there, a diagnostic
nobody had watched fail; here, an inference nobody had watched decline.

## What is left

- **The loop buffer's hit test is the floor when the buffer is on.** At 16 words and
  above the worst path ends at `lb_hit`/`lb_hit2`: read data, through the datapath, into
  `pc_nxt`, and then a 23-bit subtract against the window base. 21.72 MHz becomes 21.13.
  The subtract only needs `pc_nxt` for the one case that is already forced to miss -- the
  microword loading the program counter -- so computing it from `pc` plus the prefetch
  increment instead, and marking that one microword invalid, takes the ALU out of it
  entirely. Not done: the default core does not have the path at all, and a board that
  turns the buffer on is trading 2.7 % of the clock for thirty per cent of the clocks.
- **The shifter is the floor now.** Three shifter families sit inside 0.5 ns of each other
  and `alu -> alu_y` is 2.5 ns behind. The barrel is shared and the operand widths are
  already trimmed by both tools, so what remains is the barrel's own depth.
- **Frequency is not where the logic is.** Four rounds of this work moved the Artix from
  13,121 LUTs to 6,585 and the MAX 10 from 72 % of the part to 28 %, and the clock moved
  from 48 ns to 40. Those are not proportional and were never going to be: the two
  candidates that shortened a path bought the frequency, and the two that removed logic
  bought the area.
- **Both refuted hypotheses were about congestion.** Removing two thirds of the logic on a
  part that was 72 % full did not buy frequency, and neither did returning 116 of its 146
  memory blocks. On this design, at these occupancies, area and frequency are close to
  independent -- which is worth knowing before anyone spends a week shrinking something to
  make it faster.
- **`u_decode` is now the largest single block on the Artix** at 1076 LUTs of 6585, and
  indexing its previews made it bigger. Whatever helps it is not the redundancy in its
  table, because synthesis already has that.
