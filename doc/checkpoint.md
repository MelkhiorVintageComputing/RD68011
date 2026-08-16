# The checkpoint register set

The MC68010's reason for existing is that a bus error can be recovered from.
UM 5.4.1: "The MC68010 stacks the frame format and the vector offset followed by
22 words of internal register information. The return from exception (RTE)
instruction restores the internal register information so that the MC68010 can
continue execution of the instruction after the error handler routine
completes."

That one sentence constrains the whole microarchitecture. Every scrap of state
an instruction accumulates has to live somewhere the format $8 frame can save
and RTE can reload — which means the working registers must be a **fixed, named
set**, not whatever a given piece of microcode finds convenient. This document
freezes that set. It is written in P2, before the instructions exist, because
retrofitting it after the datapath is built is the single largest risk in the
plan.

## The frame — UM figure 6-8

29 words, of which only 26 are written; three are reserved.

| Offset | Contents |
|---|---|
| SP+0 | status register |
| SP+2 | program counter, high |
| SP+4 | program counter, low |
| SP+6 | `1000` and the vector offset — format $8 |
| SP+8 | special status word |
| SP+10 | fault address, high |
| SP+12 | fault address, low |
| SP+14 | unused, reserved |
| SP+16 | data output buffer |
| SP+18 | unused, reserved |
| SP+20 | data input buffer |
| SP+22 | unused, reserved |
| SP+24 | instruction input buffer |
| SP+26 … SP+56 | **internal information, 16 words** |

The special status word (UM figure 6-9) is the machine-readable description of
the faulted cycle:

| Bit | Meaning |
|---|---|
| 15 `RR` | rerun flag: 0 = the processor reruns the cycle, 1 = software already did |
| 13 `IF` | the access was an instruction fetch, to the instruction input buffer |
| 12 `DF` | the access was a data fetch, to the data input buffer |
| 11 `RM` | the access was part of a read-modify-write |
| 10 `HB` | high-byte transfer — set when MOVEP faulted moving bits 8–15 or 24–31 |
| 9 `BY` | byte transfer; clear means word |
| 8 `RW` | 1 = read, 0 = write |
| 2:0 | the function code the faulted access used |

Note what the saved PC is not: UM 6.3 warns it "does not necessarily point to
the instruction that was executing when the bus error occurred, but may be
advanced by as many as five words", precisely because of the prefetch mechanism
this design already implements.

## Why our own encoding of the internal words is legitimate

This was a decision taken up front — emit a correct-shape format $8 frame whose
16 internal words use our encoding, so that our own RTE continues a faulted
instruction correctly. It turns out the architecture explicitly anticipates
exactly this. UM 6.4, on how RTE validates a long frame:

> The only word checked for validity is the first of the 16 internal
> information words (SP + 26) [...]. This word contains a processor version
> number (in bits 10-13) and proprietary internal information that must match
> the version number of the MC68010 attempting to read the data. [...] If the
> version number is incorrect for this processor, the RTE instruction is
> aborted and exception processing begins for a format error exception.

So Motorola's own contract is: the internal words are private, they are
version-stamped, and a processor that does not recognise the stamp must refuse
the frame rather than misinterpret it. Software that saves a frame and later
restores it — which is what every operating system does — cannot tell the
difference. Software that synthesises internal words from scratch was already
not portable across MC68010 versions.

RD68011 therefore carries **its own version number** in bits 10–13 of the word
at SP+26 and refuses any frame that does not carry it, with a format error
(vector 14), exactly as the manual prescribes. `doc/divergences.md` records
this; the choice of number is in `rtl/rd68011_pkg.sv`.

## The set

Frozen as of P2. Anything an instruction needs to carry across a bus cycle goes
here or it does not exist.

### Implemented (`rtl/rd68011_seq.sv`), as of P5

| Register | Width | What it holds | Where it lands in the frame |
|---|--:|---|---|
| `upc` | 13 | the micro-address to resume at | internal |
| `pc` | 32 | next prefetch address | derived, see the budget |
| `ir` | 16 | the opcode being executed | internal |
| `irc` | 16 | the next word, already fetched | **instruction input buffer**, SP+24 |
| `ir_pc` | 32 | the address `ir` came from | **SP+2**, the frame's own PC |
| `irc_pc` | 32 | the address `irc` came from | internal |
| `t0` | 32 | working register / effective address | internal |
| `t1` | 32 | working register / operand | internal |
| `ea_latch` | 32 | the address output buffer | internal |
| `dbuf` | 32 | the data output buffer, both halves | low half is **SP+16**; high half internal |
| `xw` | 16 | the extension-word latch: MOVEM's remaining register mask, and MOVEC's and MOVES's register-and-direction word | internal |
| `sr` | 16 | status register | **SP+0** |

### Not checkpointed, and why

| | |
|---|---|
| `sfc`, `dfc` | Architectural registers, not per-instruction state. A fault does not change them and RTE does not have to put them back; MOVEC is what writes them. |
| the divider's `q`, `rem`, `den`, `count`, `neg_q`, `neg_r`, `signed_r` | A division does no bus cycle, so it cannot fault. The microcode waits on `busy` and only then goes near memory. |
| `vbr`, `usp`, `ssp`, `regs` | Architectural. |

### Reserved for the phases that need them

| Register | Width | Arrives in | For |
|---|--:|---|---|
| `fault_addr` | 32 | P6 | SP+10 — the address of the faulted cycle |
| `ssw` | 16 | P6 | SP+8 — assembled from the in-flight cycle descriptor |
| `loop_state` | small | P7 | loop mode (UM appendix A) |

### The budget

The 16 internal words are 256 bits, and they are all there is.

Spoken for after P5: `upc` 13, `ir` 16, `irc_pc` 32, `t0` 32, `t1` 32,
`ea_latch` 32, `dbuf` high half 16, `xw` 16 — **189 bits**, plus 4 bits of
version number. That leaves about 63 bits, or four words, for the in-flight
cycle descriptor and loop-mode state.

Two things keep it inside the budget, and both are worth stating because they
are load-bearing:

- **`pc` is not saved.** The prefetch pipe maintains `pc = irc_pc + 2` at every
  point — a fetch sets `irc_pc` to `pc` and then advances `pc` by a word, and
  nothing else moves either — so saving `irc_pc` saves both. `tools/harte/
  model_check.py` is what makes that an invariant rather than a hope.
- **`ir_pc` is not in the internal words** because it is the frame's own
  program counter at SP+2.

P5 spent 96 bits of the margin the P2 estimate left (`ea_latch`, the high half
of `dbuf`, and five more bits of `upc` than were budgeted, against a 32-bit
saving from not storing `pc`). It still fits, which is what this document
exists to keep true; P6 is where it is spent.

## Rules this imposes on the microcode

1. **No state outside the set.** A microword may not stash a value anywhere but
   the registers above. If a sequence needs a third temporary, the answer is to
   restructure it or to add a register here — with the budget recomputed.

2. **A bus cycle is a checkpoint.** The fault can only happen during a bus
   cycle, so the state at the *start* of each bus-cycle microword must be
   sufficient to resume from. In practice this means a microword must not
   depend on a value that a previous microword computed and then destroyed.

3. **A read-modify-write is atomic to the fault handler.** UM 5.4.2 and 6.3:
   the whole cycle is rerun whether the fault hit the read or the write, so the
   microcode must be able to restart a TAS from its first microword with the
   original operand address intact — which is why the address lives in `t0` and
   is not consumed.

4. **`irc` is architectural during a fault.** It is the instruction input
   buffer the frame exposes at SP+24, so it may not be used as a scratch
   register. `xw` exists for that reason: an extension word that has to outlive
   the prefetch replacing `irc` gets copied there rather than left in place.

## Verification

P6 is where this is tested end to end, but the shape of the test is fixed now:
a `MOVEM` faulting partway through its transfer list, handled, and continued to
completion with every remaining register moved and none moved twice. If the
checkpoint set is wrong, that test cannot be made to pass by patching around it.

P5 built that instruction, and built it in the shape the test needs: MOVEM's
remaining work is exactly the contents of `xw` and `t0`, and its loop resumes
from a single micro-address. Nothing about continuing it needs a counter that
would have to be reconstructed.
