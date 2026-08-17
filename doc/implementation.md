# Implementation readiness

What the design costs and how fast it goes, measured rather than estimated, on
a named part with a real place and route.

```sh
make lint     # elaborate under iverilog, Verilator and yosys
make audit    # prove no register initialises outside reset
make synth    # Vivado synthesis, and the estimate that comes with it
make impl     # place and route, and the number that means something
make paths    # what limits the frequency, with the unreachable routes excluded
```

## The numbers

Post-route, `xc7a100tcsg324-1`, out of context, one clock constraint of 48 ns
with a 50 % duty cycle:

| | |
|---|--:|
| Clock period | **48.0 ns**, which is **20.8 MHz** |
| Setup slack | 2.077 ns |
| Hold slack | 0.168 ns |
| Slice LUTs | 13011 (20.5 % of the part) |
| Slice registers | 1304 (1.0 %) |
| F7 / F8 muxes | 1503 / 206 |
| DSP48E1 | 3 |
| Block RAM | 0 |

46 ns also closed, at 0.277 ns. That is inside the run-to-run variation
described below, so it is not the number to quote; 48 ns is where it closes
with margin.

For scale: the fastest MC68010 Motorola shipped ran at 12.5 MHz, and the part
this is modelled on was usually clocked at 8 or 10.

`make synth` reports a different, more optimistic slack, because before
placement the router's contribution is a guess — and most of this design's
critical path is routing. The number above is the one to quote.

**Do not convert that slack into a frequency by dividing.** Every critical path
here launches on one clock edge and captures on the next, so its budget is half
the period and both halves shrink together; the shortest period the design can
take is `48 - 2 x slack`, not `48 - slack`. `scripts/impl.tcl` prints the
second form, which is right for a rising-to-rising path and is what it has for
the general case. Where a frequency is quoted below it is measured, by editing
`clk_period_ns` in `scripts/rd68011.xdc` and running place and route again.

## Why the clock is what it is

Half a clock, not a whole one, because the paths that bind start at one edge
and end at the next. That much is the bus protocol and not a choice: figure 5-3
lets a cycle begin on the rising edge immediately after the falling edge that
ended the previous one, so the request for the next cycle must be ready by then.

What is on that half clock has been measured rather than read off the timing
report, because for most of this design's life the worst path the report showed
was one the microcode could not take. **`doc/critical-path.md` is that work**:
what `make paths` does, what it found, and the four changes that came out of it.
The summary is:

| | worst slack, all at 60 ns |
|---|--:|
| P8, as measured | 0.289 ns |
| ... with the unreachable route excluded | 1.464 ns |
| decode the next opcode without waiting for the bus cycle | 0.534 ns |
| previews carried in the microword, `rd68011_ureq_rom` deleted | 1.953 ns |
| steer the request on MOVEM's mask alone | 1.509 ns |
| give the write data the three half clocks it actually has | **3.027 ns** |

and the constraint then moved from 60 ns to 48.

The route that used to be reported as worst -- read data, through the ALU, to a
flag, to the micro-branch, to the store, to the bus request -- was worth
**1.175 ns** of the thirty. It is now absent rather than excluded: the request is
selected on the mask test, so the ALU is not in its fan-in, and the exclusion
`make paths` applies finds nothing left to cut.

What limits it now is real and is required by the cycle counts:

```
  read data                      latched on the falling edge of S6
    -> the A and B source multiplexers
    -> the ALU, or the shifter, whichever the microword selects
    -> t0_nxt / pc_nxt
    -> the next bus address, and the address-error check on it
    -> the bus request, latched on the rising edge that ends S7
```

Absolute-long addressing reads the low half of an address and concatenates it
into T0 through the ALU, and the next microword issues at `asel=T0`; branch
targets do the same through the PC. Read data through the datapath into the next
bus address in half a period is what having no wasted clock between the two
means. At 60 ns the ALU is the worse of the two arms and at 48 ns the shifter
is; they are the same path.

## Two cautions about these numbers

**Two different LUT counts, both correct.** `scripts/impl.tcl` prints the number
of LUT *primitives* (14522); the utilisation report says *Slice LUTs* (13011),
which counts occupied LUT sites. They differ by more than 10 %, and comparing
one against the other looks exactly like a regression. It is not one. The table
above quotes the report.

**Place and route varies more than small changes do.** Adding `term_berr_late` --
one flip-flop, the fix in `doc/divergences.md` -- costs +6 LUTs and +1 register
at synthesis, with worst slack identical to the nanosecond. Through place and
route the same change reads as +71 Slice LUTs, +78 registers and 0.576 ns less
slack, because the router took a different trajectory and replicated 78 flops
along the way. Measured by checking out the earlier commit into a worktree and
running the same script, which is the only way to compare these honestly.

So a difference under about 0.6 ns is a statement about the router, not about
the design. Two rows of the table in "Why the clock is what it is" differ by
less than that and should not be read as a regression. Anyone chasing a few
hundred picoseconds should re-run the baseline rather than trust a number in a
document.

**What the previews cost.** Deleting `rd68011_ureq_rom` and widening the
microword from 103 bits to 145 is **+342 Slice LUTs, +2.7 %** -- and 77 *fewer*
registers, because the router had less reason to replicate. The 8192-entry
21-bit store it replaced was worth more than the 42 bits added.

### What is left, and what it would cost

- **The floor is the address path.** Read data through the datapath into the
  next bus address is required by absolute-long addressing and by branch
  targets, and
  shortening it means changing what those instructions cost. The one thing on it
  that is not obviously necessary is the address-error check standing between
  `n_addr` and `req_valid`; whether the bus unit could make that check itself, a
  state later, has not been looked at.
- **It is a routing problem more than a depth one.** 72 % of the delay was
  routing when it was last broken down. That ratio is worth knowing before
  anyone restructures logic to fix a placement problem.
- **Registering the bus request** would present it a cycle earlier, which means
  knowing the next microword a cycle earlier, which a conditional branch cannot
  do. It would cost a cycle on every bus access and break the exact cycle counts
  that `sim/tb/core_timing_tb.sv` checks and `doc/timing-divergences.md`
  accounts for. It is not worth it and it is not necessary.

The microcode store as a block RAM was considered and remains an area trade
rather than a speed one. The store's *second* read -- the one that was on the
critical path -- no longer exists; what is left is the read at `upc`, whose
address is already a register, so a block RAM with a registered output would
hold exactly the same value at the same time. That would move a large part of
the LUTs into the 135 block RAMs the part has, and buy no frequency. It would
also need the reset rule bent, because a block RAM output register has only a
synchronous reset.

## The reset audit

ASIC is a target, so there is no power-on register state: every register takes
its value from the reset branch of its `always_ff`. `make audit` proves it two
ways, because either alone would miss something.

**Source.** No `initial` block, no `always_latch`, and no initialiser on a
declaration that could infer a register, anywhere under `rtl/`.

**Netlist.** yosys synthesises the whole design to gate-level flops and the
cell types are read back. A flop without a reset is a different cell there —
`$_DFF_P_` rather than `$_DFF_PN0_` — so one that got past the source check by
some route nobody thought of still shows up. As of P8:

```
reset audit: 15 files, no initial blocks, no latches, no declaration initialisers
reset audit: 2684 flip-flops in the netlist, every one of them with a reset
    $_DFFE_NN0N_        46      $_DFF_NN0_          58
    $_DFFE_NN0P_        74      $_DFF_NN1_          30
    $_DFFE_NN1P_         2      $_DFF_PN0_        1168
    $_DFFE_PN0N_       166      $_DFF_PN1_           6
    $_DFFE_PN0P_      1122
    $_DFFE_PN1P_        12
```

Every one of those cell names carries a reset polarity and a reset value.
yosys counts more flops than Vivado does because it flattens without merging;
the count is not the point, the absence of a resetless type is.

The negative-edge flops in that list are the bus interface's output stage,
which is negedge-clocked on purpose — one bus state is half a clock period, and
`doc/bus-timing-compliance.md` explains why.

## Four tools, one subset

`make lint` elaborates every module under iverilog 12.0, Verilator 5.032 and
yosys 0.52; `make synth` adds Vivado 2025.2. The intersection of what those
four accept is the language this project is written in, and
`doc/coding-standard.md` is the record of where the edges are — every entry in
it was found by trying it here.

yosys is the strictest and therefore the one that defines the subset. The lint
target runs a full `synth`, not just `read_verilog`, so anything
unsynthesisable is caught there rather than half an hour later in Vivado.

## What is not covered

- **Nanosecond pad timing.** The AC specifications in
  `Inputs/doc/.../ac-electrical-specifications.csv` are limits on a real
  package's pins. An RTL model has no analogue delays; what is checked instead
  is the placement of every edge within the bus-state ruler, which is the part
  that belongs to the design. `doc/bus-timing-compliance.md` has that.
- **A board.** This is synthesised out of context: no I/O buffers, no pin
  constraints, no board clock. `doc/pinout.md` describes the wrapper a real
  design would put around it.
- **ASIC.** Nothing here has been through an ASIC flow. What has been done is
  the thing that makes one possible: no initialisation outside reset, no
  vendor primitives, no inferred memories that only an FPGA has.
