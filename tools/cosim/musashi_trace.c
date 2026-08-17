/* The oracle: Musashi running the same program, printing the same trace.
 *
 *   musashi_trace <image.hex> <instructions> [> trace]
 *
 * Musashi is an instruction-set simulator with no notion of a bus cycle, so it
 * cannot say anything about the half of this project that is bus behaviour.
 * What it can say is what the architectural state should be after every
 * instruction of a real program -- which is the half the reference vectors
 * check one instruction at a time and never in sequence.
 *
 * One line per instruction, printed before it runs: the address, the opcode
 * about to execute, the status register, and all sixteen registers. The opcode
 * is there so that tools/cosim/compare.py can tell when a flag is one the
 * architecture leaves undefined. sim/tb/core_program_tb.sv prints the
 * same line from the RTL, and tools/cosim/compare.py finds the first place
 * they stop agreeing.
 *
 * The memory is the one sim/models/rd68011_slave.sv models in the core
 * testbench: 32K of word-wide RAM at zero, aliased over the low 4M, which is
 * everything the test programs use.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "m68k.h"

#define MEM_WORDS  (1u << 14)          /* rd68011_slave's ADDR_BITS */
#define MEM_BYTES  (MEM_WORDS * 2u)
#define MEM_MASK   (MEM_BYTES - 1u)

static unsigned char mem[MEM_BYTES];

static unsigned long stop_after;
static unsigned long executed;
static int           halt;

/* The done word the programs write, at the address sim/programs/link.ld
 * fixes. Running past it would trace the tight loop they park in. */
#define DONE_ADDR 0x0408u

unsigned int m68k_read_memory_8(unsigned int address)
{
    return mem[address & MEM_MASK];
}

unsigned int m68k_read_memory_16(unsigned int address)
{
    unsigned int a = address & MEM_MASK;
    return ((unsigned int)mem[a] << 8) | mem[(a + 1) & MEM_MASK];
}

unsigned int m68k_read_memory_32(unsigned int address)
{
    return (m68k_read_memory_16(address) << 16) |
            m68k_read_memory_16(address + 2);
}

void m68k_write_memory_8(unsigned int address, unsigned int value)
{
    mem[address & MEM_MASK] = (unsigned char)value;
}

void m68k_write_memory_16(unsigned int address, unsigned int value)
{
    unsigned int a = address & MEM_MASK;
    mem[a]                 = (unsigned char)(value >> 8);
    mem[(a + 1) & MEM_MASK] = (unsigned char)value;
}

void m68k_write_memory_32(unsigned int address, unsigned int value)
{
    m68k_write_memory_16(address, value >> 16);
    m68k_write_memory_16(address + 2, value);
}

/* The disassembler's reads must not have side effects; here they are the same
 * memory either way. */
unsigned int m68k_read_disassembler_16(unsigned int a) { return m68k_read_memory_16(a); }
unsigned int m68k_read_disassembler_32(unsigned int a) { return m68k_read_memory_32(a); }

static void trace(unsigned int pc)
{
    static const int regs[16] = {
        M68K_REG_D0, M68K_REG_D1, M68K_REG_D2, M68K_REG_D3,
        M68K_REG_D4, M68K_REG_D5, M68K_REG_D6, M68K_REG_D7,
        M68K_REG_A0, M68K_REG_A1, M68K_REG_A2, M68K_REG_A3,
        M68K_REG_A4, M68K_REG_A5, M68K_REG_A6, M68K_REG_A7,
    };
    int i;

    if (halt)
        return;
    if (executed >= stop_after || m68k_read_memory_16(DONE_ADDR) != 0) {
        halt = 1;
        return;
    }
    executed++;

    printf("%06x %04x %04x", pc & 0xFFFFFF,
           m68k_read_memory_16(pc), (unsigned)m68k_get_reg(NULL, M68K_REG_SR));
    for (i = 0; i < 16; i++)
        printf(" %08x", (unsigned)m68k_get_reg(NULL, regs[i]));
    printf("\n");
}

static int load_hex(const char *path)
{
    FILE *f = fopen(path, "r");
    char line[64];
    unsigned long i = 0;

    if (!f) {
        fprintf(stderr, "cannot open %s\n", path);
        return 0;
    }
    while (fgets(line, sizeof line, f) && i < MEM_WORDS) {
        unsigned int w;
        if (sscanf(line, "%x", &w) != 1)
            continue;
        mem[i * 2]     = (unsigned char)(w >> 8);
        mem[i * 2 + 1] = (unsigned char)w;
        i++;
    }
    fclose(f);
    return i > 0;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <image.hex> <instructions>\n", argv[0]);
        return 2;
    }
    stop_after = strtoul(argv[2], NULL, 0);

    memset(mem, 0, sizeof mem);
    if (!load_hex(argv[1]))
        return 1;

    m68k_init();
    m68k_set_cpu_type(M68K_CPU_TYPE_68010);
    m68k_set_instr_hook_callback(trace);
    m68k_pulse_reset();

    /* In slices, so the hook's decision to stop takes effect promptly. */
    while (!halt)
        m68k_execute(1000);

    return 0;
}
