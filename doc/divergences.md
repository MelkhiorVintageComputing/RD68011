# Divergences from a real MC68010

Every place RD68011 does not behave as the part does, and why. Software
compatibility is the project's first goal, so anything here is either a
deliberate decision with a reason, or a limit of what can be reproduced.

Instruction *timings* are a separate list — `doc/timing-divergences.md` — and so
is the bus-level detail, in `doc/bus-timing-compliance.md`.

## How this is checked

Four pressures, and they find different things.

**The reference vectors** are the broadest: `make harte-all` runs the
SingleStepTests through the core one instruction at a time. **The directed
testbenches** cover what the vectors cannot -- the bus protocol, the MC68010's
own instructions, faults and continuation, loop mode. **Real programs** --
`make programs`, built with `m68k-linux-gnu` and run to completion -- cover
what neither does: sequences. **`make cosim`** runs those programs against
Musashi and compares every register after every instruction, which is the same
question asked by a second implementation nobody here wrote. **`make suska`**
asks a third, in VHDL, about the bus -- `doc/suska-crosscheck.md` says what it
could and could not answer. And **`make lint`,
`make audit` and `make impl`** cover what none of them does, which is whether
any of it can be built; `doc/implementation.md` has those numbers.

The programs are worth their own note. Everything else here tests one
instruction from a fabricated state; a program is a return address surviving
three nested calls, a frame pointer still being a frame pointer after the
callee saved eight registers, a handler that does real work and returns into
the middle of the instruction that faulted, and compiler output nobody chose by
hand. Two bugs were found that way and neither could have been found the other
way:

- **A faulted write did not record its data.** The format $8 frame reports the
  data output buffer at SP+16, and a handler completing the access itself reads
  it from there. A microword that both computes the data and drives it does not
  commit when it faults, so the buffer still held the previous write's. Now the
  fault captures it.
- **An address error fired again on a resumed access.** With the rerun flag set
  the access has been done in software and is not repeated, but the odd-address
  check was still looking at it. UM 6.3.10 says as much in the other direction:
  "if the RR flag is not set, the fault address is used when the cycle is
  retried, and another address error exception occurs".

### Co-simulation against Musashi

`make cosim` runs each program on the core and on Musashi -- an
instruction-set simulator written by somebody else from the same manuals -- and
compares the program counter, the status register and all sixteen registers
before every instruction. **93991 instructions, every register the same.**

An ISS has no bus cycles, no prefetch pipe and no cycle counts, so it says
nothing about the half of this project that is bus behaviour. What it is good
for is being independent: it was not derived from the vectors this design was
built against, so where the two agree, two different readings of the manual
agree.

Two things are excluded, and the comparator prints how often each mattered:

- **The condition codes PRM section 4 marks undefined** -- N and V after ABCD,
  SBCD and NBCD. Each trace line carries the opcode so the mask is applied
  exactly where the manual says undefined and nowhere else. 469 of 93991.
- **The condition codes at reset**, which UM 5.5 does not define either. Every
  program sets them with its first instruction, so this is one line each.

One real disagreement came out of it, and the vectors settle it:

| | |
|---|---|
| **BCD on digits that are not valid BCD.** `NBCD` of $FF with X set gives $9A and a carry here, and Musashi leaves the operand alone with no carry. | The operation is only defined for BCD operands, so this is outside the manual -- but it is not outside the hardware, and the reference vectors have 161 invalid-digit NBCD cases which this design matches every one of. The whole BCD model was fitted to those vectors before any of it was written; `rtl/rd68011_alu.sv` has the derivation. Musashi is the outlier. `sim/programs/p05_stress.S` therefore feeds the BCD chain valid digits, so that what is compared is the carry propagating along it rather than an answer to a question nobody asked. |

### The Suska cross-check

`Inputs/Suska_Configware/68K10/` is another MC68010-compatible design, and
CLAUDE.md allows it to be run to validate testbenches and never read to write
RTL. `make suska` runs it. Its transaction list agrees with ours -- 79 data
accesses at the same addresses in the same order and the same sizes -- which
independently confirms the addressing modes.

What it could not do is corroborate the bus *timing*, which was the hope: its
bus cycle is two clocks with AS asserting on a falling edge where the manual's
is four with AS asserting on a rising one. `doc/suska-crosscheck.md` has the
measurement, the two places it diverges, and what pins the timing down instead.

### The vector sweep

`make harte-all` compares registers, status register, prefetch pipe, memory and
the bus transaction list.
Those vectors were generated from MAME's microcoded **MC68000**, so wherever the
MC68010 must differ, the runner does one of two things:

- **Adjusts the comparison** where the difference is well defined, so
  everything else the test checks is still checked. CLR is the case that
  matters.
- **Skips the test**, counted and reported, where the whole shape differs.

A sweep therefore reports three numbers: passed, failed, and skipped — with the
skips broken down into "not implemented" and "needing exception processing", so
a partial implementation says what is missing rather than quietly passing.

As of P6 the sweep runs **124 opcode files and 23492 tests with zero
failures**, 4442 of them address errors. Nothing is skipped as not implemented:
all 89 MC68010 instructions are built. 1308 tests remain skipped, all of them
because the reference took a group 1 or 2 exception and pushed a three-word
frame where an MC68010 pushes four.

**Address errors are compared, not skipped.** The reference records an aborted
access as a transaction kind of its own and notes that the real part never puts
it on the bus — which is exactly what this design does. So for those tests the
runner compares everything up to the fault: the bus cycles that ran before it,
and the address the fault names. That is the whole of the question an address
error asks — was it detected at the same point of the same instruction — and it
is now asked of every addressing mode of every instruction rather than of a
handful of directed cases. It is what took the skipped count from 5750 to 1308.

The exception is CLR, where neither the cycle list nor the fault address can be
compared, because the MC68010 does not make the operand read the MC68000
address-errors on: it faults one prefetch later, and on a long at base+2 rather
than at base, because the write it makes instead goes low word first. What is
still checked there is that a fault happened at all.

## MC68000 to MC68010 differences the vectors expose

These are not RD68011 divergences — they are the MC68010 behaving as it should,
against a reference that is an earlier part. Each was confirmed against the
manual and against the vectors before being relied on.

| | |
|---|---|
| **CLR does not read its operand.** UM section 9's execution times give the MC68010 two cycles fewer than the MC68000 for every memory destination. The shape is `P w`, not `r P w`. | The runner removes the reference's operand read and compares the rest. 250-odd tests per size are compared this way. |
| **MOVE from SR is privileged.** PRM section 6: on the MC68010 it traps in user mode, where the MC68000 allowed it. | Implemented. User-mode vectors for it are skipped, since the reference simply ran where this traps. |
| **Exception stack frames carry a format and vector word.** A privilege violation on the MC68000 pushes SR and PC as three words; the MC68010 pushes four. Confirmed empirically from the user-mode RESET vectors, where all 1267 of them take the trap. | Implemented, and the reason every vector whose reference took an exception is skipped -- see below. |
| **Bus and address error frames are the 29-word format $8**, not the MC68000's seven-word one. | Implemented. `doc/checkpoint.md` has the layout and the argument for the sixteen internal words; `sim/tb/core_fault_tb.sv` checks it. |
| **RTE continues a faulted instruction.** UM 5.4.1: the internal register information "is reloaded by the RTE instruction so that the MC68010 can continue execution of the instruction after the error handler routine completes". The MC68000 cannot do this at all. | Implemented, including the rerun flag: a handler that completed the access itself sets it and the access is not repeated. |
| **A bus error on an interrupt acknowledge is a spurious interrupt** (UM 6.3.4), with a short frame and vector 24 rather than the bus error vector. | Implemented. |
| **`MOVEC` traps on an unknown control register.** Only $000 SFC, $001 DFC, $800 USP and $801 VBR exist on this part; PRM section 6's note 1 makes any other code an illegal instruction. | Implemented: the decode is hardware, so the microcode tests one condition rather than branching four ways. |
| **New instructions**: `BKPT`, `MOVEC`, `MOVES`, `RTD`, and the `SFC` and `DFC` registers. | Implemented. The MC68000 vectors have nothing to compare them against, so they are covered by `sim/tb/core_m68010_tb.sv` instead. |
| **`BKPT` runs a breakpoint acknowledge cycle** -- CPU space, function codes all ones, zeros on every address line -- and then takes an illegal instruction exception however that cycle ended (PRM section 4). The MC68000 runs no cycle at all. | Implemented and checked by function code, not by cycle index. |
| **`MOVE from CCR`** is an MC68010 addition and has no MC68000 vectors at all. | Implemented; the sweep has nothing to compare it against, so it is covered by the directed tests. |
| **`VBR`** relocates the vector table; the MC68000 always used address zero. | Implemented. Reset clears it, as UM 5.5 requires. |
| **`RTE` checks the frame format** and traps to vector 14 on a code it does not recognise (UM 6.4). | Implemented for format $0; format $8 arrives in P6. |
| **Loop mode** (UM appendix A): a DBcc whose displacement is minus four and whose target is a one-word loop mode instruction stops fetching altogether. | Implemented, and checked by `sim/tb/core_loop_tb.sv` -- which asks the question that matters as a negative one: once the loop is running, no cycle in program space happens at all. |

### How the sweep tells an exception apart

A vector whose reference took an exception cannot be compared at all: the
MC68000 pushed three words where an MC68010 pushes four, so the supervisor
stack pointer ends six bytes lower instead of eight and every word of the frame
is somewhere else.

The runner detects that from the reference's own transaction list rather than
from a list of opcodes -- three words pushed, then a longword read from the
vector table down in low memory. Doing it that way lets the *non*-trapping
cases of CHK and TRAPV through to be checked normally, which a list of opcodes
would have thrown away with the rest.

## Deliberate divergences

| | Why |
|---|---|
| **The E clock's power-on phase.** UM 3.7 says the ring counter "may come up in any state. (At power-on, it is impossible to guarantee phase relationship of E to CLK.)" Ours starts from a defined reset state. | Deterministic simulation is worth more than reproducing an indeterminacy, and no correct system can depend on the phase. |
| **`rst_n` is not an MC68010 pin.** It is a hardware initialisation input that gives every register a defined value. | ASIC is a target, so there is no power-on state. The architectural reset — RESET and HALT asserted together, vector fetch from $000000 and $000004 — is a separate sequence on the real pins, and is implemented. |
| **The format $8 frame's 16 internal words use our own encoding**, stamped with our own version number. | This is what the architecture asks for. UM 6.4: the first internal word carries "a processor version number (in bits 10-13) and proprietary internal information that must match the version number of the MC68010 attempting to read the data", and RTE must raise a format error when it does not match. Software that saves and restores a frame — which is every operating system — cannot tell the difference. Software that synthesises internal words from scratch was already not portable between MC68010 versions. `doc/checkpoint.md` has the full argument. |
| **The address bus stays driven between bus cycles.** UM 5.1.1, 5.1.2, 5.1.3 and appendix B all say it goes to high impedance at the end of a cycle; table 3-4 and figure 5-3 say it stays driven. | The manual contradicts itself. Table 3-4 is followed by default because that is what systems built around this part rely on; the `ADDR_HIZ_BETWEEN_CYCLES` parameter selects the other reading. `doc/bus-timing-compliance.md` has both citations. |
| **Nanosecond output delays are not modelled in the RTL.** | An RTL model has no analogue delays, so those limits cannot be *measured* from it. They can still be *decided*: `make timing` asks whether any assignment of pad delays within section 10's own budget satisfies every required separation between pins, which is an exact question with an exact answer. This design is conformant at all six speed grades. `doc/ac-timing.md` has the numbers, and the skew envelope a real implementation would have to hold to. |
| **The order the four words of a format $0 frame are written in.** They go out from the top of the frame down: the format word, the low half of the program counter, its high half, then the status register. | No available reference records the order for an MC68010 -- the vectors are an MC68000 with a different frame -- so this one was chosen rather than measured. The resulting memory is exactly what UM figure 6-6 specifies, which is what software sees; only a bus analyser could tell the difference. |
| **CHK's Z, V and C flags.** PRM section 4 leaves all three undefined and defines N only for the two trapping cases. This takes the flags from the first bound test and leaves the second alone. | Undefined is undefined, but matching something real is better than matching nothing: this is what the reference does, and it is what the sweep checks against. |

## Not yet implemented

Nothing. Every instruction, every exception and both of the MC68010's own
mechanisms -- instruction continuation and loop mode -- are built, the design
places and routes on a named part at 16.9 MHz, and no register in it
initialises outside reset. `doc/implementation.md` is the record.

## Deliberate divergences added in P7

| | Why |
|---|--- |
| **Table A-1 is read as "every one-word instruction whose memory operands use only (An), (An)+ and -(An)"**, which admits MOVE (Ay)+ to (Ax)+ -- a cell table A-1 omits and table 9-3 gives a cycle count for. | The two tables disagree, and the page is the most OCR-damaged in the manual. A missing row in a scanned list is a likelier explanation than one arbitrary hole in an otherwise complete matrix, and table 9-3 having a number in the cell settles it. The hole both tables agree on -- a register source to -(Ax) -- is kept. The list is generated from `tools/ucode/program.py` into `rtl/gen/rd68011_loop_rom.sv`, so it can be read and argued with. |

## Deliberate divergences added in P6

| | Why |
|---|--- |
| **The order the twenty-nine words of a format $8 frame are written in.** From the top of the frame down, the stack pointer pre-decrementing by two, which is the same direction the four-word frame is written in. | No reference records the order for an MC68010, and the resulting memory is exactly what UM figure 6-8 specifies. Only a bus analyser could tell, and the same argument already covers the short frame. |
| **The three reserved words of the frame are stepped over, not written.** | UM figure 6-8's own note: "The stack pointer is decremented by 29 words, although only 26 words of information are actually written to memory." |
| **The sixteen internal words carry our own encoding**, listed in `doc/checkpoint.md`. | This is what UM 6.4 asks for, and the version number in bits 10-13 of the first of them is the architecture's own mechanism for saying so. A frame stamped with another implementation's number is refused with a format error, exactly as the manual prescribes. |
| **The program counter a fault stacks is the prefetch pointer.** UM 6.3.9.2 says only that it "may be advanced by as many as five words" beyond the instruction. | It is the value RTE has to put back for the instruction to carry on, so it is the one that is saved. Any value within the range the manual allows is conformant, and this one is the useful one. |

## Deliberate divergences added in P5

| | Why |
|---|--- |
| **`MOVES.x An,(An)+` and `MOVES.x An,-(An)` store the *unmodified* register.** PRM section 6 calls the value stored undefined for these, and adds that the MC68010, MC68020, MC68030 and MC68040 store the incremented or decremented one. Measured here: `MOVEA.L #$4000,A0; MOVES.L A0,(A0)+` stores $00004000 where a real MC68010 stores $00004004. | The architecture leaves it undefined, and matching it would cost a microword: the write data leaves the register file at the start of the bus cycle, and the address unit's update lands at the end of it. Software that depends on this was already not portable across the family -- the manual's own advice is to run the sequence and find out. Pinned by `sim/tb/core_m68010_tb.sv` so it cannot drift silently. |
| **MOVEM's transfer order within a register list is the mask's**, lowest bit first, and to `-(An)` the mask is read the other way round. | This is what PRM section 4 specifies and what the reference vectors show; it is recorded here only because it is the part of MOVEM most easily got backwards. |

## What is implemented and passing

All 89 instructions, across 124 opcode files at zero failures: MOVE and MOVEA
at all three sizes
and every addressing mode, MOVEQ, TST, CLR, NEG, NEGX, NOT, the ALU group
(ADD, SUB, AND, OR, EOR, CMP) in both directions, ADDA/SUBA/CMPA, the immediate
group, ADDQ and SUBQ, EXT, SWAP, LEA, PEA, Scc, TAS, the four bit operations in
both their dynamic and static forms -- BTST including the immediate
destination that PRM section 4 gives it and nothing else in the group -- and
all twenty-four shift and rotate variants; Bcc, BSR, DBcc, JMP, JSR, RTS, RTR,
LINK and UNLK; TRAP, TRAPV, CHK, ILLEGAL, line A and line F, privilege
violations, trace, and interrupts with both the autovectored and the vectored
acknowledge; MOVE to and from SR and CCR, the immediate-to-SR and to-CCR forms,
MOVE USP, RESET, STOP and RTE; MULU, MULS, DIVU, DIVS, the BCD group, ADDX,
SUBX, CMPM, EXG, MOVEM and MOVEP; and the MC68010's own MOVEC, MOVES, RTD and
BKPT.

The exception frame itself, the vector table, RTE's format check, the interrupt
priority against the mask, trace, and waking from STOP are covered by
`sim/tb/core_exception_tb.sv` instead of by the sweep, for the reason above.
RTD, BKPT, MOVEC and MOVES are covered by `sim/tb/core_m68010_tb.sv`, because
an MC68000 reference has no vectors for instructions it does not have.

The format $8 frame, RTE reloading one, and everything that continues a faulted
instruction are covered by `sim/tb/core_fault_tb.sv`, for the same reason: an
MC68000's fault frame is seven words with no internal state in it at all.

And all of it is covered again, in sequence, by the programs under
`sim/programs/`: nested calls and compiler-shaped stack frames, exception
handlers that adjust their own frame and return, a bus error handler that
completes the access itself the way UM 6.3.9.2 describes, and a C program at
-Os with the register allocator's choices rather than anyone's. What
the sweep does check about faults is the half that does compare -- where an
address error is detected, on which cycle of which instruction, across 4442
tests.
