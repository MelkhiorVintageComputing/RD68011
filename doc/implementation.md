# Implementation readiness

What the design costs and how fast it goes, measured rather than estimated, on
a named part with a real place and route.

```sh
make lint     # elaborate under iverilog, Verilator and yosys
make audit    # prove no register initialises outside reset
make synth    # Vivado synthesis, and the estimate that comes with it
make impl     # place and route, and the number that means something
```

## The numbers

Post-route, `xc7a100tcsg324-1`, out of context, one clock constraint of 60 ns
with a 50 % duty cycle:

| | |
|---|--:|
| Clock period | **60.0 ns** |
| Setup slack | 0.289 ns (0.865 ns on an earlier run -- see below) |
| Hold slack | 0.111 ns |
| **Fastest the routed design will run** | **16.8 MHz**, give or take a run |
| Slice LUTs | 12650 (20.0 % of the part) |
| Slice registers | 1381 (1.1 %) |
| F7 / F8 muxes | 1707 / 282 |
| DSP48E1 | 3 |
| Block RAM | 0 |

For scale: the fastest MC68010 Motorola shipped ran at 12.5 MHz, and the part
this is modelled on was usually clocked at 8 or 10.

`make synth` reports a different, more optimistic slack, because before
placement the router's contribution is a guess — and two thirds of this
design's critical path is routing. The number above is the one to quote.

## Why the clock is what it is

Half a clock, not a whole one, because the path starts at a falling-edge flop
and ends at a rising-edge one. That much is the bus protocol and not a choice:
figure 5-3 lets a cycle begin on the rising edge immediately after the falling
edge that ended the previous one, so the request for the next cycle must be
ready by then -- and it comes from the microword that only becomes current on
that same edge. Which is why the store is read twice, once for the current
microword and once for the next.

The path place and route reports as worst is this:

```
  read data                      latched on the falling edge of S6
    -> the A source multiplexer
    -> the ALU
    -> the zero flag
    -> the micro-branch condition
    -> the next micro-address
    -> the request-preview store
    -> the bus request, latched on the rising edge that ends S7
```

41 logic levels, 29.4 ns of a 30.0 ns budget, and **72 % of it routing** -- only
8.2 ns is gates. At that ratio it is a placement and congestion problem more
than a logic-depth one, which is worth knowing before anyone restructures logic
to fix it.

### That path cannot actually happen

This document used to present the chain above as the design's defining
structure. It is the longest *topological* route, which is all static timing
analysis looks at, and the microcode never takes it.

For it to be real, one microword would have to issue a bus read, feed the read
data into the ALU, **and** branch on a flag the ALU computed -- all three, since
`asrc`, `alu` and `cond` come from the same microword. Counting them in
`build/ucode.lst`:

```
bus cycle + RDATA into the ALU + a conditional branch:   16 microwords
the condition those 16 use:                              cond=MASK, all of them

every condition that ever coexists with a bus cycle:
    MASK 56,  XWDR 21,  FMT0 1,  FMT8 1,  VERSION 1
```

None is an ALU flag. `MASK` is MOVEM's register mask and `XWDR` an
extension-word test, both from registers; `FMT0`, `FMT8` and `VERSION` test
`rdata` bits directly -- `cond_true = (rdata[15:12] == 4'h0)` -- without
touching the ALU. `cond_true` is a mux over every condition and `z_flag` is one
of its inputs, so the wire is there; synthesis has no way to know that the
microword selecting `RDATA` into the ALU is never the microword selecting a
flag to branch on.

What *is* real, and is the same shape one hop shorter, is
`movem_in_word_aind_loop`:

```
6129  seq=COND cond=MASK asrc=RDATA alu=SXW dst=REG_L bus=READ asel=T0_INC2
      wsel=MNEXT mop=STEP        ; a register, sign-extended from a word
```

`MOVEM.W (An),<list>`, one word per iteration: read it, sign-extend it through
the ALU, write the register, step the mask, decide whether to go round again,
and start the next read back to back. So read data through the ALU to the
register file in half a period is a genuine requirement, and so is read data to
the next bus request -- but by way of `MASK`, which does not pass through the
ALU. It is the *concatenation* of the two that no microword performs.

This is a functional false path, not a structural one: it depends on which
microwords exist, not on how the logic is wired. That makes it awkward to
exclude. A `set_false_path` through the flag input of the condition mux would
also disable the paths where a microword legitimately does branch on a flag,
and those still have to meet timing. Making it impossible rather than merely
improbable would mean registering `cond_true`, which costs a microword on every
conditional branch -- and the cycle counts are part of what this project
promises.

So the 60 ns constraint is met, and it is being set by a route the processor
cannot take. The honest reading of 16.8 MHz is "the design closes at 60 ns",
not "the design cannot go faster". What the real limit is has not been
measured, and measuring it means either excluding this path carefully or
looking at what place and route reports once it is gone.

Three things were done earlier to shorten this chain, and each is measured:

Three things have been done about it, and each is measured:

| | |
|---|--:|
| The multiplier moved out of the ALU into `rd68011_mul`, with registered operands and a registered result. Synthesis has no way to know that no multiply ever takes its operands from read data, so a DSP sat in the chain. | 4.0 ns |
| The decoder's address stopped being `ir_nxt`. RTE restoring `ir` put the ALU into it — never on a microword that decodes anything, but synthesis cannot know that either, so the ALU fed the decoder, the decoder fed the store, and the store fed the request. | 1.7 ns |
| The second read is of a store of its own, holding only the twenty-one bits a bus request is built from rather than all hundred and three. Area, mostly; the depth of an 8192-entry mux does not depend on its width. | 0.2 ns |

The period went 72 ns to 60 ns across those, which is 13.9 MHz to 16.8.

## Two cautions about these numbers

**Two different LUT counts, both correct.** `scripts/impl.tcl` prints the number
of LUT *primitives* (13647); the utilisation report says *Slice LUTs* (12650),
which counts occupied LUT sites. They differ by about 8 %, and comparing one
against the other looks exactly like an 8 % area regression. It is not one. The
table above quotes the report.

**Place and route varies more than the design does.** Adding `term_berr_late` --
one flip-flop, the fix in `doc/divergences.md` -- costs +6 LUTs and +1 register
at synthesis, with worst slack identical to the nanosecond (1.211 ns both ways).
Through place and route the same change reads as +71 Slice LUTs, +78 registers
and 0.576 ns less slack, because the router took a different trajectory and
replicated 78 flops along the way. Measured by checking out the earlier commit
into a worktree and running the same script, which is the only way to compare
these honestly.

So the routed slack at 60 ns sits somewhere around 0.3 to 0.9 ns depending on
the run. That is a statement about how tight the constraint is, not about any
particular change: a one-flop perturbation moves the result across most of that
band. Anyone chasing a few hundred picoseconds here should re-run the baseline
rather than trust a number in a document.

### What is left, and what it would cost

To go faster, one of these would have to give -- and the first is the one to do
before any of the others:

- **Find out what the real limit is first.** The reported path is one the
  microcode cannot take (above). Before trading anything away for speed, the
  thing to do is establish what the longest *activatable* path costs -- because
  everything below may be solving a problem the design does not have.
- **Register the bus request.** Present it a cycle earlier, which means knowing
  the next microword a cycle earlier, which a conditional branch cannot do. It
  would cost a cycle on every bus access and break the exact cycle counts that
  `sim/tb/core_timing_tb.sv` checks and `doc/timing-divergences.md` accounts
  for.
- **Precompute both arms.** A conditional microword branches to `next` or
  `next|1`, so the assembler could store both successors' request fields in the
  microword itself and leave the late signal driving only a mux. That keeps the
  cycle counts exactly and would take the store out of the path. It widens the
  microword by two request previews — 42 bits on top of 103 — and does not help
  the `DECODE` case, whose successor comes from the opcode.
- **Accept 16.8 MHz**, which is already faster than any MC68010 that was ever
  sold, and is what this project does.

The microcode store as a block RAM was considered and is not the answer. The
*current* microword could come from one — its address is a register, so a BRAM
with a registered output holds exactly the same value — and that would move
about half the LUTs into the 135 block RAMs the part has. But the current
microword is not on the critical path; the *next* one is, and its address is
not known a cycle early. It is an area trade, not a speed one, and the area is
not what is short.

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
