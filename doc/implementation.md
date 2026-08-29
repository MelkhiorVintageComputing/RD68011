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
| Setup slack | 2.048 ns |
| Hold slack | 0.138 ns |
| Slice LUTs | 6585 (10.4 % of the part) |
| Slice registers | 1342 (1.1 %) |
| F7 / F8 muxes | 551 / 112 |
| DSP48E1 | 3 |
| Block RAM | 7.5 of 135 |

`doc/size-and-speed.md` is where those last four rows changed: the microcode
store is a block memory rather than 6665 LUTs, and the design is half the size
it was. That document also measures what it cost, which was not nothing.

### The same design on a MAX 10

`make quartus` fits it to `10M50DAF484C7G`, the largest MAX 10 Quartus Prime
Lite supports, with the same 48 ns clock so the two are reported against the
same period. It is a deliberately unlike part: four-input logic elements and
M9K blocks where the Artix-7 has six-input LUTs and 36 kbit block RAMs.

| | |
|---|--:|
| Fmax | **19.98 MHz** |
| Setup slack | −2.351 ns against 48 ns |
| Hold slack | 0.322 ns |
| Logic elements | 13749 (28 % of the part) |
| Registers | 1391 |
| Embedded 9-bit multipliers | 4 (1 %) |
| M9K blocks | 30 of 182 (16 %) |
| Memory bits | 245760 (of 1677312) |

28 % of the part where it was 72 %, and it needs one assignment to get there:
MAX 10 loads its embedded RAM from the configuration flash and only does so when
the image is built to carry the contents, so without
`INTERNAL_FLASH_UPDATE_MODE "SINGLE COMP IMAGE WITH ERAM"` in
`scripts/quartus.tcl` every inferred ROM stays in logic, silently.
`doc/size-and-speed.md` has that measurement and the six others it took to find
it.

It does not quite reach 48 ns, and `make quartus` gates on the Fmax floor in the
Makefile rather than on that slack, which is a regression test rather than an
aspiration.

Quartus's Fmax is the more trustworthy of the two frequency figures here. The
section below on reading a frequency off a slack explains why `1000 / (period −
slack)` is wrong for this design; Quartus computes Fmax by scaling both clock
edges together, keeping the duty cycle, which is exactly what an edge-to-edge
path needs.

**It was 4.26 MHz.** The first fit came in a factor of four and a half lower
than this, and the whole of the difference was one generated file. It is worth
recording, because it is the only place so far where the design's speed turned
out not to be portable, and because what fixed it changed no logic at all.

The worst path was `upc[0]` to `cur_addr[30]`, 235 ns through **498 logic
levels**, with 940 of the nodes on it inside `u_decode`.
`rtl/gen/rd68011_decode_rom.sv` was a `casez` of 1401 patterns whose header said
"the first matching pattern wins" -- a priority decoder by construction, which
is how forms distinguished only by a field value are separated there rather
than by a run-time test in the microcode. Vivado and yosys both flatten that.
Quartus Lite builds it as written, a cascade. Measured on the decoder alone,
registered on both sides with nothing else present: **4.67 MHz**, against 4.26
for the whole core -- the decoder was not the largest contributor to the
critical path, it was very nearly all of it. `OPTIMIZATION_TECHNIQUE SPEED` with
`OPTIMIZATION_MODE "AGGRESSIVE PERFORMANCE"` moved it to 4.77, so it was
structural rather than a flow setting, and `quartus_syn`, the newer engine that
might do better, is Pro-only.

`tools/ucode/assemble.py` now resolves the order into disjoint patterns before
emitting them. The source in `program.py` stays ordered, because that is the
readable way to say that `BRA.W` is `BRA.B` with a displacement byte of zero;
`make_disjoint` subtracts each pattern from the ones before it, and
`check_disjoint` proves over all 65536 opcodes that the two tables decode alike
and that no two parallel patterns overlap. Only the branch group actually
overlapped -- `BRA.B`, `BSR.B`, `Bcc.W` and `Bcc.B`, four patterns of 1401,
530 encodings of 65536. Because a `casez` cannot say "not zero", a displacement
byte that must be non-zero becomes eight patterns and a `Bcc` that must not be
`BRA` or `BSR` becomes three; 1401 patterns become 1440.

What that bought, all of it measured:

| | ordered | disjoint |
|---|--:|--:|
| MAX 10, decoder alone | 4.67 MHz | **41.87 MHz** |
| MAX 10, whole core | 4.26 MHz | **19.32 MHz** |
| MAX 10, logic elements | 37366 (75 %) | 35924 (72 %) |
| MAX 10, worst path | 498 logic levels | 29 |
| MAX 10, fit time | about two hours | seven minutes |
| Artix-7, setup slack at 48 ns | 1.994 ns | 2.009 ns |
| Artix-7, LUTs | 14416 | 14346 |
| Artix-7, `u_decode` LUTs | 1130 | 1080 |

Both columns are that experiment's own runs, so they stay as measured and do
not track the tables above: the design has gained a register since, and the
"disjoint" column is no longer the current figure.

**On the Artix-7 it changed nothing, and that was the expectation.** The
decoder appears in none of the 400 worst paths `make impl` reports, before or
after; `doc/critical-path.md` records that it stopped being the limit two
changes ago, when the next opcode began decoding early and the previews moved
into the microword. Fifteen picoseconds is noise against the 1.3 ns spread that
document measured between two runs of the same design. The 50 LUTs are real but
uninteresting.

The MAX 10's worst path is now `req_rdata[7]` to `cyc_addr[20]` in 36 logic
levels -- the same family as the Artix-7's, read data through the datapath into
the next address. The two tools now agree about what limits this design, which
they did not before.

### Where the area goes

`report_utilization -hierarchical`, same run. Worth having because until it was
added every area claim in this document was a guess:

| | LUTs | FFs | BRAM | |
|---|--:|--:|--:|---|
| `u_seq` itself | 3467 | 1096 | 0 | source multiplexers, address unit, register file |
| `u_decode` | 1076 | 0 | 0 | 1401 opcode patterns, entry point and preview |
| `u_urom` | 589 | 0 | 7.5 | the microcode store: 533 control table, 56 previews |
| `u_shifter` | 578 | 0 | 0 | one barrel, shared |
| `u_alu` | 500 | 0 | 0 | |
| `u_divider` | 224 | 89 | 0 | |
| `u_biu` | 135 | 157 | 0 | the bus interface is almost all flops |
| total | 6585 | 1342 | 7.5 | plus 3 DSP48E1 for the multiplier |

The store used to be 6665 LUTs and half the design. `doc/size-and-speed.md` is
what changed that, and it is also where the shifter's 814 became 578.

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
| as first measured | 0.289 ns |
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
of LUT *primitives* (14603); the utilisation report says *Slice LUTs* (13121),
which counts occupied LUT sites. They differ by more than 10 %, and comparing
one against the other looks exactly like a regression. It is not one. The table
above quotes the report.

**Place and route varies more than small changes do, and by more than was
thought.** Two runs at 48 ns, differing only by the contents of one unreachable
microcode word, came out at **2.077 ns and 0.752 ns** of slack -- with 13011 and
13016 Slice LUTs, and identical register, carry and DSP counts. A 1.3 ns spread
on what is essentially the same netlist.

The earlier evidence pointed the same way and was read too narrowly: adding
`term_berr_late`, one flip-flop, costs +6 LUTs and +1 register at synthesis with
worst slack identical to the nanosecond, but reads as +71 Slice LUTs, +78
registers and 0.576 ns after routing, because the router took a different
trajectory and replicated 78 flops on the way.

So **treat a difference under about 1.5 ns as a statement about the router**,
not about the design, and do not quote a single routed slack as though it were a
property. Several rows of the table in "Why the clock is what it is" differ by
less than that. Anyone chasing a few hundred picoseconds should re-run the
baseline rather than trust a number in a document -- including these.

**What the previews cost.** Deleting `rd68011_ureq_rom` and widening the
microword from 103 bits to 145 -- it is 146 now, one more for `notrace` -- is
**+342 Slice LUTs, +2.7 %** -- and 77 *fewer*
registers, because the router had less reason to replicate. The 8192-entry
21-bit store it replaced was worth more than the 42 bits added.

### What is left, and what it would cost

- **The floor is the address path.** Read data through the datapath into the
  next bus address is required by absolute-long addressing and by branch
  targets, and shortening it means changing what those instructions cost. The
  one thing on it that is not obviously necessary is the address-error check
  standing between `n_addr` and `req_valid`; whether the bus unit could make
  that check itself, a state later, has not been looked at.
- **It is a routing problem more than a depth one.** The worst path is 21.7 ns
  in 24 logic levels, and **76.8 % of that is routing** -- only 5.0 ns is gates.
  It was 29.4 ns in 41 levels at 72 % before the changes above, so the logic
  came out and the ratio got worse. That is worth knowing before anyone
  restructures logic to fix a placement problem.
- **Registering the bus request** would present it a cycle earlier, which means
  knowing the next microword a cycle earlier, which a conditional branch cannot
  do. It would cost a cycle on every bus access and break the exact cycle counts
  that `sim/tb/core_timing_tb.sv` checks and `doc/timing-divergences.md`
  accounts for. It is not worth it and it is not necessary.

The microcode store *is* a block memory now, and this paragraph used to predict
what that would be worth. It was right about the mechanism and about the
frequency and wrong about the size. The read at `upc` moved to `upc_nxt`, whose
address is a register either way, so the memory holds the same word at the same
time and costs no clock; it halved the LUT count and bought no frequency on this
part. What it did not predict is the MAX 10, where it cost five per cent until
the microword was re-encoded and the address register taken out of the ALU's
reach. `doc/size-and-speed.md` is the whole account, including the two
hypotheses it refuted.

## The reset audit

ASIC is a target, so there is no power-on register state: every register takes
its value from the reset branch of its `always_ff`. `make audit` proves it two
ways, because either alone would miss something.

**Source.** No `initial` block, no `always_latch`, and no initialiser on a
declaration that could infer a register, anywhere under `rtl/`.

**Netlist.** yosys synthesises the whole design to gate-level flops and the
cell types are read back. A flop without a reset is a different cell there —
`$_DFF_P_` rather than `$_DFF_PN0_` — so one that got past the source check by
some route nobody thought of still shows up. The current output:

```
reset audit: 16 files, no initial blocks, no latches, no declaration initialisers
reset audit: 1385 flip-flops in the netlist, every one of them with a reset
    $_DFFE_NN0P_        61      $_DFF_NN0_          30
    $_DFFE_NN1P_         1      $_DFF_NN1_          15
    $_DFFE_PN0N_        84      $_DFF_PN0_         588
    $_DFFE_PN0P_       596      $_DFF_PN1_           4
    $_DFFE_PN1P_         6
reset audit: 30 more in rd68011_ucode_rom, which the module docstring exempts
```

### One register has no reset, and it is named

The microcode store's output register takes no reset value. It cannot: a block
memory's read register is inside the primitive, and requiring a reset on it is
requiring the store to be logic -- which was 6665 LUTs on the Artix-7 and 23604
logic elements on the MAX 10, half the design on one part and two thirds of it
on the other.

The rule exists to prevent a design that depends on power-on state, and this one
does not. The store is addressed by `upc_nxt`, which `rd68011_seq.sv` forces to
`ENTRY_RESET` whenever `rst_n` or `reset_sync_n` is asserted, so one clock edge
during reset leaves it holding `ROM[ENTRY_RESET]` -- the same microword `upc`'s
own reset branch selects, so the pair is consistent from that edge onwards. Its
value is determined by reset, by a different mechanism from every other register
here. The obligation that creates is one clock edge while reset is asserted;
`core_reset` gives four, `harte_tb` one, and the part requires four.

The exemption is *enforced* rather than allowed: no resetless register may exist
outside that one module, and both halves of that were watched to fail. It is
named by module and not by instance because a flattened netlist cannot be asked
-- yosys's `ff` pass renames the flops to `$auto$ff.cc:266:slice$41200` and drops
their `src` attribute, so `n:`, `c:` and `a:src=` all match nothing. The audit is
hierarchical for that reason, which also runs faster and says which module each
flop is in.

That is why the count reads 1385 where it read 1381: without flattening, four
registers that cross-module optimisation used to remove now survive.

Every one of those cell names carries a reset polarity and a reset value. The
absence of a resetless type is the point, not the count -- but the count should
still be right, and for a long time it was not. It read 2684, and every figure
in the table was twice what it should have been: `synth` prints statistics of its own
before the explicit `stat` does, so the output holds two identical blocks and
the audit summed both. The doubling was noticed and then explained away, as
yosys flattening without merging. That explanation was wrong, and the size of
the gap should have been the clue -- yosys does count a few more than the
place-and-route tools do, 1385 against Vivado's 1342 placed and Quartus's 1391
registers, but not twice as many. `tools/reset_audit.py` now reads only the
last block, and since it stopped flattening, only the aggregate under
`=== design hierarchy ===` -- the per-module blocks above it must not be added
up as well, which would be the same mistake wearing a different hat.

The negative-edge flops in that list are the bus interface's output stage,
which is negedge-clocked on purpose — one bus state is half a clock period, and
`doc/bus-timing-compliance.md` explains why.

## Six tools, one subset

`make lint` elaborates every module under iverilog 12.0, Verilator 5.032 and
yosys 0.52; `make synth` adds Vivado 2025.2, `make lint-quartus` adds Quartus
Prime Lite 25.1 and `make lint-questa` adds Questa Altera Starter Edition
2025.2. The intersection of what those six accept is the language this project
is written in, and `doc/coding-standard.md` is the record of where the edges
are — every entry in it was found by trying it here.

yosys is the strictest and therefore the one that defines the subset. The lint
target runs a full `synth`, not just `read_verilog`, so anything
unsynthesisable is caught there rather than half an hour later in Vivado.

The last three each need a vendor installation, so none of them is in `make
check`. What they buy is independence: six front-ends that share no parser.
The two Altera ones were added last and each found something on its first run —
Quartus a mis-parse of package scope inside an instantiation port expression
that produced a silently wrong netlist, Questa a set of variables the
testbenches read above their own declarations. Both are in
`doc/coding-standard.md`, and `make lint-quartus` greps for the Quartus one
because that tool's exit code does not report it.

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
