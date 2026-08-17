# What actually limits the frequency

`make impl` reports the worst path static timing analysis can find. For this design
that path is one the microcode cannot take, so the number it produces answers a
question nobody asked. This document reports the other one.

```sh
make impl     # place and route, and the checkpoint this works from
make paths    # the exclusions, the survivors, and the families
```

`make paths` runs on the checkpoint `make impl` leaves behind, so placement and
routing are bit-identical to the run that produced `build/impl_timing.rpt` and any
difference in the answer is attributable to the exclusion and to nothing else. It
costs about a minute.

## The headline

| | slack at 60 ns | shortest period | |
|---|--:|--:|---|
| What `make impl` reports | 0.289 ns | 59.4 ns | a path the microcode cannot take |
| What the microcode can actually reach | **1.464 ns** | **57.1 ns** | the number that means something |
| The unreachable route is worth | 1.175 ns | | |

**So the false path costs a nanosecond, not a wall.** `doc/implementation.md` was right
that 16.8 MHz is "the design closes at 60 ns" rather than "the design cannot go
faster" — but the ceiling it was hiding is 17.5 MHz, not 25. Anyone who was about to
restructure the microcode engine to recover that nanosecond should read the families
table first.

## Reading the frequency off a slack

`scripts/impl.tcl` prints `1000 / (period - slack)`. That is right for a path between
two rising edges and wrong for this design, whose critical paths all launch on one
edge and capture on the next. Their budget is *half* the period, so both halves
shrink together as the clock tightens:

```
    half-period paths:   T >= 2 x (T_now/2 - slack)  =  T_now - 2 x slack
```

At 0.289 ns that is 59.4 ns rather than the reported 59.7 — no difference worth
having. At 10 ns of slack it is 40 ns rather than 50, which is the difference between
25 MHz and 20. The table above uses the halving form. `impl.tcl` has not been changed,
because the formula is only wrong for paths whose launch and capture edges differ and
it does not know which it has; the number to quote is here.

## The families

From `make paths`, one path per endpoint, grouped by the units each passes through.
400 endpoints, worst slack 1.464 ns:

| slack | behind | ends | family |
|--:|--:|--:|---|
| **1.464** | — | 30 | `req_last -> decode-rom -> dec_entry -> ureq-rom -> rq_nxt -> req_valid -> start_new` |
| 1.815 | +0.35 | 7 | the same, ending at `fc_o` |
| 1.827 | +0.36 | 65 | the same, ending at `cur_addr` |
| **2.323** | +0.86 | 16 | `ucode-rom -> shifter`, ending at the write-data register |
| 6.616 | +5.15 | 47 | `req_last -> decode-rom -> dec_entry -> ureq-rom` |
| 10.658 | +9.19 | 21 | `a-mux -> alu -> z_flag`, ending at the micro-PC |
| 11.633 | +10.17 | 18 | `a-mux -> alu -> alu_y -> loop-rom` |
| 11.927 | +10.46 | 68 | `req_last -> decode-rom -> dec_entry` |
| 14.302 | +12.84 | 74 | `a-mux -> alu -> alu_y`, into the register file |
| 14.355 | +12.89 | 20 | `req_last` alone |
| 14.847 | +13.38 | 33 | `a-mux -> shifter` |

68 of the 400 endpoints are within a nanosecond of the worst, 101 within two. This is
a plateau, not a peak: **there is no single change that moves this design**, and any
one fix that is not accompanied by the others buys a fraction of a nanosecond.

Two families account for everything within 2.4 ns. Both are described below.

## Family A — two stores in series, at every instruction boundary

28.247 ns of a 30 ns budget, 30 logic levels, **79 % of it routing**.

```
st_n[3]                          the bus state machine, falling edge
  -> req_last                    this is the last state of the cycle
  -> dec_op                      so commit is true, so the decoder looks at irc
  -> rd68011_decode_rom          1401 ordered patterns, opcode to entry point
  -> dec_entry
  -> rd68011_ureq_rom            8192 entries, the request preview
  -> rq_nxt -> req_addr, req_valid
  -> start_new                   the bus unit latches the next cycle, rising edge
```

| segment | ns |
|---|--:|
| the flop, and `st_n` to `req_last` | 3.26 |
| `req_last` to the decoder's opcode | **4.27** |
| the decode ROM | **5.35** |
| `dec_entry` to the preview store's address | **2.77** |
| the preview store | **3.42** |
| `rq_nxt` to `req_valid` (includes the address adders) | 7.36 |
| `req_valid` to `start_new` | 1.83 |

The four bold rows — **15.8 ns, over half the path** — are one late signal being turned
into a store address and used to read two stores in series. Neither address needs to
be late. `dec_op` is `commit ? (loopback ? loop_ir : irc) : ir` (`rtl/rd68011_seq.sv:381-386`),
so it has two candidates, both registers; `commit` is the only late part. Both
candidates could be decoded in advance and the late signal left choosing between two
answers rather than driving a lookup.

This is the path 1429 microwords take — every one with `seq=DECODE`, which is every
instruction boundary in the machine. It is entirely real.

`doc/implementation.md` says of precomputing successors that it "does not help the
`DECODE` case, whose successor comes from the opcode". That is the wrong way round:
the `DECODE` case *is* the critical path, and it is helpable, because the opcode it
comes from is one of two registers.

## Family B — the write data, constrained at a third of its real budget

2.323 ns, 16 endpoints, all of them `u_biu/d_o[15:0]`.

```
upc -> rd68011_ucode_rom -> uw[sh] -> rd68011_shifter -> req_wdata -> d_o
```

Reported requirement: `clk fall@30.000ns - clk rise@0.000ns`, half a period. The
design does not need that. `d_o` is latched on the falling edge entering S3
(`rtl/rd68011_biu.sv:632-636`), and the microword became current on the rising edge
that started S0 — **three half-periods earlier**, not one. `upc` cannot change in
between, because `retire` is false until `req_last` and `upc_nxt` holds `upc`
(`rtl/rd68011_seq.sv:1227`) for the whole of a bus microword.

So this looks like a multicycle path that the constraints do not express —
`scripts/rd68011.xdc` contains no `set_multicycle_path` at all. If that is right, the
family is a constraints artefact rather than a property of the design, and saying so
costs two lines.

It is deliberately **not** asserted yet. A multicycle exception that is wrong is a
silent functional failure rather than a timing failure, and this one needs the S15
read-modify-write case checked as well as S3. It is recorded here as the next thing
to establish, not as a conclusion.

## What the exclusion is, and why it is not in the build

`scripts/paths.tcl` applies, in the reporting session only:

```tcl
set_false_path -through {u_seq/z_flag u_seq/n_flag u_seq/y[*] u_seq/alu_y[*] u_seq/sh_out[*]} \
               -through {u_seq/u_ureq_nxt/addr[*]}
```

A *pair* of `-through` points, so it cuts the concatenation and neither half: branching
on an ALU flag has to meet timing, and read data reaching the next bus request has to
meet timing; it is doing both in one microword that never happens. Counting
`build/ucode.lst`, the conditions that ever share a microword with a bus cycle are
MASK 56, XWDR 21, FMT0 1, FMT8 1 and VERSION 1, and none of the three ALU-sourced
conditions (`ZERO`, `N`, `CNT`) is among them.

It stays out of `scripts/rd68011.xdc` because it is a *functional* exclusion — it
depends on which microwords exist, not on how the logic is wired — and a constraints
file has no way to say that. Written into the build it would also disable the flag
branches that are real and do have to meet timing.

The script fails loudly rather than quietly if either `-through` names nothing, since
an exception that matches nothing looks exactly like a design that had no such path.

## The false path can be made structurally impossible, for nothing

Worth recording even though it is only worth a nanosecond, because it costs nothing
at all.

Applying `tools/ucode/isa.py`'s own `req_word()` to the resolved microprogram, and
comparing the two successors of every conditional microword:

```
condition   arms differ   arms agree
MASK                 56            0
every other            0          172
```

For all 172 non-MASK conditional microwords — including **every one of the 46 that
branch on an ALU flag** — both successors present the *identical* bus request. Only
MOVEM's mask test decides between two different ones, and `xw_after` is built from the
`xw` and `irc` registers (`rtl/rd68011_seq.sv:490-496`); it never touches the ALU.

So the condition multiplexer does not need to be in the request's fan-in at all,
except for MASK. Narrowing the select to MASK removes the ALU, the shifter, the
divider and the multiplier from the request cone by construction — no exception, no
deferral, no extra clock, no microcode change. The assembler can prove the premise on
every build and refuse to assemble a microprogram that breaks it.

## Where this leaves the design

The order these are worth doing in, by measured value:

1. **Family A.** 15.8 ns of the 28.2 ns path is two stores read at a late address.
   Carrying the previews in the microword and in the decode ROM, and decoding both
   candidate opcodes in advance, replaces the pair with a multiplexer.
2. **Family B.** Establish whether the write-data path really is multicycle. If it is,
   two lines of constraint.
3. **The MASK-only select.** A nanosecond, and free.

With all three, the next thing in the way is at 10.658 ns — `read data -> A-source
multiplexer -> ALU -> zero flag -> the micro-PC` — which would put the design somewhere
near 38 ns and 26 MHz. That is a floor set by the cycle counts: read data through the
ALU in half a period is what MOVEM and absolute-long addressing require, and shortening
it means changing what the instructions cost.

Every number here is one routed run. `doc/implementation.md:142-155` records that a
one-flop change moves routed slack by 0.58 ns, so treat differences under a nanosecond
as noise and re-run the baseline rather than trusting a figure in a document.
