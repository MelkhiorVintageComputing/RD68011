# RD68011 — a SystemVerilog MC68010

A from-scratch implementation of the Motorola MC68010 in portable SystemVerilog,
targeting FPGA today and ASIC eventually. It is not a "68000-alike": the goal is
the part, including the bus protocol state by state and the mechanism the
MC68010 exists for — a bus error that can be recovered from and an instruction
that carries on afterwards.

Written from the Motorola manuals alone. Nothing here was derived from another
implementation's source.

| | |
|---|---|
| **ISA** | all **89** MC68010 instructions, every addressing mode, every exception |
| **Bus** | asynchronous S0–S7 cycles, read-modify-write, arbitration, M6800 synchronous cycles, autovectored and vectored interrupts |
| **MC68010 proper** | instruction continuation (format $8 frame + RTE), loop mode, VBR, SFC/DFC, MOVEC/MOVES/RTD/BKPT |
| **Verified by** | 23492 reference vectors, 93991 co-simulated instructions, 15 directed testbenches, 6 programs, a second core in VHDL |
| **Implemented** | 20.8 MHz post-route on an `xc7a100t-1`, 6585 LUTs, 1342 FFs, 7.5 block RAMs |
| **For scale** | the fastest MC68010 Motorola shipped ran at 12.5 MHz |

```sh
make check      # lint, reset audit, testbenches, programs, AC-timing gates
make harte-all  # every SingleStepTests opcode file the ISA covers
make cosim      # the programs against Musashi, every register, every instruction
make impl       # place and route, for the frequency that means something
```

---

## Architecture

Two modules and a clean contract between them. The sequencer says *what* access
it wants; the bus interface unit owns *when* every pin moves.

```
                            rd68011_top
  ┌────────────────────────────────────────────────────────────────────┐
  │                                                                    │
  │   ┌──────────────────────── rd68011_seq ────────────────────────┐  │
  │   │  microcode engine · datapath · register file · address unit │  │
  │   │  prefetch pipe · loop mode · fault checkpointing            │  │
  │   └──────────┬──────────────────────────────────▲───────────────┘  │
  │              │                                  │                  │
  │   req_valid  │  req_kind  req_fc  req_addr      │  req_ack         │
  │   req_uds    │  req_lds   req_wdata             │  req_last        │
  │   reset_req  │  dbf                             │  req_rdata       │
  │              │                                  │  req_end         │
  │              │                                  │  req_fault[_wr]  │
  │              │                                  │  reset_busy      │
  │              │                                  │  ipl/reset/halt  │
  │              ▼                                  │  bus_idle        │
  │   ┌──────────────────────── rd68011_biu ────────┴───────────────┐  │
  │   │  S0–S7 state machine (half a clock per state)               │  │
  │   │  wait states · BERR/RETRY/HALT · read-modify-write          │  │
  │   │  bus arbitration · E clock and VMA · input synchronisers    │  │
  │   │  double-edge output flops for AS, UDS, LDS, data enable     │  │
  │   └──────────────────────────┬──────────────────────────────────┘  │
  └──────────────────────────────┼─────────────────────────────────────┘
                                 ▼
              every three-state pin split into  _i / _o / _oe
              (an external wrapper makes real pins — doc/pinout.md)
```

`req_kind` is one of `READ`, `WRITE`, `RMW`, `IACK`, `BKPT`. The sequencer never
counts clocks: it presents a request and stalls until `req_ack`, so wait states,
a slow M6800 peripheral and a retried cycle all look the same from above.

### The microcode engine

One microword per clock, 146 bits wide, 6674 of them.

```
   ir ─┐      ┌────────────────┐   entry point ─────────┐
       ├─────►│   decode_rom   │                        │
  irc ─┘      │ 1440 patterns  │   request preview ───┐ │
              └────────────────┘                      │ │
                                                      ▼ ▼
  bus cycle terminated? ───┐    ┌───────────────────────────────────┐
  condition true? ─────────┼───►│      select the next arm          │
  fault? ──────────────────┘    │  NEXT · COND · DECODE · RESUME    │
                                │  fault entry · hold               │
  this microword's ────────────►│                                   │
  next / next|1, rq0 / rq1      └──────┬─────────────────────┬──────┘
                                 upc' ─┘                     └── its preview
                                       │                            │
              ┌────────────────────────▼────────────┐               ▼
              │  ucode_rom   8192 × 30, registered  │      the request the BIU
              │  Read at upc' rather than upc: the  │      latches on this edge
              │  same word at the same time, and a  │
              │  memory instead of logic.           │
              └────────┬──────────────────┬─────────┘
               control │                  │ preview
                 index ▼                  ▼ index
           ┌───────────────────┐  ┌───────────────────┐
           │ uctl_rom 600 × 91 │  │ urq_rom  126 × 42 │
           └─────────┬─────────┘  └─────────┬─────────┘
                     └───── uw, 146 b ──────┘
                                │
                                ▼
              datapath control · prefetch · loop mode ·
              condition codes · both successors' previews
```

Three things in that picture are answers to a measurement rather than the
obvious design:

- **A microword carries its own successors' bus requests.** The request the bus
  unit latches has to come from the microword that will be current *after* the
  coming edge — which depends on the cycle terminating, a condition resolving
  and any fault. A second lookup at that late address is the obvious way, and an
  expensive one, so nothing is looked up late: each microword carries the
  previews of both its successors, the decoder emits one beside its entry point,
  and the arms that hold the micro-PC reuse the current microword's own fields.
- **Only one condition can steer the bus.** Of 228 conditional microwords, the
  two arms present a different bus request in exactly 56 — all of them MOVEM's
  mask test, deciding whether another transfer follows. So the request is
  selected on that test alone, and the ALU, the shifter, the divider and the
  multiplier leave the request's fan-in by construction. The assembler enforces
  it, so a future microcode edit that broke the property would fail the build.
- **The store is read a microword early, and is two tables deep.** `upc` takes
  `upc'` unconditionally outside reset, so a memory addressed at `upc'` with a
  registered read holds the same word at the same time — no clock lost, and a
  block RAM instead of logic. Storing an *index* into the 600 distinct control
  patterns and the 126 distinct preview pairs then makes the stored word 30 bits
  rather than 146.

`doc/critical-path.md` measures the first two, `doc/size-and-speed.md` the third.

### The datapath

```
    ir · irc · rdata · registers · constants · SR/CCR · VBR · USP · ea_latch
              │                                        │
        ┌─────▼──────┐   one shared list of     ┌──────▼─────┐
        │  A source  │   51 named sources       │  B source  │
        └─────┬──────┘                          └──────┬─────┘
              └───────────┬──────────┬──────────┬──────┘
                          ▼          ▼          ▼          ▼
                       ┌─────┐  ┌────────┐ ┌────────┐ ┌────────┐
                       │ ALU │  │shifter │ │divider │ │  mul   │
                       │     │  │ 1 clk, │ │ multi- │ │ 3 DSP  │
                       │ +/- │  │ any    │ │ clock  │ │ blocks │
                       │ log │  │ count  │ │        │ │        │
                       │ BCD │  └────────┘ └────────┘ └────────┘
                       └─────┘       │          │          │
                          └──────────┴────┬─────┴──────────┘
                                          ▼  y[31:0]
   ┌──────────────┬──────────────┬────────┴─────┬──────────────┐
   ▼              ▼              ▼              ▼              ▼
 D0–D7          PC · T0 · T1   ea_latch      SR / CCR      DBUF (32 b)
 A0–A6          ir · irc       address       SFC / DFC     the data output
 USP / SSP      upc_save       output buffer VBR           buffer a fault saves
```

`A7` is not in the register array: it is whichever stack pointer the S bit
selects, so an exception switches stacks without moving anything.

The **address unit** sits between `y` and the bus request. It picks a base
register, applies the pre-decrement or post-increment the microword asks for,
bypasses a register write landing in the same edge, and checks the result for an
address error before the request is presented. Read data, through the datapath,
into the next bus address, inside half a clock — that is what "no wasted clock
between an address arriving and the cycle that uses it" costs, and it is the
design's critical path.

### The bus cycle

Half a clock period per bus state, which is the manual's own ruler. Every
testbench indexes its observations by half-clock tick from the S0 rising edge
and asserts against it.

```
            S0    S1    S2    S3    S4    S5    S6    S7
  clk     ‾‾‾‾‾\_____/‾‾‾‾‾\_____/‾‾‾‾‾\_____/‾‾‾‾‾\_____/
  FC      <═══════════════ function code ════════════════>
  A1-A23  ─────<═══════════════ address ══════════════════
  /AS     ‾‾‾‾‾‾‾‾‾‾‾\_____________________________/‾‾‾‾‾‾
  /UDS r  ‾‾‾‾‾‾‾‾‾‾‾\_____________________________/‾‾‾‾‾‾
  D    r                    <──── slave drives ────>
                                                   ^ read data latched
  R//W w  ‾‾‾‾‾‾‾‾‾‾‾\_____________________________/‾‾‾‾‾‾
  /UDS w  ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\_________________/‾‾‾‾‾‾
  D    w                    <═ data output buffer ═>
  /DTACK                               ^ sampled
```

| Edge | What moves | Manual |
|---|---|---|
| S0 rising | function code valid, R/W high | 5.1.1 state 0 |
| S1 falling | address valid | 5.1.1 state 1 |
| S2 rising | AS asserted; data strobes on a read; R/W low on a write | 5.1.1/5.1.2 state 2 |
| S4 rising | data strobes on a write | 5.1.2 state 4 |
| S4 falling | DTACK, BERR, VPA, HALT sampled — a wait state is a whole clock inserted here | 5.1.1 state 4 |
| S6 falling | read data latched; AS and data strobes negated | 5.1.1 state 7 |
| S7 rising | address and data buses released; R/W driven high | 5.1.2 state 7 |

The address bus floats between cycles, and through S0 of the next one:
§5.1.1, 5.1.2, 5.1.3 and appendix B all say so, specification 7 gives the time
it takes, and figures 5-3 and 10-4 draw it on the mid rail there.
`ADDR_HIZ_BETWEEN_CYCLES` keeps it driven for a board that needs it.

Read-modify-write is one indivisible twenty-state cycle — S0–S7 read, S8–S11
internal, S12–S19 write, with AS asserted straight through. An M6800
synchronous cycle replaces the DTACK handshake with VPA, VMA and the E clock,
which divides the input by ten, six low and four high. Interrupt acknowledge is
a CPU-space read that takes a vector number, or an autovector if VPA answers
instead — and, unlike an M6800 cycle, it does not wait for E.

### Instruction continuation

The MC68010's reason for existing. A faulted access aborts the microword before
anything it would have written is written, so the state the format $8 frame
records is the state at the *start* of that microword. The frame is 29 words —
status register, program counter, format and vector, the special status word,
the fault address, the data output buffer, the data input buffer, the
instruction input buffer, and 16 internal words. `RTE` reloads them, resumes at
the saved micro-address, and the microword reissues exactly the same request —
or, if the handler set the rerun flag because it completed the access itself,
does not.

That constraint shapes the whole microarchitecture: every scrap of state an
instruction accumulates has to live in a fixed, named set of registers the frame
can save and reload, not in whatever a given piece of microcode found
convenient. `doc/checkpoint.md` froze that set before the instructions existed.

The special status word describing the faulted cycle — which bits mean what,
what each field reads for every shape of access, and what two other cores make
of it — is in `doc/ssw.md`.

---

## Verification

Five pressures, and they find different things. No single one of them would have
found the bugs the others did.

| | What it is | Scale |
|---|---|--:|
| **Reference vectors** | `make harte-all` runs SingleStepTests through the core one instruction at a time, comparing registers, prefetch pipe, memory and the whole bus transaction list | 124 opcode files, **23492 tests, zero failures** |
| **Directed testbenches** | `make sim` — what vectors cannot reach: the bus protocol edge by edge, faults and continuation, loop mode, arbitration, the MC68010's own instructions, exact clock counts | 15 testbenches |
| **Real programs** | `make programs` — flat images built with `m68k-linux-gnu` and run to completion, self-checking; sequences long enough for carried state to be what breaks | 6 programs, incl. C at `-Os` |
| **Co-simulation** | `make cosim` compares PC, SR and all sixteen registers against Musashi before every instruction | **93991 instructions, every register the same** |
| **A second core** | `make suska` runs the Suska WF68K10, an unrelated VHDL MC68010, under ghdl and compares bus transactions | 79 data accesses, same addresses, same order |

Plus the ones that ask whether any of it can be built: every module elaborates
under **iverilog, Verilator, yosys, Vivado, Quartus and Questa** — the
intersection of what those six accept is the language this project is written
in, `make lint` runs the three that need no vendor installation — and
`make audit` proves, in the source *and* in the yosys netlist, that not one of
1385 flip-flops initialises outside reset. Exactly one register is exempt — the
microcode store's read register, which a block RAM keeps inside the primitive —
and the audit names it, explains it, and fails if a second one appears.

**AC timing is decided, not measured.** An RTL model has no analogue delays, so
section 10's nanosecond limits cannot be measured from it. They can still be
answered: the limits split into a budget on each pad delay and a set of required
separations between pins, and "is there any assignment inside the budget meeting
every separation" is a system of difference constraints with an exact answer.
`make timing` runs it. This design is conformant at all six speed grades with 22
to 45 ns of room on the binding constraint.

### Bugs this found

Worth listing because each was found by exactly one thing and would have
survived everything else — and eight of them by something outside the five: the
AC-timing work, a real machine, someone reading the source, and asking what the
tests did not cover:

- A faulted write did not record its data output buffer, so a handler completing
  the access itself read the *previous* write's — found by a program, not by a
  vector.
- An address error fired again on a resumed access whose rerun flag was set.
- The MC68010's late bus error — BERR up to 80 ns *after* DTACK — was detected
  and never delivered; found by the AC-timing work.
- An autovectored interrupt acknowledge waited on the E clock, costing 15.5
  clocks; found by a real machine.
- Level 7 was recognised as a level rather than an edge, so it re-took forever.
- That edge then outlived its request by one clock, so a withdrawn level-7
  request was acknowledged as level *0* and the handler entered with the mask
  at zero; found by someone reading the RTL, after a real machine took one
  unexplained vector 24.
- The topmost word of a fault frame taken from *user* mode went to `USP-2`
  rather than `SSP-2`, carrying the supervisor function code with the user
  stack pointer's address — one microword's worth of disagreement about which
  register A7 is. Found by the same machine, this time running an operating
  system: the stray write faults inside exception processing and halts the
  CPU.
- A trace exception was taken after instructions that were never executed —
  after an illegal one, after a privileged one refused in user mode, after an
  interrupt displaced the next instruction, and after a bus error aborted one.
  Each pushed a second frame, so the *first* handler was traced instead of run.
  Found by asking which parts of the design nothing tested: the reference sweep
  skips every vector whose reference took an exception, and trace had one
  directed test.
- A longword read whose two bus cycles straddled a bus grant lost one of them.
  The bus unit decided whether to start the next cycle from the arbitration
  unit's *current* state while the output enables followed its *next* one, so on
  the single edge where the arbiter reached `ARB_GRANT` the cycle began anyway
  and then ran with its address bus in high impedance. Found by the same machine
  again, netbooting with an Ethernet controller doing DMA — a corrupted pointer
  every few thousand reads, and three different deaths from one bitstream.
- A faulted access that addressed through the address output buffer resumed at
  the wrong address. The buffer is the one thing a re-executed microword cannot
  recompute — it exists for the accesses that prefetch first and so no longer
  have the register field that named their address — and the frame build
  destroyed it before recording it, because every word of the frame is written
  through the same address-unit update that loads it. The resumed access went
  into the frame instead. Reported from the same machine as `MOVE.L Dn,-(An)`
  failing to resume; it is also every read-modify-write on `(An)`, and the
  return-address push of `JSR`, `BSR`, `PEA` and `LINK`.

---

## Layout

| Path | What |
|---|---|
| `rtl/` | the processor, one module per file, prefix `rd68011_` |
| `rtl/gen/` | generated from `tools/ucode/` — microcode store, decoder, loop table |
| `tools/` | microcode assembler, test runners, timing solvers, doc generators |
| `sim/tb/` | testbenches |
| `sim/models/` | bus-slave models |
| `sim/programs/` | real code, built and run on the core |
| `sim/suska/` | harnesses that run the same programs on the Suska VHDL core |
| `scripts/` | Vivado and Quartus synthesis, implementation, timing and path-analysis scripts |
| `doc/` | pinout, coding standard, compliance, divergence and implementation reports |
| `Inputs/` | manuals, reference implementations, external test vectors — **immutable** |

### Documentation

| | |
|---|---|
| `doc/pinout.md` | every pin, its direction, and the wrapper that makes real ones |
| `doc/bus-timing-compliance.md` | what the bus unit does on the pins, and which of section 10's 1092 limits can be checked |
| `doc/ac-timing.md` | the nanosecond conformance result, at all six speed grades |
| `doc/checkpoint.md` | the format $8 frame, the fixed register set, and why our internal words are legitimate |
| `doc/ssw.md` | the special status word, field by field, on this core and two others |
| `doc/divergences.md` | every place this does not behave as the part does, and why |
| `doc/timing-divergences.md` | every instruction whose cycle count differs, measured and justified |
| `doc/bugs-found.md` | every defect found in this design, how it was found, and what stops it coming back |
| `doc/implementation.md` | area, frequency, the reset audit, and two cautions about the numbers |
| `doc/critical-path.md` | what actually limits the frequency, with the unreachable routes excluded |
| `doc/size-and-speed.md` | making it smaller and faster: six candidates measured, four kept |
| `doc/coding-standard.md` | the portable SystemVerilog subset, every entry found by trying it |
| `doc/suska-crosscheck.md` | what a second core could and could not corroborate |

---

## Implementation

Post-route, `xc7a100tcsg324-1`, out of context, 48 ns with a 50 % duty cycle:

| | |
|---|--:|
| Clock | **48.0 ns — 20.8 MHz** |
| Setup slack | 2.048 ns |
| Slice LUTs | 6585 (10.4 % of the part) |
| Slice registers | 1342 (1.1 %) |
| DSP48E1 | 3 |
| Block RAM | 7.5 of 135 |

48 ns is the constraint every figure in this project is measured against, not
the limit: the design also closes at 44, 42 and 40 ns, and fails at 36. On a
MAX 10 `10M50DAF484C7G` the same design fits in 13749 logic elements — 28 % of
the part — and 30 M9K memory blocks, at 19.98 MHz. `doc/size-and-speed.md` has
how it got there: six candidates measured on both devices, four kept.

Two cautions, both learned here: **place and route varies more than small changes
do** — two runs differing only in the contents of one unreachable microcode word
came out 1.3 ns apart, so treat anything under about 1.5 ns as a statement about
the router. And **do not convert a slack into a frequency by dividing**: every
critical path here launches on one clock edge and captures on the next, so its
budget is half the period and both halves shrink together. The shortest period
is `T − 2 × slack`, not `T − slack`. Frequencies quoted here are measured by
re-running place and route, never extrapolated.

---

## Rules

Four, and they are not style preferences — breaking one is a bug.

**`Inputs/` is immutable.** Nothing under it may be modified, ever. New inputs
may be added, and once added they are frozen too.

**`Inputs/Suska_Configware/` is never a source for RTL.** It is another
MC68010-compatible design, in VHDL, and it is here only to validate testbenches
by being *run*. Nobody writing code in `rtl/` opens a file in it. The golden
reference is the documentation in `Inputs/doc/`.

**No initialisation outside reset.** ASIC is a target, so there is no power-on
register state: no `initial` blocks, no declaration-site initialisers on
anything that infers a register, no relying on `'x` resolving usefully. Every
register takes its value from the reset branch of its `always_ff`, and
`make audit` proves it.

**Portable SystemVerilog only.** The RTL must elaborate under iverilog,
Verilator, yosys, Vivado, Quartus and Questa. `make lint` is the gate for the
three that need no vendor installation; yosys is the strictest and therefore
defines the subset.

---

## Building

Requires iverilog 12.0, Verilator 5.032, yosys 0.52, `m68k-linux-gnu` binutils
and gcc, and — for the optional targets — ghdl, Vivado 2025.2, and Quartus
Prime Lite 25.1 with Questa Altera Starter Edition 2025.2.

```sh
make ucode      # regenerate the microcode ROMs from tools/ucode/
make lint       # elaborate every module under the three always-available tools
make audit      # prove no register initialises outside reset
make sim        # the directed testbenches
make programs   # build sim/programs/ and run them
make programs WAITS=13   # ... against slow memory, as a shared bus makes it
make cosim      # ... and against Musashi, comparing every register
make harte-all  # the whole reference sweep
make suska      # compare bus transactions against the Suska VHDL core
make timing     # AC-specification conformance
make synth impl # Vivado synthesis, then place and route
make paths      # what limits the frequency, unreachable routes excluded
make lint-questa lint-quartus   # two more front-ends, from the Altera tools
make quartus    # ... and the MAX 10 fit, for a second frequency — 19.98 MHz
make check      # the gate: ucode-check, lint, audit, sim, programs, AC timing
```

`Inputs/` holds git submodules — the manuals, Musashi, the SingleStepTests
vectors and the Suska configware — each under its own upstream licence. Clone
with `--recursive`, or `git submodule update --init` afterwards.
