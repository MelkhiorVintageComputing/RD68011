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
| **Nanosecond output delays are not modelled in the RTL.** | An RTL model has no analogue delays, so those limits cannot be *measured* from it. They can still be *decided*: `make timing` asks whether any assignment of pad delays within section 10's own budget satisfies every required separation between pins, which is an exact question with an exact answer. This design is conformant at all six speed grades. `doc/ac-timing.md` has the numbers, and the skew envelope a real implementation would have to hold to. |
| **The order the four words of a format $0 frame are written in.** They go out from the top of the frame down: the format word, the low half of the program counter, its high half, then the status register. | No available reference records the order for an MC68010 -- the vectors are an MC68000 with a different frame -- so this one was chosen rather than measured. The resulting memory is exactly what UM figure 6-6 specifies, which is what software sees; only a bus analyser could tell the difference. |
| **CHK's Z, V and C flags.** PRM section 4 leaves all three undefined and defines N only for the two trapping cases. This takes the flags from the first bound test and leaves the second alone. | Undefined is undefined, but matching something real is better than matching nothing: this is what the reference does, and it is what the sweep checks against. |

## A bug the AC-timing work found

**The MC68010's late bus error was detected and never delivered.** Specification
48\* -- the only line in section 10 that names this part alone -- lets the system
assert BERR up to 80 ns *after* DTACK at 8 MHz and requires the processor to
fault the cycle anyway (UM 5.4.1, table 5-1 cases 4 and 6). Measured on the whole
processor, this design accepted 7.5 ns of that 80.

The bus unit recognised every late bus error and told nobody. It set `end_code`
to `CE_BERR`, which reaches the sequencer through `req_end` -- a clock later than
a microword can act on, as `rd68011_biu.sv`'s own port comment says. The signal
the sequencer keys off, `req_fault`, was driven only by the early-BERR path. So
`req_fault` never rose and no late bus error was ever taken.

`sim/tb/bus_error_tb.sv` case 4 passed throughout, because it checked `req_end`
-- which was set -- and not `req_fault`. It now checks both, and reverting the
fix makes it fail.

Fixed with a `term_berr_late` of its own rather than by setting `term_berr`,
which would also have sent the state machine on to S9; a late bus error must
still end in S7, the transfer having already completed. The window is now
132.5 ns at 8 MHz against the 80 required. `doc/ac-timing.md` has the
measurements.

Worth recording *how* it was found, because none of the four existing pressures
could have: the reference vectors are an MC68000 and have no late bus error,
Musashi has no bus, real programs never provoke one, and the directed test
checked the wrong signal. It took asking the specification's own question --
how late may this arrive and still work -- and then taking a disagreement
between two of this project's own testbenches seriously.

## A bug a real machine found

**An autovectored interrupt acknowledge waited for the E clock.** Reported from a
Sun-2 FPGA replica: the core boots a real Sun-2 boot PROM through the whole
power-on diagnostic, memory sizing, MMU map setup and the serial banner, takes
twelve bus-error probes at exactly the addresses another core takes them at --
and then dies at the machine's first timer interrupt, on an FC=7 cycle at
`fffffe`. The machine asserts VPA for CPU space; the cycle was not terminated;
the machine's twelve-clock bus timeout fired instead, and a bus error during
interrupt acknowledge took the core apart.

Measured here rather than inferred: an autovectored acknowledge took **15.5
clocks** after VPA, where one terminated by DTACK takes two. The bus unit
treated VPA as a request for the M6800 handshake whatever the cycle was, so
`samp_done` could only be reached through `term_vpa && vma_asserted &&
e_last_high`, and the acknowledge sat in the wait loop until E came round.

**Two modes, not a contradiction, and reading it as one is how the bug got
written.** Sections 5 and 6 document the native MC68000 bus cycles and native
exception processing. Appendix B documents the M6800 compatibility mode. VPA is
a single pin doing two jobs:

- outside CPU space: *this is an M6800 peripheral*, so run the synchronous
  cycle -- assert VMA, align with E (appendix B);
- during an interrupt acknowledge: *autovector this* -- UM 5.1.4, "the
  interrupt acknowledge cycle **is the same**, except the interrupting device
  asserts VPA instead of DTACK", and UM 6.3.4, which lists DTACK, AVEC/VPA and
  BERR as the three ways to "terminate the vector acquisition".

What appendix B.2 says about VMA -- "the processor (or external circuitry)
asserts VMA and completes a normal M6800 read cycle" -- belongs to its own mode,
where an M6800 peripheral really is being addressed. It is not a description of
the native autovector, and it hedges in any case. Later parts split the pin in
two, VPA for the M6800 mode and AVEC for the native one, precisely to remove
the ambiguity the single pin carries; the manual's own "when VPA (or AVEC) is
asserted" in 5.1.4 is the same distinction showing through.

The bus unit had applied the appendix's behaviour to both jobs. Now VPA acts
where DTACK acts, on the same sampling edge, and the acknowledge is four clocks
like any other cycle. No VMA is asserted for it -- there is nothing to
synchronise, the vector being generated internally, and appendix B's own warning
about "an unintended access to the device" is reason enough not to strobe one
that was never being addressed.

`sim/tb/bus_m6800_tb.sv` had an autovector case throughout, quoting UM 5.1.4 in
its own comment, and it passed the whole time: it checked the end code, which was
correctly `CE_AVEC`, and never how long the cycle took. It now checks the
duration and that no VMA appears, and reverting the fix makes both fail.

Worth recording *how* it was found, because nothing here could have: the
reference vectors have no bus, Musashi has no bus, the directed test checked the
end code and not the clock, and no program in `sim/programs/` takes an
autovectored interrupt. It took someone running real code on a real machine's
PROM.

## A second bug the same machine found

**Level seven was recognised as a level, so it was taken for ever.** With the
acknowledge fixed, the same report came back with a bus trace: the handler is
entered correctly -- right vector number, right frame, right vector address,
right handler address -- fetches the first two words of its first instruction,
and is then interrupted again before that instruction retires. Three
acknowledges 4.8 us apart, the stack eight bytes lower each time. The
instruction that would have cleared the interrupting device never runs, so the
request stays asserted, so it happens again.

The manual does not quite say what to do here, and the gap is where the bug
lived.

- UM 3.5: "Level seven, which cannot be masked, has the highest priority", and
  "these signals must remain asserted until the processor signals interrupt
  acknowledge ... for that request to be recognized".
- UM section 6: "interrupts are inhibited for all priority levels less than or
  equal to the current priority", and processing starts only "if the priority of
  the pending interrupt is greater than the current processor priority".

Read section 6 as a comparison and level seven is inhibited the moment it is
taken, because taking it sets the mask to seven and seven is not greater than
seven -- which contradicts 3.5. Take 3.5 at its word and add level seven to the
comparison, which is what this design did, and a device that holds its request
as 3.5 instructs is acknowledged at every instruction boundary until the stack
runs down through memory.

Neither is right, because **level seven is an edge and the others are levels**.
A transition to seven is always recognised, whatever the mask -- that is what
unmaskable means -- and the line merely sitting at seven is not a new request.
Both sentences then hold at once, and a device that holds its request until the
acknowledge, as 3.5 requires, gets exactly one.

`irq7_edge` is that transition, set on the change to seven, cleared when the
interrupt it raised is taken, and read only while the line is still at seven --
a request withdrawn early is one the processor may forget rather than invent an
acknowledge for. That last clause was originally the clearing rule alone, which
is what the next section is about. Levels one to six are unchanged and still
compared against the mask.

`sim/tb/core_exception_tb.sv` holds the line at seven and checks that the
handler's first instruction actually runs and that only one frame is pushed.
Putting the level test back fails it twice over, and instructively: the store
never happens, and the sentinel eight bytes below the frame comes back as
`0x2700` -- the status register of a second frame, the stack already on its way
down.

The first report's `0x7C2700` turned out to be this too, at one remove. The
stack descends eight bytes per acknowledge; after some hundreds of passes it
reaches the vector table and the pushed frame overwrites it, and the next vector
fetch reads back the frame that was just written there -- the format word
`0x007C` and the status register `0x2700` -- and the core jumps to `0x007C2700`.
A correct vector read of a vector table the runaway stack had already eaten.

## A third bug, in the edge that fixed the second

**The edge outlived its request by one clock, and the interrupt was then taken
as level 0.** Reported from outside the project, found by reading rather than by
simulating, and prompted by a single unexplained vector 24 on a machine whose
only always-unmasked source is at level seven -- taken at an arbitrary point in
a program that had just lowered the interrupt mask for the first time.

`irq7_edge` is cleared in a clocked block and read combinationally, so for one
clock it described a request that had already gone. The level is sampled in that
same clock, from the same `irq_level`:

```systemverilog
assign irq_pending = irq7_edge || (irq_level > sr[SR_I0+2 -: 3]);
...
if (commit && take_irq) irq_taken <= irq_level;
```

so an interrupt taken in that clock latched the level it read, which was zero.
The edge is the only route to a zero there: the other term requires
`irq_level > mask`, hence at least one. Three things followed, in increasing
order of harm -- an acknowledge with `A3-A1 = 000`, an autovector of `24 + 0`,
which is the spurious vector's number reached by a route that is not spurious
interrupt, and a handler entered with the mask at **zero**, so interruptible by
everything including the level that raised it. The part can do none of the
three: it commits to a level and acknowledges *that* level, and a request
withdrawn afterwards gives a spurious interrupt, never a different one.

**And a second defect in the same three lines**, which the report did not
mention. The chain set the flag before it could clear it:

```systemverilog
if      (irq_level != 3'd7)                         irq7_edge <= 1'b0;
else if (irq_prev != 3'd7)                          irq7_edge <= 1'b1;   // wins
else if (commit && take_irq && (irq_level == 3'd7)) irq7_edge <= 1'b0;
```

With the mask below seven the *level* term takes the request in the very clock
the line first reads seven -- which is also the clock the transition is seen, so
arm two fired and the flag survived the acknowledge that answered it. The
handler's first instruction boundary then took a second interrupt for the one
request: two frames, two acknowledges. That is the previous section's failure
arriving by the other door, in the one case its test does not cover -- it enters
with the reset mask of seven, so the level term never fires there.

Both are one-clock races. `STOP` makes them certain rather than narrow: with no
bus cycle in flight every clock retires, and `STOP` is an interrupt point, so
every stopped clock is a chance to take one. That is what makes them testable.

The fix is two lines. The edge is qualified by the line, so it is a condition on
the request being there now rather than a memory of it having been:

```systemverilog
assign irq_pending = (irq7_edge && (irq_level == 3'd7)) ||
                     (irq_level > sr[SR_I0+2 -: 3]);
```

and taking the interrupt comes first in the clearing chain, ahead of setting it.
The first also closes the general case where the line drops from seven to a
level at or below the mask: the stale edge used to take that level and lower the
mask to it.

`sim/tb/core_exception_tb.sv` has three cases: a one-clock level-seven pulse
against a stopped core with the mask at seven, which must leave it stopped and
run no cycle at all; the same pulse against a running core, swept across twelve
phases of a `NOP` loop so an instruction boundary lands in the window; and a
held level-seven request arriving while the mask is zero, checked by the
sentinel eight bytes below the one frame it may push. Before the fix the first
parks the core in the vector-24 handler with the mask at zero, two of the twelve
sweep offsets do the same, and the sentinel comes back as `0x2700`.

The permanent guard is in `sim/tb/rd68011_core_harness.svh` rather than in a
test: whenever an interrupt is taken, the level must be seven or above the mask.
That is the whole rule, stated once, and being in the harness it holds for every
directed test, every reference vector, every program and every co-simulated
instruction. It is not in `rtl/` because `rtl/` carries no assertions and has to
elaborate under yosys and Vivado as well.

## A fourth bug the same machine found

**The topmost word of a fault frame went to the user stack.** Reported from the
same Sun-2 replica, now running SunOS 4.0.3 rather than the boot PROM, and dying
every time at the first instruction of `/sbin/init` with nothing on the console
but `Watchdog reset!`.

The kernel deliberately runs a brand-new process in the kernel's own MMU context
so that its first access faults and the handler can allocate one. That intended
bus error is taken from user mode. Of the twenty-nine words of the format $8
frame, twenty-eight went to the supervisor stack and the first one -- the word
at `SP+56`, written first because the frame is written top down -- went to
`USP-2`. On a demand-paged system the page under a fresh process's stack pointer
is usually not present, so the stray write faults *inside* exception processing:
double bus fault, halt, watchdog.

The fingerprint was on the bus, and it names the cause exactly:

```
A=100000 FC=1 RW=0      the faulting user data write
A=02fffe FC=5 RW=0      the first frame word: USP-2, with the supervisor code
A=000fe0 FC=5 RW=0      the rest of the frame, correctly on the SSP
```

One cycle carrying the supervisor function code and the user stack pointer's
address. The function code and the address come from different places.

Everything in a bus request is built from the *next* microword, because the bus
unit latches the whole request on the edge that ends the previous cycle --
`rd68011_seq.sv` says so in a comment above the block that does it, and the
function code follows the rule: it is derived from `sr_nxt`, deliberately, with
`MOVE to SR` named as the case where it shows. The address register the next
microword indexes through was the one field that did not: `n_ea_base` read the
register file through `RDREG`, and `RDREG` resolves index 15 to `sr[S] ? ssp :
usp` -- the S bit as it is *now*.

For every other microword pair those two agree. Exception entry is the pair
where they do not. `fault_exception()` in `tools/ucode/program.py` sets S in one
microword and issues the first frame push in the very next one, so the push's
address is computed while `sr[S]` is still the user-mode zero, and its function
code while `sr_nxt[S]` is already one. From the second push onward `sr[S]` has
caught up and everything agrees, which is why exactly one word is misplaced.

The stack pointers show nothing afterwards. The write-back of the pre-decrement
happens on the push microword itself, where `sr[S]` is already one, so the
*supervisor* stack pointer takes `SSP0-2` and the second push lands where it
should. `USP` is never written. Only the memory under the user stack is a
witness -- and the first version of the reporter's own test compared the two
stack pointers, found them right, and declared the core correct.

**Only the two faults, not every exception.** The report's scope said trap and
interrupt too. They are not affected, and the tests now say so rather than
leaving it argued: the four-word frame of `exception_tail()` has a microword
between the one that sets S and the first bus cycle -- the one that reserves
eight bytes -- and the pushes after it address through the latched effective
address, not through A7. Only `fault_exception()`, which both faults share, puts
a bus cycle directly after the S bit.

The fix is one field, and it is the field being brought into line with the
comment already above it: `n_ea_base` resolves index 15 through `sr_nxt[S]`,
like the function code beside it. The two bypasses that hand the next microword
a value this edge is writing are guarded to the case where the bank has not
changed underneath them -- a write to A7 goes to whichever bank `sr[S]` names,
so it is only the value the next microword reads if the next microword reads the
same bank. No microcode today writes A7 and changes S in one microword; `RTE`
restores the status register in its last microword for exactly this reason, and
says so in its own comment.

`sim/tb/core_fault_tb.sv` takes a bus error and an address error from user mode
with the two stack pointers 8 kB apart, paints the eight words under the user
stack, and checks three things: that the first supervisor-space write of the
frame is at `SSP-2`, that the painted words are untouched, and that `USP` did
not move. Four of those checks fail before the fix.
`sim/tb/core_exception_tb.sv` does the same for an interrupt taken in user mode,
beside the `TRAP` case already there; both pass before the fix, which is the
point of them.

No harness invariant. "A frame word went to the wrong stack" is only visible if
you know where the other stack is, and nothing at the pins does.

## Four bugs in one register, found by asking what was untested

**A trace exception was taken after instructions that were never executed.**
Nobody reported these. They came out of asking whether the reproduction written
for a faulted prefetch had siblings -- what else the tests did not reach. The
answer was the whole exception surface:
the sweep skips every vector whose reference took an exception, for the reason
in *How the sweep tells an exception apart* above, so exceptions are checked by
directed tests alone -- and trace had exactly one, a traced `NOP`.

UM 6.3.8 is the entire specification of when the trace exception happens, and it
is one paragraph:

> If the T bit is set (on) at the beginning of the execution of an instruction,
> a trace exception is generated after the instruction is completed. If the
> instruction is not executed because an interrupt is taken or because the
> instruction is illegal or privileged, the trace exception does not occur. The
> trace exception also does not occur if the instruction is aborted by a reset,
> bus error, or address error exception. If the instruction is executed and an
> interrupt is pending on completion, the trace exception is processed before
> the interrupt exception. During the execution of the instruction, if an
> exception is forced by that instruction, the exception processing for the
> instruction exception occurs before that of the trace exception.

Every "does not occur" in it was wrong here. Measured on the core, both frames
read out of memory:

| under trace | was | should be |
|---|---|---|
| `ILLEGAL`, line A, line F | the illegal frame, **then a trace frame** | one frame |
| a privileged instruction in user mode | the privilege frame, **then a trace frame** | one frame |
| an interrupt taken instead of the next instruction | the interrupt frame, **then a trace frame** | one frame |
| an instruction aborted by a bus error | the format $8 frame, **then a trace frame** | one frame |

In each case the second frame's program counter is the *first* handler's own
entry point: the debugger's trace handler ran in place of the illegal-instruction
handler, the interrupt handler and the bus-error handler, before any of them
executed a single instruction. For a monitor that single steps, that is the
mechanism it is built on failing exactly where it is needed.

One line behind all four (`rtl/rd68011_seq.sv`):

```systemverilog
if (commit && (f_seq == U_SEQ_DECODE))
  trace_armed <= take_trace ? 1'b0 : sr_nxt[SR_T];
```

`trace_armed` says the instruction now running began with T set. It was armed at
every instruction boundary and disarmed only by the trace itself, so nothing
cancelled it when the instruction that followed never ran -- the arming outlived
the instruction it belonged to and was spent on the handler instead.

The fix is that same assignment written out as the four cases the manual gives:
`fault` cancels it, a microword carrying the new `notrace` bit cancels it, an
interrupt at a boundary cancels it, and `U_SEQ_RESUME` -- `RTE` picking a
faulted instruction back up -- restores it from the status register the frame
saved, which is the T the instruction was running under. `trace_armed` therefore
needs no place of its own in the sixteen internal words; `doc/checkpoint.md`
records why.

The `notrace` bit is set by `raise_exception()` in `tools/ucode/program.py` at
exactly four call sites -- illegal, line A, line F and privilege violation --
because only the microcode knows which exception it is taking. The other six
call sites keep the arming deliberately: `TRAP`, `TRAPV`, `CHK` and divide by
zero are exceptions the instruction *forced*, which the same paragraph puts
before the trace and not instead of it.

**What the reference can say.** It cannot compare these, but it can be counted:
of the `ILLEGAL_LINEA` vectors with T set, 1319 of 1319 push six bytes, which is
one frame and not two; `ILLEGAL_LINEF`, 1232 of 1232; `STOP` and `RESET` with T
set in user mode, six bytes likewise.

**Two things were already right**, and are now pinned in
`sim/tb/core_exception_tb.sv` rather than left to be assumed: a traced `TRAP #3`
pushes the trap frame and then the trace frame, and an instruction that
completes under trace with an interrupt waiting is traced first and interrupted
second. The second is the ordering table 6-1 gives, and nothing had ever
exercised it.

### And a `STOP` under trace now traces instead of stopping

PRM section 6, `STOP`: "A trace exception occurs if instruction tracing is
enabled (T0 = 1, T1 = 0) when the STOP instruction begins execution." This
design used to load the status register and stop for ever, because `take_trace`
was an instruction-boundary test and a `STOP` never reaches another boundary --
`take_irq` had the extra term and `take_trace` did not. Single stepping into a
`STOP` never came back.

`take_trace` now carries the same `STOP` term. The program counter the frame
gets is the interrupt path's, `IRQPC`, because a `STOP` does no prefetch and
`ir_pc` is still the `STOP`'s own address; the flag that selects it was called
`irq_from_stop` and is now `exc_from_stop`, set for either exception.

The MC68000 vectors show **no** frame for this: `STOP` with T and S set ends
with the stack untouched in all 598 of them. They do not contradict the PRM so
much as stop earlier. A vector records one instruction, and a trace exception
belongs to the boundary *after* it, which is where both the reference and
`sim/tb/harte_tb.sv` stop looking -- the sweep never sees a trace exception
anywhere, and `RESET` with T set in supervisor mode says the same thing in the
same way, 617 vectors of it. `harte_tb` counts the stopped microword as an
instruction boundary so that a `STOP` is captured like any other instruction, so
the sweep neither notices this change nor fails on it. The manual in `Inputs/doc/` is the golden reference and it is explicit, so
it is followed; the check is `sim/tb/core_exception_tb.sv`'s traced `STOP`, which
asserts the vector 9 frame with the instruction *after* the `STOP` in it.

### Where the tests are

`sim/tb/core_exception_tb.sv`, beside the traced `NOP` that was the only one:
traced `ILLEGAL`, line A and line F; a traced privileged instruction; an
interrupt that displaces a traced instruction; the two orderings above; and the
traced `STOP`. `sim/tb/core_fault_tb.sv` has the fourth cancel -- a traced
instruction aborted by a bus error, whose handler must run untraced -- and its
other half, that `RTE` continuing the instruction pays the trace afterwards,
because the instruction was suspended and not abandoned. Nineteen of these fail
before the fix.

There is no harness-wide invariant for this one. The rule the level-seven fix
guards -- an interrupt is legitimate only at a level above the mask -- is
visible in one line of state at the moment it is taken. "The instruction was
actually executed" is not: it is the absence of another exception, which no
single edge can see. The directed cases are the statement.

## A fifth bug the same machine found, in the seam between two bus cycles

**A longword read across a bus grant lost a word.** Reported from the same
Sun-2/50 replica, netbooting, with an Intel 82586 doing DVMA through the MMU
while the CPU runs the boot PROM. A longword read every few thousand came back
with one half replaced by something else -- almost always a pointer, because
`moveal (An),%a0` is what reads longwords -- and the machine then died three
different ways from the same bitstream: a timeout bus error at a wild address,
an illegal instruction at a PC holding ordinary code, or a double bus fault and
the watchdog. It only bites when a second bus master is active, so a machine
with no DMA never sees it.

The report eliminated the machine before blaming the core, which is what made it
worth taking at face value: 295,827 CPU reads on a full boot, every one checked
against what memory held, none wrong -- and the check made to fail first, by
re-introducing a memory-bridge bug, which turned the same boot into ten wrong
out of the same 295,827. Correct data reaching the pins, wrong data retained.

### The mechanism

A 68010 longword is two bus cycles and UM 5.2.1 lets a master have the bus
between them, so the bus unit has to decide, at the rising edge that ends S7,
whether to start the next cycle or hand the buses over. It made that decision
from `arb_bus_released`, built from the arbitration unit's **current** state.
The output enables were registered from `arb_bus_released_nxt`, built from its
**next** state -- deliberately, and `doc/bus-timing-compliance.md` explains why
that is the right choice for them.

For all but one alignment of BR the two agree. The exception is the edge on
which the arbiter itself moves from `ARB_IDLE` to `ARB_GRANT`, because that is
the same rising edge that ends S7 and starts the next cycle: the state machine
looked at `ARB_IDLE`, saw no reason not to start, and went to S0; the enables
looked at `ARB_GRANT`, saw a grant, and one clock later turned every output off.
The cycle then ran S2 through S7 with the address bus in high impedance and the
strobes released -- so nothing ever reached memory, and the word the transfer
was waiting for was whatever the bus happened to carry. On this board that is
the alternate master's data, which is why the reporter saw a plausible-looking
wrong pointer rather than an obviously dead one.

`arb_freeze` exists to prevent exactly this and does not reach it. It stops the
arbitration state machine *changing* during S0 and S1 -- the two states in which
AS is not yet asserted, so `arb_bus_released` cannot tell a cycle in flight from
an idle bus -- but it says nothing about the arbiter already being in
`ARB_GRANT` when S0 begins, and on this one edge it arrives there simultaneously.

### The fix

`arb_bus_released` is gone; there is one signal, and it is the next-state form
the output enables already used. The bus state machine now decides from it too,
so `st_p` is `ST_ARB` on exactly the clocks the outputs are released rather than
on a set of clocks that nearly matches. Everything it is built from is a
register, so feeding a next-state signal into the state machine's own next state
closes no loop.

One side effect, and it is the same inconsistency read the other way: the bus
unit used to hold `ST_ARB` for one clock after handing the buses back, so a
cycle resumed one clock later than the enables allowed. It now resumes as soon
as it may. Specifications 57 and 57A are about when the pins are *driven*, which
never changed, and `sim/tb/bus_arb_tb.sv` measures both at 2.0 clocks either way.

### What tests it

`sim/tb/core_arb_tb.sv` sweeps the grant across a whole transfer, half a clock
at a time, in both arbitration protocols, over a `MOVE.L` (one seam) and a
`MOVEM.L` of two registers (three), with an alternate master driving the data
bus while it owns it -- so a re-latch shows up as wrong data and not merely as
high impedance. Ninety-six episodes, and it counts how many actually handed the
bus over, because a sweep that never released it would pass without testing
anything.

The sweep step is the point. The defect needed BR recognised on one specific
rising edge, so it occupies exactly one clock of each seam: six of the
ninety-six episodes fail before the fix, and a sweep stepping a whole clock from
an arbitrary start would find it or miss it by luck. The three MOVEM.L seams
fail at 1, 9 and 17 half clocks, four clocks apart, which is the cycle length --
that regularity is what says the mechanism is the seam and not the instruction.

The report's own asymmetry -- "the word read before the grant is lost, the word
read after it is kept" -- is the one thing in it that does not survive. It was
offered as a lead rather than a diagnosis, and the sweep shows the corrupted
word is whichever one *begins* on the grant edge; which side of the grant that
falls on depends only on where BR lands.

No harness invariant. What went wrong is a legal bus state entered at an illegal
moment, and every pin is individually plausible while it happens.

## A sixth bug, in the one register the frame recorded after destroying it

**A faulted access that addressed through the address output buffer resumed at
the wrong address.** Reported from a Sun-2/120 replica on an Artix-7, from a
probe written to exonerate `rts`: a `movel %d1,%a0@-` whose write bus-errors is
not resumed by `RTE`, while `movel #imm,(abs)` and `movel %a0@+,%d1` -- the same
handler, the same page, the same privilege, the same boot -- both are. The
machine continued inside the boot PROM with a garbage `a5`, and surfaced as an
address error at a stale PROM address.

The report isolated its variable carefully and stopped where its evidence
stopped, which was the right call and also why it under-called the scope: it had
one instruction and two controls, and concluded the predecrement was what was
left. The predecrement is not the variable. `MOVE.L D1,(A0)` and
`MOVE.L D1,(A0)+` resume; `MOVE.L -(A0),D1` -- predecrement as a *source* --
resumes; and `NOT.B (A0)`, `JSR (A0)`, `BSR`, `PEA` and `LINK` all fail exactly
as `MOVE.L D1,-(A0)` does. What they have in common is not an addressing mode.

### The mechanism

Continuation works by re-executing the microword the fault aborted: nothing that
microword would have written was written, so running it again reissues the same
request. That holds as long as the microword can recompute its address, which
almost all of them can, because they name it through a register the frame saves
and restores.

The exceptions are the microwords that prefetch *before* they access. By the
time those run, `ir` holds the next instruction and the register field that
named the address is gone, so they address through `ea_latch` -- the address
output buffer -- instead. That is 257 microcode labels: MOVE to `-(An)` in all
its source and size combinations, every read-modify-write on `(An)`, `(An)+` and
`-(An)` (the whole `ADDI`/`ANDI`/`ADDQ`/`BCHG`/`CLR`/`NEG`/`NOT`/`Scc`/shift
family), the `-(Ay),-(Ax)` multiprecision forms, and the return-address pushes
of `JSR`, `BSR`, `PEA` and `LINK`.

The frame has a word for that latch -- `SP+36`/`SP+38`, ours, and
`doc/checkpoint.md` has listed it in the checkpoint set since P5. The frame
build destroyed it before writing it. Every word of the frame is written through
an `aupd` on the stack pointer, and an `aupd` is exactly what loads the latch,
so the first frame write overwrote it and the ten-writes-later word that was
meant to record it recorded a stack address instead. `RTE` then made the same
mistake in reverse: it restored the latch mid-walk, and the nineteen remaining
frame reads -- post-increments on the stack pointer, every one of them an
`aupd` -- overwrote it again before the walk was over.

So the resumed access went wherever the frame had reached. Measured on
`MOVE.L D1,-(A0)` with the write to `$4006` faulted: the frame recorded
`$2FEE`, `RTE` restored `$2FFE`, and the two write cycles that should have gone
to `$4006` and `$4004` went to `$3000` and `$2FFE` -- straight into the
supervisor stack under the handler. Nothing announces itself; the return address
is simply not what was pushed, which is the report's "continues somewhere
unrelated" seen from the other end, and why its four runs died three different
ways.

### The fix

A holding register, `ea_save`, on the same footing as `fault_addr`, `dib` and
`upc_save`: the fault takes a copy of the latch before the frame build's own
accesses start loading it, the frame is written from that copy, `RTE` restores
into that copy, and the `RESUME` microword moves it back into the latch. `RESUME`
is the only correct moment -- it is the first point at which no further `aupd`
is coming -- and it does no access of its own, so nothing competes for it.

Two new microcode encodings, `SRC EALSAVE` and `DST EALSAVE`; the microcode
store is unchanged at 6674 words of 146 bits.

### What tests it

`sim/tb/core_fault_tb.sv` faults five accesses that address through the latch --
both write cycles of `MOVE.L D1,-(A0)`, `MOVE.W D1,-(A0)`, the write-back of
`NOT.B (A0)`, and the return address `JSR (A0)` pushes -- and checks the faulted
cycle was reissued and that nothing landed in the frame's address range
afterwards. The read-modify-write arms its bus error only once the core drives a
write: it reads and writes the same address, and arming from the start faults
the *read*, which addresses through the register and was never affected. That
version of the case passed before the fix and after it, which is worth recording
because the file already had one of those.

The existing test at "the data output buffer survives" faults
`MOVE.L D0,-(A0)` and passed throughout. It checked the two halves in memory,
and the slave model has no bus-error input -- a faulted write lands in its
memory anyway -- so both halves were right whether or not the write was ever
reissued. The cycle-count check that the rest of the file uses for continuation
was missing there. It is there now, and it fails before the fix.

Ten checks fail with the fix reverted, across all five cases plus that one.

## A divergence that turned out not to have a source

**"The address bus stays driven between bus cycles"** was listed above as a
deliberate divergence for most of this project's life, justified by a
contradiction in the manual: the state descriptions say the address bus goes to
high impedance at the end of a cycle, and table 3-4 and figure 5-3 were said to
say it stays driven. Neither of those two says any such thing, and the entry has
been deleted.

**Table 3-4** is a signal summary with exactly two high-impedance columns, *On
RESET* and *On Bus Relinquish*. The address bus reads **Yes** in both. It has no
column in which an end-of-cycle release could appear, so it cannot be read as
denying one -- and reading it that way is an argument from a silence the table's
own shape forces.

**Figure 5-3** draws two different glyphs on the two rows either side of a cycle
boundary, and at 300 dpi they are not hard to tell apart. `FC2-FC0` is a
crossover: the lines cross, and the bus is driven throughout. `A23-A1` converges
to a single mid-rail line, runs flat, and diverges again -- the same glyph the
data bus uses two rows below, where it is unquestionably floating. It is narrow,
which is presumably how it came to be read as a crossover, but it is not one.

Everything else in the manual agrees, and two sources say it outright rather
than by drawing:

- **Specification 7**, in the `read-write` AC table and not only the arbitration
  one, is "Clock High to Address, Data Bus High Impedance" -- 80 ns at 8 MHz
  down to 42 ns at 20 MHz. The electrical specifications state how long the
  address bus takes to float at the end of an ordinary cycle, which is not a
  quantity a part that keeps driving it would have.
- **Appendix B**: "At state 0 (S0) in the cycle, the address bus is in the
  high-impedance state." Not an end-of-cycle event but a description of the
  state of the bus at the start of the next one.
- **Figure 10-4** marks both on the `A23-A0` row: 8 where the valid window ends,
  7 where the two lines reach the mid rail.
- Six state descriptions -- UM 5.1.1 state 7, 5.1.2 state 7, 5.1.3 state 19 and
  their three twins in section 4 -- say it in prose.

The repo already half-disagreed with itself: `make-figure-svg.py` draws the
address row of figures 10-4, 10-5 and 10-6 as `v, z, v`, high impedance between
cycles, so our own redrawn figures contradicted our own divergence table.

### What the RTL was doing

`ADDR_HIZ_BETWEEN_CYCLES` now defaults to 1, and the logic behind it was rebuilt,
because the path the parameter selected had never been simulated and did not
work:

- It released the address only in `ST_IDLE`, so **back-to-back cycles never
  floated it at all** -- and S0 of a back-to-back pair is the exact case
  appendix B describes.
- `a_oe` was a rising-edge register reading the *present* state, so both of its
  edges landed a full clock late: the address would have floated a clock after
  the cycle ended, and come back only at the rising edge that asserts `AS` --
  a whole state after the address itself is loaded, and two after S0 began.

It is now a `rd68011_dedge_ff` like `AS`, the data strobes and the data bus
enable: set entering S1, where the address itself is loaded (spec 6), cleared at
the rising edge that ends the cycle (spec 7). The clear term is the data bus's
minus the S7 a read-modify-write passes through on its way to the modify states,
because `AS` is held across that whole cycle and so is the address.

### What tests it

`bus_rw_tb` checks `a_oe` as a window -- asserted in S1 through S7 and negated
in the states either side -- on every read and every write, and separately that
S0 of the back-to-back pair has it released while S7 of the cycle before it does
not. `bus_wait_rmw_tb` checks the window across zero to four wait states and
across both halves of a read-modify-write, where releasing at the read half's S7
would break the indivisible cycle. `bus_system_tb`'s RESET test had to move: an
idle address bus is released anyway now, so "released while RESET is asserted"
is measured in S1 of a cycle run with RESET asserted, which is the only place
the two behaviours differ.

`bus_arb_tb` lost something instead of gaining it, and it is worth saying so.
The processor relinquishes the bus only after the current cycle completes, so by
the time a grant takes effect the address bus is already released for the other
reason. Table 3-4's relinquish column is no longer observable on `a_oe`; the
control group still carries that test.

Clearing `ADDR_HIZ_BETWEEN_CYCLES` again fails 38 checks: 13 in `bus_rw_tb`, 24
in `bus_wait_rmw_tb` and 1 in `bus_arb_tb`. `bus_system_tb` passes either way,
and should -- what it tests is RESET, which releases the address bus under both
readings.

## Not yet implemented

Nothing. Every instruction, every exception and both of the MC68010's own
mechanisms -- instruction continuation and loop mode -- are built, the design
places and routes on a named part at 20.8 MHz, and no register in it
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
