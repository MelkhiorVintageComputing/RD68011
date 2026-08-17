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
| Setup slack | 0.865 ns |
| Hold slack | 0.111 ns |
| **Fastest the routed design will run** | **16.9 MHz** |
| Slice LUTs | 12579 (19.8 % of the part) |
| Slice registers | 1303 (1.0 %) |
| F7 / F8 muxes | 1707 / 282 |
| DSP48E1 | 3 |
| Block RAM | 0 |

For scale: the fastest MC68010 Motorola shipped ran at 12.5 MHz, and the part
this is modelled on was usually clocked at 8 or 10.

`make synth` reports a different, more optimistic slack, because before
placement the router's contribution is a guess — and two thirds of this
design's critical path is routing. The number above is the one to quote.

## Why the clock is what it is

One path, and it has been the same one since the instruction set was finished.
Half a clock, not a whole one, because it starts at a falling-edge flop and
ends at a rising-edge one:

```
  read data                      latched on the falling edge of S6
    -> the A and B source multiplexers
    -> the ALU
    -> the zero flag
    -> the micro-address, because a conditional microword branches on it
    -> the *next* microword, out of the microcode store
    -> the bus request address, which the bus unit latches on the rising
       edge that ends S7
```

That is not an accident of coding; it is the structure that buys the exact
cycle counts. The bus unit latches a request on the edge that ends the previous
cycle, so the request has to come from the microword that is only becoming
current on that edge — which is why the store is read twice, once for the
current microword and once for the next one.

Three things have been done about it, and each is measured:

| | |
|---|--:|
| The multiplier moved out of the ALU into `rd68011_mul`, with registered operands and a registered result. Synthesis has no way to know that no multiply ever takes its operands from read data, so a DSP sat in the chain. | 4.0 ns |
| The decoder's address stopped being `ir_nxt`. RTE restoring `ir` put the ALU into it — never on a microword that decodes anything, but synthesis cannot know that either, so the ALU fed the decoder, the decoder fed the store, and the store fed the request. | 1.7 ns |
| The second read is of a store of its own, holding only the twenty-one bits a bus request is built from rather than all hundred and three. Area, mostly; the depth of an 8192-entry mux does not depend on its width. | 0.2 ns |

The period went 72 ns to 60 ns across those, which is 13.9 MHz to 16.9.

### What is left, and what it would cost

The chain that remains is irreducible without changing what the design is. To
go faster, one of these would have to give:

- **Register the bus request.** Present it a cycle earlier, which means knowing
  the next microword a cycle earlier, which a conditional branch on the ALU
  cannot do. It would cost a cycle on every bus access and break the exact
  cycle counts that `sim/tb/core_timing_tb.sv` checks and
  `doc/timing-divergences.md` accounts for.
- **Precompute both arms.** A conditional microword branches to `next` or
  `next|1`, so the assembler could store both successors' request fields in the
  microword itself and leave the late signal driving only a mux. That keeps the
  cycle counts exactly and would take the store out of the path. It widens the
  microword by two request previews — 42 bits on top of 103 — and does not help
  the `DECODE` case, whose successor comes from the opcode.
- **Accept 16.9 MHz**, which is already faster than any MC68010 that was ever
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
