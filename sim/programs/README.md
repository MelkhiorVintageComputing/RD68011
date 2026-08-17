# Test programs

Real code, built with `m68k-linux-gnu` and run to completion on the core.

Everything else that tests this processor tests it one instruction at a time.
The reference vectors are a single instruction each from a fabricated register
state; the directed testbenches are a handful of hand-written ones. These are
programs: sequences long enough for state to be carried between instructions
and for the carrying to be what breaks.

```sh
make programs           # build them all and run them all
```

## The contract

Each program is a flat image — the vector table at zero and everything after
it, exactly what an MC68010 sees after reset — and is self-checking. Three
words at addresses `sim/programs/link.ld` fixes:

| Address | |
|---|---|
| `0x0400` | **result**: `$600D600D` on success, otherwise the number of the check that failed, or `$8xxx` for an exception the program did not expect (`xxx` is its vector offset) |
| `0x0404` | **progress**: the check now running, so a program that hangs still says where |
| `0x0408` | **done**: one word, written last |

`done` is one word and is written last because `sim/tb/core_program_tb.sv`
polls memory while the processor runs, and a long store is two bus cycles —
reading between them gives half an answer.

`rd68011.inc` has the vector table, the two markers and the `CHECK` /
`EXPECT_EQ` macros; a program that provokes an exception it did not name fails
with the vector rather than hanging.

## The programs

| | |
|---|---|
| `p01_flow.S` | Control flow and the stack: nested `BSR`, `LINK`/`UNLK` frames, `MOVEM` save and restore across a callee that clobbers everything, `RTD`, a `DBcc` loop, a jump table, recursion, a block copy, and condition codes surviving a call. |
| `p02_excep.S` | Exceptions as a program uses them: four `TRAP`s telling themselves apart by vector, divide by zero, `CHK`, `TRAPV`, `ILLEGAL` and line A and F stepped over by their own handlers, a privilege violation taken from user mode and returned from in supervisor mode, single-stepping with the trace bit, the vector base register moved and put back, and `MOVES` through `SFC` and `DFC`. |
| `p03_fault.S` | A bus error handler that completes the access itself, the way UM 6.3.9.2 describes: it sets the rerun flag and fills in the data input buffer image, so an address that faults behaves like a device register that is not there. Reads, writes, a `MOVEM` across it, an address error handled the same way, and sixteen faults inside one loop. Needs `p03_fault.args`, which tells the harness which address to fault on. |
| `p05_stress.S` | Arithmetic in long chains, driven by a pseudo-random sequence: the ALU group at all three sizes with flags carried along, eight words of multi-precision `SUBX`, BCD chains where the correction propagates across bytes, multiply and divide feeding each other, every shift and rotate at data-dependent counts, bit operations, a `TAS`, a `CMPM` and a `MOVEP`. It exists mostly for `make cosim`, which compares every register after every instruction; the checksum at the end is a regression marker on top of that. |
| `p04_ccode.c` | C at `-Os`: 32-bit multiply and divide, sign extension across widths, structs sorted by value, a `switch`, byte-at-a-time string work, a table-driven CRC32 checked against its standard value, an FNV hash, recursion, calls through a table of function pointers, and shifts at every width. |

`p04_ccode.c` pushes every input through an inline-assembly barrier before
using it. Without that, gcc folds the whole program at compile time and `main`
becomes five instructions — a test of gcc's constant folder and of nothing
else.

## Co-simulation

`make cosim` runs each of these on the core and on Musashi and compares the
program counter, the status register and all sixteen registers before every
instruction. `p03_fault` is left out: it needs faults injected from outside the
processor, which an instruction-set simulator with no bus has no way to
reproduce.

A program that is only self-checking checks what its author thought to check. A
program run in lockstep checks everything, which is why `p05_stress` is written
the way it is -- it computes almost nothing anyone cares about, and exists to
put the machine through states nobody chose.

## No libgcc

There is no 68010 multilib, so the only `libgcc.a` the toolchain has is built
for a 68020 and contains instructions this part does not have. Linking it
produced `BSR.L` — opcode `$61FF`, which on an MC68010 is a byte branch of
minus one and therefore an address error, which is exactly what the core
reported.

So `libmc68010.S` supplies the handful a C program cannot do without —
`__mulsi3`, `__divsi3`, `__modsi3`, `__udivsi3`, `__umodsi3` — in instructions
the part actually has. Long long is left out of the C program on purpose
rather than growing that file into a libgcc.
