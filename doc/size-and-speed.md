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
