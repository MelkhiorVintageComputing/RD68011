# Bugs found and fixed

Every defect this project has found in its own design, what it was, how it was
found, and what stops it coming back. None of these is a divergence any more --
`doc/divergences.md` is the list of what still differs from the part -- but the
record is worth keeping, because *how* each one was found says more about which
pressures work than the fix does.

The pattern is worth stating up front: not one of these was found by the
reference vectors, which are an MC68000 and one instruction at a time. What
found them was a real machine running real software -- four of the entries
below come from the same Sun-2 FPGA replica -- real programs built by a
compiler, a downstream report, the specification's own numbers turned into a
question, and asking what the tests did not reach.

Every fix below has a test that fails without it. That is the project's rule: a
gate nobody has watched fail is not a gate.

## Two bugs the real programs found

`make programs` builds real code with `m68k-linux-gnu` and runs it to
completion. Everything else tests one instruction from a fabricated state; a
program tests sequences, and `doc/divergences.md` makes the argument for why
that reaches things nothing else does. These two are the evidence:

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
`doc/divergences.md` gives under *How the sweep tells an exception apart*, so
exceptions are checked by directed tests alone -- and trace had exactly one, a
traced `NOP`.

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
`doc/checkpoint.md` has listed it in the checkpoint set all along. The frame
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

**"The address bus stays driven between bus cycles"** stood in
`doc/divergences.md` as a deliberate divergence for most of this project's
life, justified by a
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

## A report that did not reproduce, and what that is worth

Not every report is a defect, and the ones that are not still cost something to
settle. This one is here because the settling is the useful part.

**What was reported.** Three unrelated programs on a Sun-2/50 replica running
SunOS 4.0.3 die with `SIGBUS` at the same instruction in libc's `strncpy`, with
the same registers, across two root filesystems and two storage regions. On that
kernel `SIGBUS` reaches user space only from `T_ADDRERR`, so the machine was
reporting an **address error on a byte move** -- which a 68010 has no reason to
raise, byte accesses having no alignment requirement. The loop is four
instructions of setup and two of body, and one byte has been copied when the
fault is taken, so both operands are odd on the pass that fails.

The report was careful enough to state the objection to its own headline: if
`MOVE.B (A1)+,(A0)+` faulted whenever both operands were odd, the second byte of
every ordinary string copy would fault, and the machine would not boot. So
either the trigger is narrower than the alignment, or the frame does not name
the instruction that faulted.

**What was built.** `sim/tb/core_strncpy_tb.sv`, the loop copied opcode for
opcode from the report's disassembly -- including that it is entered at the
`DBEQ` rather than at the `MOVE`, so the first thing executed is the decrement
and branch. 231 cases: all four entry alignments with *n* from 1 to 16, the
operands far apart in the address space, the reported operands themselves with
every address bit as reported except A23 (which this memory model does not
answer), and the loop interrupted at each of 161 consecutive clocks.

**The result is negative and it is worth something, because of three things
that go with it.**

- *The controls fire.* A word read at an odd address takes vector 3 and a byte
  read at an odd address does not, both checked every run. Without those a null
  result would be indistinguishable from a handler that was never going to run.
- *Loop mode was running.* The displacement is minus four and
  `MOVE.B (Ay)+,(Ax)+` is in table A-1, so the copy runs with no instruction
  fetches at all -- the state the reported fault would have been taken in. A
  monitor fails the case if `loop_active` never came up, so this is checked
  rather than assumed.
- *The reproducer catches the reported fault when it is put there.* Deleting the
  byte-size exemption from `n_addr_err` -- one term of one expression -- makes
  every case take vector 3, and the frame it builds is the frame the Sun-2
  reported: format 8, vector offset $00c, fault address the odd source, and a
  stacked PC of `$101a`, which is the **extension word of the `DBEQ`**. The
  report's own PC, `_strncpy + $14`, is the extension word of its `DBEQ`. So the
  reading of the frame in the report is right about what such a fault would look
  like; the core does not produce one.

The RTL says the same thing more directly and was checked first:
`rd68011_seq.sv`'s `n_addr_err` requires `n_size != U_SIZE_BYTE`, so a byte
access cannot reach vector 3 by construction. That is an argument, though, and
an argument is not a test -- which is why the sweep exists and why it carries an
injection that makes it fail.

### The follow-up, with a bus capture and a mechanism

A second report came back with what the first was missing: a cycle-level capture
of the fault rather than an inference from a core file. The same instruction
takes vector 3 and **no bus cycle is issued for the access at all**, so the core
is deciding internally. The discriminator is that the loop must be **re-entered
by `RTE`** -- which is why the first sweep, and the reporter's own freestanding
probe, both passed: neither ever resumed the loop, the probe because it masks
interrupts to level 7.

Two resume paths can do that, and in this design they share almost nothing:

- **A short frame**, from an exception taken at an instruction boundary, which
  comes back through `DECODE`. For this to be the reported case the loop has to
  be running in *user* mode, so that the `RTE` changes the supervisor bit on the
  way out -- which the first sweep, running entirely in supervisor mode, could
  not have exercised.
- **A long frame**, from a bus error on the copy's own access -- the page-fault
  path the machine actually takes -- which comes back through `RESUME` and
  `upc_save` and re-executes the faulted microword with the rerun flag clear, so
  the access is retried.

`core_strncpy_tb` now does both, and counts what it achieved rather than
asserting it: **829** cases where the `RTE` demonstrably resumed inside the loop,
**365** of those with both operands odd, and **42** resumed out of a format $8
frame with loop mode running when the fault hit. Nothing faults. The page-fault
handler saves every register and writes and reads back through `-(An)` before
returning, because a two-instruction handler restores almost nothing and every
instruction-restart defect this project has found was found by one doing real
work.

**What it does not rule out.** There is no MMU here and one flat memory, so
anything that depends on which pages are involved, or on translation, is out of
reach of a core-only test. A23 is out of reach of the memory model, but that gap
is narrower than it looks: `n_addr_err` reads no address bit above A0, so no
high-order bit can reach the decision. What is ruled out is the mechanism as
stated: this loop, in loop mode, at every alignment and length, in user mode and
supervisor, resumed by `RTE` out of both frame formats, at five memory latencies,
does not fault.

### The third report settled it, by capturing the frame

The third report captured the format $8 frame word by word off the bus and read
it as evidence that the core had formed a malformed access -- "a byte move
described as a word write". It is better evidence than that. **The frame is not
malformed. It is a faithful description of the core executing a different
instruction**, and every field agrees:

| the frame said | which is |
|---|---|
| `ir` = `$22C1` | `MOVE.L D1,(A1)+` |
| resume micro-address = `$34A` | 842, the first microword of `move_long_r2apost` |
| data output buffer = `$0000000C` | `D1` = 12, which is what that instruction writes |
| SSW = `$0001` | word, write, user data -- correct for a long write's first cycle |
| fault address = `a1`, odd | correct: a word write there *is* an address error |
| version word = `$2E00` | version `$B`, loop state `10`: loop mode running, phase 0 |

So the alignment check is right, the access it objected to was genuinely
word-sized, and the defect is one register upstream: `ir` held the wrong opcode.
In loop mode `ir` comes from `loop_ir` through `LOOPBACK`, so `loop_ir` is the
register to look at -- and the frame's own `loop_ir` slot, SP+56, also held
`$22C1`, which is one corruption explaining both.

`core_strncpy_tb` watches `loop_ir` on every clock loop mode is active, across
all 1999 cases. It is never wrong, and in the page-fault cases the frame the
core pushes carries the right value -- SP+56 reads `$10D9`, the instruction that
is actually in the loop.

**So the last case in that testbench asks the other question, and it reproduces
the report exactly.** The handler writes `$22C1` into SP+56 before returning --
one word, nothing else -- and the resumed loop faults with:

| | reproduced | reported |
|---|---|---|
| format / vector offset | `800C` | `800C` |
| special status word | `0001` | `0001` |
| fault address | the source pointer, odd | the source pointer, odd |
| stacked PC | the `DBEQ`'s extension word | the `DBEQ`'s extension word |
| stacked SR | `0000` | `0000` |

Every observable, from one input: **the frame's SP+56 word changed between the
push and the `RTE`**. The core cannot defend against that. `RTE` validates the
format word and the version number, which is what UM 6.4 asks for, and nothing
else in the frame -- and SP+56's meaning is this implementation's own, recorded
in `doc/divergences.md` as a deliberate divergence, because the sixteen internal
words are implementation-defined and a real MC68010 has something else there.
Software that relocates a format $8 frame between stacks, rebuilds it, or
normalises its internal words will break exactly this way and no other
implementation's frame would tell it so.

That does not prove the field failure is that and not something else. It does
mean the cheap next measurement is upstream of the core: capture the *page
fault's* frame as well as the address error's, and compare the SP+56 the core
pushed with the SP+56 the `RTE` read back.

### The fourth report, and what its comparison does and does not show

The fourth report recovered both frames from the one capture and tabulated them
side by side. Two things in it are new and both matter.

**`SP+30` differs and `SP+56` does not.** The frame the kernel hands back carries
`ir` = `$10D9`, the `MOVE.B` really executing, *and* `loop_ir` = `$22C1` in the
same frame. The frame the core builds a moment later has `$22C1` in both. So the
disagreement is already present in the incoming frame, and what the core does
after the `RTE` -- putting `loop_ir` into `ir` through `LOOPBACK` -- is what it
is built to do.

**Its incoming frame is coherent everywhere else.** `upc_save` = `$4D` is
microword 77, the source-byte read of `move_byte_apost2apost`; the SSW `$1301`
says byte, read, user data; the fault address is even. All of that is the
legitimate demand-paging fault on the first byte, correctly described.

That leaves one question: how can `loop_active` be set while `loop_ir` disagrees
with `ir`? In this design `loop_active` is set in exactly two places --
`LP_ENTER`, which writes `loop_ir` on the same edge, and `RESUME`, which does
not -- and `RESUME` is reachable from one microword, the long-frame `RTE`. So a
handler running a **loop of its own** between them is the only core-side path,
and a real kernel has one: `bzero` and `copyin` are one-word moves closed by a
`DBcc` with a displacement of minus four, which is a loop mode loop, and `$22C1`
is `MOVE.L D1,(A1)+`.

`core_strncpy_tb` now runs 30 cases where the page-fault handler does exactly
that -- saves every register, runs a loop mode loop on `$22C1`, restores, `RTE`
-- across four alignments and every faulting word, with a monitor that fails the
case if the *user* loop ever resumes with anything but its own instruction. The
handler's loop is legitimately looping `$22C1` at the time, so the monitor is
scoped by program counter rather than by value. All 30 pass, and 2030 cases in
total now find nothing.

**One correction is owed to the comparison itself.** It concludes that "nothing
between the push and the pop altered that word", but the two columns are the
*pop of the bus-error frame* and the *push of the address-error frame* -- two
different frames. The bus-error frame's own push is not in the window, so the
interval that matters is precisely the one not measured. What the capture shows
is that `SP+56` was already `$22C1` when `RTE` read it; what would settle it is
recording what the core *wrote* there, which needs the recorder triggered on the
bus-error handler instead.

On this side that write has been observed directly: in the clobber case above
the testbench prints `SP+56` before touching it, and the core had put `$10D9`
there -- the instruction actually in the loop.
