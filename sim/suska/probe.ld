OUTPUT_FORMAT("elf32-m68k")
OUTPUT_ARCH(m68k)
ENTRY(_start)
SECTIONS {
    .vectors 0x00000000 : { KEEP(*(.vectors)) }
    .text    0x00000100 : { *(.text) }
    /DISCARD/ : { *(.comment) *(.note.*) *(.eh_frame) }
}
