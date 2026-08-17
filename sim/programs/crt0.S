| crt0 -- what a C program needs before main and after it.
|
| The vector table, a zeroed .bss, a jump to main, and the translation of its
| return value into the mark the harness looks for: zero means every check
| passed, anything else is the number of the one that did not.

    .include "rd68011.inc"

    VECTORS
    RESULT_BLOCK

    .text
    .globl  _start
_start:
    | .bss, cleared the honest way rather than relying on the image being
    | padded with zeros -- which it is, but a crt0 that assumed so would be
    | wrong on any real part.
    lea     __bss_start,%a0
    lea     __bss_end,%a1
1:  cmpa.l  %a1,%a0
    bcc     2f
    clr.b   (%a0)+
    bra     1b

2:  jsr     main
    tst.l   %d0
    bne     3f
    bra     pass
3:  subq.l  #1,%d0                  | `fail` adds one back
    move.l  %d0,PROGRESS_ADDR
    bra     fail

| Nothing here expects an exception; C code that provokes one is a bug in the
| C code, and this says which vector it was.
    UNEXPECTED_HANDLER
    .globl  v_bus, v_addr, v_illegal, v_divzero, v_chk, v_trapv
    .globl  v_priv, v_trace, v_linea, v_linef, v_format, v_trap, v_irq
v_bus     = v_unexpected
v_addr    = v_unexpected
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
