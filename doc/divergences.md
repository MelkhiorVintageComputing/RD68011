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
