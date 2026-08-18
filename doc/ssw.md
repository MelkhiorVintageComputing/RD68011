# The special status word of a faulted bus cycle

Two MC68010 implementations were driven through the same stimulus on the same
system and produced different special status words for a faulted supervisor
data write. One of them has to be wrong. This is the manual's answer and both
implementations measured against it.

```sh
make programs           # sim/programs/p06_ssw.S, on RD68011
make suska-ssw          # the identical image on both processors
```

## What the manual says

UM figure 6-9, quoted rather than paraphrased, because two of the fields are
easy to read the wrong way:

```
   15   14   13   12   11   10    9    8              2..0
   RR   --   IF   DF   RM   HB   BY   RW              FC2-FC0
```

| | |
|---|---|
| RR | Rerun flag; 0=processor rerun (default), 1=software rerun |
| IF | Instruction fetch to the instruction input buffer |
| DF | Data fetch to the data input buffer |
| RM | Read-modify-write cycle |
| HB | High-byte transfer from the data output buffer or to the data input buffer |
| BY | Byte-transfer flag; HB selects the high or low byte of the transfer register. If BY is clear, the transfer is word |
| RW | Read/write flag; 0=write, 1=read |
| FC | The function code used during the faulted access |

and of the rest, "these bits are reserved for future use by Motorola and will be
zero when written by the MC68010" — so they are asserted as zero rather than
masked away.

**DF is a read, not "concerns data".** Read as "does this cycle concern data"
it would be set for a write. Read as the manual writes it — a data *fetch*,
*to* the data input buffer — a write fetches nothing. The prose settles it:
"If the bus cycle is a read, the data at the fault address should be written to
the images of the data input buffer, instruction input buffer, or both according
to the data fetch (DF) and instruction fetch (IF) bits." The two bits only ever
say which buffer a *read* should be completed into, so a write sets neither.

**HB is undefined for a word transfer.** Its meaning is given entirely in terms
of BY — "HB selects the high or low byte of the transfer register. If BY is
clear, the transfer is word" — so when BY is clear there is no high or low byte
for it to select. `sim/programs/p06_ssw.S` masks it off except in the two byte
cases. See the open question at the end.

## The stimulus

`sim/programs/p06_ssw.S` faults a cycle in each shape the fields distinguish,
against an address nothing decodes, so the bus error arrives with no
acknowledge ever asserted — a timeout, not a retry. The handler abandons the
frame rather than returning through it: RTE would rerun the faulted cycle for
ever, and RTS would need a return address nothing pushed.

| | expected SSW | |
|---|--:|---|
| supervisor data write, word | `0005` | IF=0 DF=0 RW=0 FC=5 |
| supervisor data read, word | `1105` | DF=1 RW=1 FC=5 |
| supervisor data write, byte, even | `0205` | BY=1, HB not asserted |
| supervisor data write, byte, odd | `0205` | BY=1, HB not asserted |
| instruction fetch | `2106` | IF=1 RW=1 FC=6 |
| user data write | `0001` | FC=1 |
| user program fetch | `2102` | FC=2 |
| read-modify-write (TAS) | `1b05` | RM=1, and the read half faults |

It also asserts the parts outside the special status word, which make good
invariants: vector 2, format 8 in the top nibble of the format word, the vector
offset 8, and the fault address equal to the address driven.

The first and fifth cases are the discriminating pair. A test that only ever
faults on instruction fetches passes on both implementations and catches
nothing.

## What each produced

**RD68011: all nine checks pass.** Every case matches the table above.

**Suska WF68K10: fails the first case**, with

```
SSW suska: result 00000002    (check 1 failed)
SSW suska: ssw[0] = 2306
```

`0x2306` is IF=1, BY=1, RW=1, FC=6: an instruction fetch, a byte, a read, in
supervisor *program* space. The stimulus was a word write in supervisor *data*
space. Four fields wrong, and wrong in a way that describes a plausible cycle —
just not the one that faulted, which is what the original report suspected when
it said the word looked "filled from something other than the faulted cycle's
own attributes".

That matches the reported implementation A, which produced `0x2506` on real
hardware for the same stimulus: the same IF=1, RW=1, FC=6, differing only in HB
and BY. So the fault is reproduced here from the manual and a program, without
needing the machine it was found on.

**Caveat.** `sim/suska/wf68k10_ssw_tb.vhd` is ours, and a testbench can be wrong
in a way that flatters or maligns what it drives. What supports the reading: the
identical image, through the identical memory model shape, passes on RD68011;
the failure is at the *first* faulting case rather than somewhere deep; and the
value matches what a different observer measured on different hardware. The
Suska core is instantiated with the generics `sim/suska/wf68k10_tb.vhd` has used
throughout, and nothing was read of its source.

## Why it matters

`RTE` on a format 8 frame reruns the faulted cycle from the frame's saved state,
so a frame that misdescribes the direction, the space or the function code
cannot rerun it correctly — that is the path a demand-paged kernel takes after
making a page valid. And a kernel that probes for absent hardware arms a
recovery, performs the access, and asks the handler what faulted.

A wrong word does not by itself break `longjmp`-style recovery, because a
handler that discards the frame and jumps to a saved PC never reads it. So this
is asserted directly rather than inferred from whether recovery worked.

## One open question

RD68011 reports **HB=0 for every ordinary byte transfer**, including a byte
write to an even address, which goes out on the upper half of the data bus and
would sit in the upper half of the data output buffer image. Our HB comes from
the microword and is set only by MOVEP, which is where the field's "which half
of the register" meaning is unambiguous.

The manual does not settle it. It defines HB only through BY — which half of the
transfer register the byte is — and an even-address byte write does use the high
half, so HB=1 is the reading that would help a handler completing the access in
software. Nothing in this project needs it yet, `sim/programs/p03_fault.S`
completes only word accesses, and asserting either value would be asserting more
than UM figure 6-9 says. It is masked in `p06_ssw.S` and recorded here instead.
