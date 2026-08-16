# Divergences from a real MC68010

Every place RD68011 does not behave as the part does, and why. Software
compatibility is the project's first goal, so anything here is either a
deliberate decision with a reason, or a limit of what can be reproduced.

Instruction *timings* are a separate list — `doc/timing-divergences.md` — and so
is the bus-level detail, in `doc/bus-timing-compliance.md`.

## How this is checked

`make harte-all` runs the SingleStepTests vectors through the core and compares
registers, status register, prefetch pipe, memory and the bus transaction list.
Those vectors were generated from MAME's microcoded **MC68000**, so wherever the
MC68010 must differ, the runner does one of two things:

- **Adjusts the comparison** where the difference is well defined, so
  everything else the test checks is still checked. CLR is the case that
  matters.
- **Skips the test**, counted and reported, where the whole shape differs.

A sweep therefore reports three numbers: passed, failed, and skipped — with the
skips broken down into "not implemented" and "needing exception processing", so
a partial implementation says what is missing rather than quietly passing.

## MC68000 to MC68010 differences the vectors expose

These are not RD68011 divergences — they are the MC68010 behaving as it should,
against a reference that is an earlier part. Each was confirmed against the
manual and against the vectors before being relied on.

| | |
|---|---|
| **CLR does not read its operand.** UM section 9's execution times give the MC68010 two cycles fewer than the MC68000 for every memory destination. The shape is `P w`, not `r P w`. | The runner removes the reference's operand read and compares the rest. 250-odd tests per size are compared this way. |
| **MOVE from SR is privileged.** PRM section 6: on the MC68010 it traps in user mode, where the MC68000 allowed it. | User-mode vectors for it are skipped; the instruction itself arrives with the supervisor group in P4. |
| **Exception stack frames carry a format and vector word.** A privilege violation on the MC68000 pushes SR and PC as three words; the MC68010 pushes four. Confirmed empirically from the user-mode RESET vectors, where all 1267 of them take the trap. | The tests that reach exception processing are skipped until P4. |
| **Bus and address error frames are the 29-word format $8**, not the MC68000's seven-word one. | P6. |
| **New instructions**: `BKPT`, `MOVE from CCR`, `MOVEC`, `MOVES`, `RTD`, and the `VBR`, `SFC` and `DFC` registers. | P5. |
| **`RTE` checks the frame format** and traps to vector 14 on a bad one. | P4 and P6. |
| **Loop mode** (UM appendix A). | P7. |

## Deliberate divergences

| | Why |
|---|---|
| **The E clock's power-on phase.** UM 3.7 says the ring counter "may come up in any state. (At power-on, it is impossible to guarantee phase relationship of E to CLK.)" Ours starts from a defined reset state. | Deterministic simulation is worth more than reproducing an indeterminacy, and no correct system can depend on the phase. |
| **`rst_n` is not an MC68010 pin.** It is a hardware initialisation input that gives every register a defined value. | ASIC is a target, so there is no power-on state. The architectural reset — RESET and HALT asserted together, vector fetch from $000000 and $000004 — is a separate sequence on the real pins, and is implemented. |
| **The format $8 frame's 16 internal words use our own encoding**, stamped with our own version number. | This is what the architecture asks for. UM 6.4: the first internal word carries "a processor version number (in bits 10-13) and proprietary internal information that must match the version number of the MC68010 attempting to read the data", and RTE must raise a format error when it does not match. Software that saves and restores a frame — which is every operating system — cannot tell the difference. Software that synthesises internal words from scratch was already not portable between MC68010 versions. `doc/checkpoint.md` has the full argument. |
| **The address bus stays driven between bus cycles.** UM 5.1.1, 5.1.2, 5.1.3 and appendix B all say it goes to high impedance at the end of a cycle; table 3-4 and figure 5-3 say it stays driven. | The manual contradicts itself. Table 3-4 is followed by default because that is what systems built around this part rely on; the `ADDR_HIZ_BETWEEN_CYCLES` parameter selects the other reading. `doc/bus-timing-compliance.md` has both citations. |
| **Nanosecond output delays are not modelled.** | An RTL model has no analogue delays; those limits are an STA and pad concern. What *is* checked is the placement of every edge in the bus-state ruler, which is the part that belongs to the design. |

## Not yet implemented

Listed so a sweep's "not implemented" count can be read against something.

**P4** — exception processing: TRAP, TRAPV, CHK, ILLEGAL, line A and line F,
privilege violations, trace, interrupts and their acknowledge cycles, RESET and
STOP, Bcc, DBcc, BSR, JMP, JSR, RTS, RTR, LINK, UNLK, and RTE with a format $0
frame.

**P5** — MULU, MULS, DIVU, DIVS, the BCD group (ABCD, SBCD, NBCD), ADDX, SUBX,
CMPM, MOVEM, MOVEP, EXG, MOVE USP, the status-register forms of ANDI, ORI and
EORI, and the MC68010's own MOVEC, MOVES, RTD and BKPT.

**P6** — bus error, address error, the format $8 frame and instruction
continuation.

**P7** — loop mode.

## What is implemented and passing

82 opcode files, every one at zero failures: MOVE and MOVEA at all three sizes
and every addressing mode, MOVEQ, TST, CLR, NEG, NEGX, NOT, the ALU group
(ADD, SUB, AND, OR, EOR, CMP) in both directions, ADDA/SUBA/CMPA, the immediate
group, ADDQ and SUBQ, EXT, SWAP, LEA, PEA, Scc, TAS, the four bit operations in
both their dynamic and static forms, and all twenty-four shift and rotate
variants.
