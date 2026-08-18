# What actually limits the frequency

For most of this design's life the worst path `make impl` reported was one the
microcode could not take, so the number it produced answered a question nobody
asked. This document is the measurement that replaced it, and what the
measurement led to.

```sh
make impl     # place and route, and the checkpoint this works from
make paths    # the exclusions, the survivors, and the families
```

`make paths` runs on the checkpoint `make impl` leaves behind, so placement and
routing are bit-identical to the run being examined and any difference in the
answer is attributable to the exclusion and to nothing else. It costs about a
minute.

## Where it started, and where it is

All at the 60 ns constraint the design started from, so the rows compare:

| | worst slack | what was limiting it |
|---|--:|---|
| P8, as measured | 0.289 ns | a route the microcode cannot take |
| ... with that route excluded | 1.464 ns | the decoder and the preview store, in series |
| decode the next opcode early | 0.534 / 1.943 ns | the write data, over-constrained |
| previews carried in the microword | 1.953 ns | the write data |
| steer the request on the mask alone | 1.509 ns | the write data |
| the write data's real budget | **3.027 ns** | read data through the datapath into the next address |

The first two rows are the same design measured two ways; the rest are changes.
What limits it now is real, is named, and is required by the cycle counts.

The constraint then moved to where the design actually closes:

| clock | slack | |
|--:|--:|---|
| 54 ns | +3.497 ns | |
| **48 ns** | **+2.077 and +0.752 ns** | **20.8 MHz, two runs, and what `scripts/rd68011.xdc` now asks for** |
| 46 ns | +0.277 ns | closes once, and that is well inside the spread above |

The two 48 ns runs differed only in the contents of one unreachable microcode
word and came out 1.3 ns apart, with the same register, carry and DSP counts and
five Slice LUTs between them. That spread is the reason the rows in the previous
table should not be read as though tenths of a nanosecond meant anything.

16.8 MHz to 20.8, and the fastest MC68010 Motorola shipped ran at 12.5.

**The false path was worth 1.175 ns.** `doc/implementation.md` used to present it
as the design's defining structure, and it was not: it cost about a nanosecond of
a thirty-nanosecond budget. It is now gone rather than excluded -- the exclusion
`make paths` applies finds nothing left to cut -- because the bus request is
selected on MOVEM's mask test alone.

## Reading a frequency off a slack

`scripts/impl.tcl` prints `1000 / (period - slack)`. That is right for a path
between two rising edges and wrong for this design, whose critical paths all
launch on one edge and capture on the next. Their budget is *half* the period, so
both halves shrink together as the clock tightens:

```
    half-period paths:   T >= T_now - 2 x slack
```

At 0.289 ns the two forms differ by 0.3 ns. At 3 ns they differ by 3 ns, and at
10 ns by 10. `impl.tcl` has not been changed, because the formula is only wrong
for paths whose launch and capture edges differ and it does not know which it
has. Where a frequency is quoted, it is measured by editing `clk_period_ns` in
`scripts/rd68011.xdc` and running place and route again, not extrapolated.
Making that conditional on the environment was tried and is a trap: `read_xdc`
accepts an `if` around the `create_clock` without complaint and then creates no
clock at all, so the design places and routes unconstrained and only fails at
the very end, when `impl.tcl` asks a clock that does not exist for its slack.

## What limits it now

34 endpoints at 48 ns, and it is the shape the cycle counts require:

```
req_rdata                     latched on the falling edge of S6
  -> the A and B source multiplexers
  -> the ALU, or the shifter, whichever the microword selects
  -> t0_nxt / pc_nxt / ea_latch_nxt
  -> n_addr, and the address-error check on it
  -> req_valid
  -> start_new                the bus unit latches the next cycle, rising edge
```

The microcode that needs it is absolute-long addressing, where one microword
reads the low half of an address and concatenates it with `irc` into T0, and the
next issues at `asel=T0`:

```
1119  next=1120 asrc=IRC bsrc=RDATA alu=CAT dst=T0 bus=READ pf=FETCH
1120  next=1121 asrc=T1 dst=DBUF bus=WRITE asel=T0 fc=DATA aeasel=DST dhi=1 size=LONG
```

and branch targets do the same through `dst=PC` into `asel=PC`. Read data through
the datapath into the next bus address, in half a period, is what "no wasted
clock between the address arriving and the cycle that uses it" means. Shortening
it means changing what the instructions cost.

The families behind it, from `make paths`:

| slack | behind | ends | family |
|--:|--:|--:|---|
| **2.077** | — | 34 | `a-mux -> shifter -> req_valid -> start_new` |
| 2.315 | +0.24 | 3 | the same, ending at `req_valid` |
| 2.566 | +0.49 | 59 | `a-mux -> shifter`, into the sequencer's own registers |
| 3.806 | +1.73 | 272 | `shifter` |
| 4.835 | +2.76 | 18 | `shifter -> loop-rom` |
| 8.342 | +6.27 | 1 | `alu` |
| 8.898 | +6.82 | 13 | `alu -> alu_y` |

At 60 ns the ALU was the worse of the two datapath arms and at 48 ns the
shifter is. They are the same path with a different unit in the middle.

## The four changes

### Decode the next opcode without waiting for the bus cycle to end

`dec_op` tested `commit` on both of its alternatives, so the decoder's opcode only
settled once the current cycle terminated -- and the decoder and the preview store
were then read in series inside half a clock, 15.8 ns of a 28.2 ns path, at every
instruction boundary.

The guard was never doing anything. `dec_entry` and `dec_dbcc` are read in one
place, the DECODE arm of `upc_target`, and that arm is only selected when
`retire && !fault`, which is `commit`. All three sources are registers, so
removing it gives the decode a whole clock. The family went from worst at
1.464 ns to 12.084 ns and left the top of the report.

### Carry the successors' request previews in the microword

The bus request has to come from the microword that will be current after the
coming edge, and which that is depends on the bus terminating, the condition
resolving and any fault. It used to be read out of an 8192-entry store at an
address computed from all of that; the store's address net alone carried 1.241 ns
of routing to 1189 loads.

Nothing is looked up late now. A microword carries the previews of its own two
successors, the decoder emits its entry point's beside the entry, the entry points
the sequencer can be thrown to have constant ones, and the arms that hold the
micro-PC take the current microword's own fields. `rd68011_ureq_rom` is gone and
the microword is 145 bits rather than 103.

One arm has no preview to carry: RESUME goes to `upc_save`, which RTE reloads out
of the format $8 frame. It presents no request and the resumed microword's cycle
starts a clock later through the `!retire` arm -- one clock, on the rarest path in
the machine, and no second store.

### Steer the request on the mask test alone

A conditional microword only steers the *bus* if its two successors present
different requests. Applying `req_word()` to both arms of all 228 of them:

```
condition   arms differ   arms agree
MASK                 56            0
every other            0          172
```

Only MOVEM's mask test, deciding whether there is another transfer. The other 172
-- including every one of the 46 that branch on an ALU flag -- present the same
request either way, so the condition cannot reach the bus through them.

So `prev_sel` tests the mask rather than `cond_true`, and the ALU, the shifter,
the divider and the multiplier leave the request's fan-in by construction.
`xw_after` is `irc`, `xw`, or `xw` with a bit cleared: registers, all of them.
`tools/ucode/isa.py`'s `BUS_STEERING_CONDS` is the same statement on the
assembler's side, and `assemble.py` fails the build if the microprogram ever needs
a condition the RTL does not implement.

### The write data's real budget

`d_o` is loaded on the falling edge entering S3. The microword that supplies the
data became current on the rising edge that started S0, and S0 to S1, S1 to S2 and
S2 to S3 alternate edges unconditionally, so it has had three half clocks. Static
timing analysis sees a rising launch and a falling capture and allows one.

`scripts/rd68011.xdc` now says so. This is the only exception in the build whose
failure mode is silent, so it is measured as well as argued:
`sim/tb/rd68011_core_harness.svh` records how long the captured value had already
been stable at every load, across every core testbench, the five programs and the
reference vectors, and fails if it is ever less than three half clocks. `make sim`
prints the number, which is 3. `make paths` also reports what the tool thinks the
requirement is, because a `-to` pattern that stops matching would drop the
constraint silently.

## What the exclusion is, and why it is not in the build

`scripts/paths.tcl` applies, in the reporting session only, a *pair* of `-through`
points so that it cuts a concatenation and neither half:

```tcl
set_false_path -through {u_seq/u_alu/y[*] u_seq/u_alu/n_out u_seq/u_alu/z_out
                         u_seq/u_shifter/dout[*]} \
               -through {u_biu/req_kind[*]}
```

Branching on an ALU flag has to meet timing; read data reaching the next bus
request has to meet timing; doing both in one microword is what never happens. It
stays out of `scripts/rd68011.xdc` because it is a *functional* exclusion, and a
constraints file has no way to say "depends on which microwords exist".

Both ends name module pins, not the nets between them, and that was learned the
hard way -- twice. `n_flag` is a multiplexer over `n_flag_alu` and the shifter's
flag, and synthesis folds that multiplexer into the logic downstream, so a route
can reach the request without the net `u_seq/n_flag` existing anywhere on it; the
first version of this script missed a whole family that way and reported a
too-good number. Then `rq_nxt` stopped existing as a net at all once it became a
multiplexer rather than a store output, and the second version aborted. Hierarchy
survives, because `scripts/synth.tcl` passes `-flatten_hierarchy none`.

`req_kind` is the witness rather than the whole request: it says which kind of bus
cycle happens and is built from the preview and nothing else, unlike `req_addr`,
which the ALU legitimately reaches through the address unit. Every bit of the
preview is selected by the same signal, so if the ALU cannot reach `req_kind` it
is not in the preview's fan-in at all.

The script fails loudly if either end names nothing, and reports it as a result --
not an error -- when the route simply is not there, which is what it now says.

## What is left

- **The floor is the address path.** Read data through the datapath into the
  next bus address is required by absolute-long addressing and by branch
  targets. The only
  thing on it that is not obviously necessary is the address-error check standing
  between `n_addr` and `req_valid`; whether the bus unit could make that check
  itself, a state later, has not been looked at.
- **76.8 % of the delay is routing.** The worst path is 21.7 ns in 24 logic
  levels and only 5.0 ns of that is gates; before these changes it was 29.4 ns
  in 41 levels at 72 %. Taking logic out made the ratio worse, which is what
  should be expected and is worth knowing before anyone restructures logic to
  fix a placement and congestion problem.
- **Place and route varies more than small changes do.** Two runs of the same
  design 1.3 ns apart, and a one-flop change reading as 0.576 ns; treat anything
  under about 1.5 ns as a statement about the router. Several rows above differ
  by less than that and are not regressions. Re-run the baseline rather than
  trusting a figure in a document, including these.
