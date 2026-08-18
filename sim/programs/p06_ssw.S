| p06_ssw -- what the special status word says about a faulted bus cycle.
|
| Two MC68010 implementations were driven through the same stimulus on the same
| system and disagreed about the special status word of a faulted supervisor
| data write. One reported a data write in supervisor data space; the other
| reported an instruction fetch, a read, in supervisor program space. They
| cannot both be right, and neither the frame nor the fault address disagreed,
| so a test that only looks at those would pass on both.
|
| UM figure 6-9 gives the format, and the field definitions are quoted rather
| than paraphrased because two of them are easy to read the wrong way:
|
|    15   14   13   12   11   10    9    8              2..0
|    RR   --   IF   DF   RM   HB   BY   RW              FC2-FC0
|
|   RR - Rerun flag; 0=processor rerun (default), 1=software rerun
|   IF - Instruction fetch to the instruction input buffer
|   DF - Data fetch to the data input buffer
|   RM - Read-modify-write cycle
|   HB - High-byte transfer from the data output buffer or to the data input
|        buffer
|   BY - Byte-transfer flag; HB selects the high or low byte of the transfer
|        register. If BY is clear, the transfer is word.
|   RW - Read/write flag; 0=write, 1=read
|   FC - The function code used during the faulted access
|
| and of the reserved bits, "these bits are reserved for future use by Motorola
| and will be zero when written by the MC68010", so they are asserted as zero
| here rather than masked away.
|
| DF is the one worth being careful about. Read as "does this cycle concern
| data" it would be set for a write; read as the manual writes it -- a data
| *fetch*, *to* the data input buffer -- it is a read into a buffer, and a write
| fetches nothing. The surrounding prose settles it: "If the bus cycle is a
| read, the data at the fault address should be written to the images of the
| data input buffer, instruction input buffer, or both according to the data
| fetch (DF) and instruction fetch (IF) bits." The two bits only ever say which
| buffer a *read* should be completed into. So a write sets neither.
|
| HB is the other one, and it is not asserted for word transfers. Its meaning is
| given entirely in terms of BY -- "HB selects the high or low byte of the
| transfer register. If BY is clear, the transfer is word" -- so when BY is
| clear there is no high or low byte for it to select and the manual does not
| say what it holds. It is masked off below except in the two byte cases, where
| it is asserted: the high byte for an even address, the low byte for an odd
| one.
|
| The recovery is by restoring a stack pointer and jumping, not by RTE, which
| would rerun the faulted cycle for ever, and not by RTS, which would need a
| return address nothing here pushed.

    .include "rd68011.inc"

|  Nothing decodes here, so the harness's bus error arrives with no DTACK ever
|  asserted -- a timeout rather than a retry. See p06_ssw.args.
    .equ    HOLE,   0x800000

    .equ    HB,     0x0400          | the bit the manual leaves undefined for
                                    | a word transfer

    VECTORS
    RESULT_BLOCK

    .text
    .globl  _start
_start:
    PROGRAM_BEGIN
    move.l  #__stack_top,resume_sp

    | ------------------------------------------------------------------
    CHECK   1                       | supervisor data write, word
    | ------------------------------------------------------------------
    | IF=0 not a fetch, DF=0 a write fetches nothing, RM=0, BY=0 a word,
    | RW=0 a write, FC=5 supervisor data.
    move.l  #1f,resume_pc
    movea.l #HOLE,%a0
    move.w  #0x1234,(%a0)
1:  move.w  ssw,%d1
    andi.w  #~HB,%d1
    EXPECT_EQ_W %d1, 0x0005
    move.l  faddr,%d2
    EXPECT_EQ_L %d2, HOLE
    move.w  fmtvec,%d3              | format 8, vector offset 8 = vector 2 * 4
    EXPECT_EQ_W %d3, 0x8008

    | ------------------------------------------------------------------
    CHECK   2                       | supervisor data read, word
    | ------------------------------------------------------------------
    | DF=1 a read into the data input buffer, RW=1, FC=5.
    move.l  #2f,resume_pc
    movea.l #HOLE,%a0
    move.w  (%a0),%d0
2:  move.w  ssw,%d1
    andi.w  #~HB,%d1
    EXPECT_EQ_W %d1, 0x1105

    | ------------------------------------------------------------------
    CHECK   3                       | supervisor data write, byte, even
    | ------------------------------------------------------------------
    | BY=1, and HB=1 because an even address is the high byte of the word.
    move.l  #3f,resume_pc
    movea.l #HOLE,%a0
    move.b  #0x5A,(%a0)
3:  move.w  ssw,%d1
    andi.w  #~HB,%d1
    EXPECT_EQ_W %d1, 0x0205

    | ------------------------------------------------------------------
    CHECK   4                       | supervisor data write, byte, odd
    | ------------------------------------------------------------------
    | The same word, so the harness still faults it, but the low byte: HB=0.
    move.l  #4f,resume_pc
    movea.l #HOLE+1,%a0
    move.b  #0x5A,(%a0)
4:  move.w  ssw,%d1
    andi.w  #~HB,%d1
    EXPECT_EQ_W %d1, 0x0205

    | ------------------------------------------------------------------
    CHECK   5                       | instruction fetch
    | ------------------------------------------------------------------
    | IF=1, DF=0, RW=1, FC=6 supervisor program. The discriminating case:
    | the implementation under suspicion produced exactly this for check 1.
    move.l  #5f,resume_pc
    jmp     HOLE
5:  move.w  ssw,%d1
    andi.w  #~HB,%d1
    EXPECT_EQ_W %d1, 0x2106

    | ------------------------------------------------------------------
    CHECK   6                       | user data write
    | ------------------------------------------------------------------
    | FC=1 user data. Everything else as check 1.
    move.l  #6f,resume_pc
    movea.l #__stack_top-0x400,%a0
    move.l  %a0,%usp
    move.w  #0x0700,%sr             | S clear: user mode from here
    movea.l #HOLE,%a0
    move.w  #0x1234,(%a0)
6:  move.w  ssw,%d1                 | the handler left us supervisor again
    andi.w  #~HB,%d1
    EXPECT_EQ_W %d1, 0x0001

    | ------------------------------------------------------------------
    CHECK   7                       | user program fetch
    | ------------------------------------------------------------------
    | FC=2 user program, IF=1, RW=1.
    move.l  #7f,resume_pc
    movea.l #__stack_top-0x400,%a0
    move.l  %a0,%usp
    move.w  #0x0700,%sr
    jmp     HOLE
7:  move.w  ssw,%d1
    andi.w  #~HB,%d1
    EXPECT_EQ_W %d1, 0x2102

    | ------------------------------------------------------------------
    CHECK   8                       | read-modify-write
    | ------------------------------------------------------------------
    | RM=1 and FC=5. TAS is the MC68010's only read-modify-write, and it is
    | the read half that faults here, so RW and DF describe a read.
    move.l  #8f,resume_pc
    movea.l #HOLE,%a0
    tas     (%a0)
8:  move.w  ssw,%d1
    andi.w  #~HB,%d1
    EXPECT_EQ_W %d1, 0x1b05

    | ------------------------------------------------------------------
    CHECK   9                       | every fault above was taken exactly once
    | ------------------------------------------------------------------
    move.w  nfault,%d1
    EXPECT_EQ_W %d1, 8

    PROGRAM_END

| The handler. It abandons the frame rather than returning through it: RTE
| would rerun the faulted cycle and fault again for ever, and RTS would need a
| return address nothing pushed. So it copies out what it came for, puts the
| stack back where the program left it, and jumps.
    .globl  v_bus, v_addr
v_bus:
v_addr:
    move.w  8(%sp),ssw
    move.l  10(%sp),faddr
    move.w  6(%sp),fmtvec
    move.w  16(%sp),dob             | the data output buffer image
    | ... and keep every one, so a testbench can read the whole set out of
    | memory rather than inferring them from which check failed.
    movem.l %d0-%d1/%a0,-(%sp)
    move.w  nfault,%d0
    andi.l  #0x000F,%d0
    add.w   %d0,%d0
    movea.l #ssw_tab,%a0
    move.w  ssw,(%a0,%d0.w)
    movem.l (%sp)+,%d0-%d1/%a0
    addq.w  #1,nfault
    movea.l resume_sp,%sp
    movea.l resume_pc,%a0
    jmp     (%a0)

    UNEXPECTED_HANDLER
    .globl  v_illegal, v_divzero, v_chk, v_trapv, v_priv, v_trace
    .globl  v_linea, v_linef, v_format, v_trap, v_irq
v_illegal:
v_divzero:
v_chk:
v_trapv:
v_priv:
v_trace:
v_linea:
v_linef:
v_format:
v_trap:
v_irq:
    bra     v_unexpected

    .data
    .align  2
ssw:        .word   0
    .globl  ssw_tab
ssw_tab:    .word   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
fmtvec:     .word   0
    .globl  dob
dob:        .word   0
nfault:     .word   0
faddr:      .long   0
resume_pc:  .long   0
resume_sp:  .long   0
