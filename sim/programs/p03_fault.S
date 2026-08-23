| p03_fault -- a bus error handler that completes the access itself.
|
| This is the MC68010's reason for existing, written the way an operating
| system would write it. The testbench answers one address with a bus error
| (see p03_fault.args), and the handler here does what UM 6.3.9.2 describes as
| the alternative to rerunning the cycle:
|
|   "An alternate method of handling a bus error is to complete the faulted
|    access in software. Using this method requires the special status word,
|    the instruction input buffer, the data input buffer, and the data output
|    buffer image. [...] Once the cycle has been completed by software, the
|    rerun (RR) bit in the special status word is set to indicate to the
|    processor that it should not rerun the cycle when the RTE instruction is
|    executed."
|
| So the faulting address behaves like a device register that does not exist:
| reads of it come back with whatever the handler decides, and writes to it are
| logged instead of happening. The program cannot tell the difference, which is
| the whole point.
|
| The format $8 frame, from UM figure 6-8:
|
|    0(sp)  status register        16(sp)  data output buffer
|    2(sp)  program counter        20(sp)  data input buffer
|    6(sp)  format and vector      24(sp)  instruction input buffer
|    8(sp)  special status word    26(sp)  sixteen internal words
|   10(sp)  fault address

    .include "rd68011.inc"

    .equ    DEVICE,     0x2000      | the address the harness faults on
    .equ    DEVICE_VAL, 0xC0DE      | what the handler pretends it reads

    VECTORS
    RESULT_BLOCK

    .text
    .globl  _start
_start:
    PROGRAM_BEGIN
    | ------------------------------------------------------------------
    CHECK   1                       | a read that never reaches memory
    | ------------------------------------------------------------------
    clr.w   fault_count
    movea.l #DEVICE,%a0
    move.w  (%a0),%d1
    EXPECT_EQ_W %d1, DEVICE_VAL
    move.w  fault_count,%d2
    EXPECT_EQ_W %d2, 1

    | ------------------------------------------------------------------
    CHECK   2                       | a write that is logged instead
    | ------------------------------------------------------------------
    clr.w   fault_count
    clr.l   fault_addr
    clr.w   fault_data
    movea.l #DEVICE,%a0
    move.w  #0x5A5A,(%a0)
    move.w  fault_count,%d2
    EXPECT_EQ_W %d2, 1
    move.l  fault_addr,%d0
    EXPECT_EQ_L %d0, DEVICE
    move.w  fault_data,%d0
    EXPECT_EQ_W %d0, 0x5A5A

    | ------------------------------------------------------------------
    CHECK   3                       | the same address inside a MOVEM
    | ------------------------------------------------------------------
    | Fill the four longs after the device word, then read all five in one
    | MOVEM. The first word of the first long is the device, and only the
    | handler can supply it.
    clr.w   fault_count
    movea.l #DEVICE+2,%a0
    move.w  #0x1111,(%a0)+
    move.l  #0x22223333,(%a0)+
    move.l  #0x44445555,(%a0)+
    move.l  #0x66667777,(%a0)+
    move.w  fault_count,%d2
    EXPECT_EQ_W %d2, 0             | none of those touched the device

    movea.l #DEVICE,%a0
    movem.l (%a0),%d2-%d5
    EXPECT_EQ_L %d2, 0xC0DE1111
    EXPECT_EQ_L %d3, 0x22223333
    EXPECT_EQ_L %d4, 0x44445555
    EXPECT_EQ_L %d5, 0x66667777
    move.w  fault_count,%d6
    EXPECT_EQ_W %d6, 1             | one word of the eight, once

    | ------------------------------------------------------------------
    CHECK   4                       | an address error, completed the same way
    | ------------------------------------------------------------------
    | A word at an odd address is an address error rather than a bus error,
    | and UM 6.3.10 says the frame is the same one. So the same handler can
    | finish it, which is the only way to get past it at all: the fault
    | address is what a rerun would use, and it would fault again.
    clr.w   fault_count
    movea.l #odd_place+1,%a0
    move.w  (%a0),%d1
    EXPECT_EQ_W %d1, DEVICE_VAL
    move.w  fault_count,%d2
    EXPECT_EQ_W %d2, 1

    | ------------------------------------------------------------------
    CHECK   5                       | and the program is otherwise unharmed
    | ------------------------------------------------------------------
    | Everything above went through a handler that ran dozens of instructions.
    | The registers it did not save had better still be what they were.
    move.l  #0x13572468,%d7
    clr.w   fault_count
    movea.l #DEVICE,%a0
    move.w  (%a0),%d1
    EXPECT_EQ_L %d7, 0x13572468
    move.l  %a0,%d0
    EXPECT_EQ_L %d0, DEVICE

    | ------------------------------------------------------------------
    CHECK   6                       | a faulting loop, continued each time
    | ------------------------------------------------------------------
    | Sixteen reads of the device in a DBcc loop: sixteen faults, sixteen
    | handled, and a sum that could only come out right if every one of them
    | put the data back where the instruction expected it.
    clr.w   fault_count
    movea.l #DEVICE,%a0
    moveq   #0,%d0
    move.w  #15,%d1
1:  move.w  (%a0),%d2
    ext.l   %d2
    add.l   %d2,%d0
    dbf     %d1,1b
    move.l  %d0,loop_sum            | kept, so a failure here is diagnosable
    move.w  fault_count,%d3
    EXPECT_EQ_W %d3, 16
    | 0xC0DE sign-extended is -16162, and sixteen of those is -258592
    EXPECT_EQ_L %d0, 0xFFFC0DE0

    | ------------------------------------------------------------------
    CHECK   7                       | a fault taken from user mode
    | ------------------------------------------------------------------
    | UM 6.2.5 puts the S bit up in step one and stacks the frame "using the
    | SSP" in step three, so no part of a frame is ever a user-stack access.
    | Reported from a machine running an operating system: the topmost word of
    | the frame went to USP-2 instead. On a demand-paged system the page under
    | a fresh process's stack pointer is usually not resident, so that write
    | faults inside exception processing and the machine halts.
    |
    | Neither stack pointer shows it -- USP is never written -- so the only
    | witness is the memory underneath, which is what this paints and reads
    | back. Last check in the program, because it ends in user mode: `pass`
    | and `fail` write to data space and need no privilege.
    lea     user_stack_top,%a1
    move.l  %a1,%usp
    move.w  #0xA5A5,%d0
    moveq   #7,%d1
1:  move.w  %d0,-(%a1)              | eight words under the user stack
    dbf     %d1,1b

    clr.w   fault_count
    andi.w  #0xDFFF,%sr             | to user mode, and stay there
    movea.l #DEVICE,%a0
    move.w  (%a0),%d1               | faults; the handler completes it as above
    EXPECT_EQ_W %d1, DEVICE_VAL
    move.w  fault_count,%d2
    EXPECT_EQ_W %d2, 1

    move.l  %sp,%d2                 | A7 is the user one, still untouched
    EXPECT_EQ_L %d2, user_stack_top
    lea     user_stack_top,%a1
    moveq   #7,%d1
1:  move.w  -(%a1),%d2
    EXPECT_EQ_W %d2, 0xA5A5
    dbf     %d1,1b

    bra     pass

| ---------------------------------------------------------------------------
| The handler
| ---------------------------------------------------------------------------
| Bus error and address error take the same frame and the same treatment: say
| that software did the access, then be the memory that was not there.
    .globl  v_bus, v_addr
v_bus:
v_addr:
    movem.l %d0-%d1,-(%sp)
    addq.w  #1,fault_count          | the frame is eight bytes further up now,
                                    | which every (%sp) below allows for

    move.w  8+8(%sp),%d0            | the special status word
    ori.w   #0x8000,%d0             | RR: do not rerun the cycle
    move.w  %d0,8+8(%sp)

    btst    #8,%d0                  | RW: set for a read
    beq     1f

    | A read. Put what it should have found into the data input buffer image,
    | which is where the processor will take it from.
    move.w  #DEVICE_VAL,20+8(%sp)
    movem.l (%sp)+,%d0-%d1
    rte

1:  | A write. Record where it was going and what it was carrying, out of the
    | fault address and the data output buffer image.
    move.l  10+8(%sp),%d1
    move.l  %d1,fault_addr
    move.w  16+8(%sp),%d1
    move.w  %d1,fault_data
    movem.l (%sp)+,%d0-%d1
    rte

    UNEXPECTED_HANDLER
    .globl  v_illegal, v_divzero, v_chk, v_trapv, v_priv, v_trace
    .globl  v_linea, v_linef, v_format, v_trap, v_irq
v_illegal = v_unexpected
v_divzero = v_unexpected
v_chk     = v_unexpected
v_trapv   = v_unexpected
v_priv    = v_unexpected
v_trace   = v_unexpected
v_linea   = v_unexpected
v_linef   = v_unexpected
v_format  = v_unexpected
v_trap    = v_unexpected
v_irq     = v_unexpected

    PROGRAM_END

| ---------------------------------------------------------------------------
    .data
    .align  2
odd_place:  .long   0, 0

    .bss
    .align  2
user_stack:  .space 256
user_stack_top:
fault_count: .space 2
fault_addr:  .space 4
fault_data:  .space 2
loop_sum:    .space 4
