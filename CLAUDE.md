# RD68011 — SystemVerilog MC68010

A from-scratch SystemVerilog implementation of the Motorola MC68010, targeting FPGA
(short-term priority) and ASIC.

## Goals

1. **100 % software compatibility** with a real MC68010.
2. **Bus-timing compatibility** — the bus-state (S0–S7) behaviour of the original.
3. Instruction *cycle* timings need not match, but **every divergence must be measured,
   reported and justified** in `doc/timing-divergences.md`.

## Hard rules

These are not style preferences. Breaking one is a bug.

### `Inputs/` is immutable

Nothing under `Inputs/` may be modified, ever. New inputs may be *added* (as submodules or
new directories), but once added they are frozen too.

### `Inputs/Suska_Configware/` is never a source for RTL

`Inputs/Suska_Configware/68K10/` is another MC68010-compatible design, in VHDL. It exists
here **only** to help validate testbenches — you may run it under ghdl and compare
testbench behaviour against it. You may **not** read it to work out how to write our RTL.
Anyone (human or agent) writing code in `rtl/` must not open files in that directory.

The golden reference is the documentation in `Inputs/doc/`. Suska is known to diverge from
the real chip on parts of the bus protocol (notably interrupts), so testbenches must
tolerate those divergences rather than encode them.

### No initialisation outside reset

ASIC is a target, so there is no power-on register state. No `initial` blocks in `rtl/`,
no declaration-site initialisers on anything that infers a register, no relying on `'x`
resolving to a useful value. Every register gets its value from the reset branch of its
`always_ff`.

### Split I/O pins

The original's bidirectional and three-state pins become separate `_i` / `_o` / `_oe`
signals. An external wrapper converts to real three-state pins where a design needs them.
See `doc/pinout.md`.

### Portable SystemVerilog only

The RTL must elaborate under **iverilog, Verilator, yosys and Vivado**. See
`doc/coding-standard.md` for the permitted subset. `make lint` is the gate.

## Layout

| Path | What |
|---|---|
| `rtl/` | the processor, one module per file, prefix `rd68011_` |
| `tools/` | microcode assembler, test runners, doc generators (Python) |
| `sim/` | testbenches, bus-slave models, test programs |
| `doc/` | pinout, coding standard, compliance and divergence reports |
| `Inputs/doc/` | Motorola manuals, split by section, with machine-readable AC specs |
| `Inputs/ref/` | reference implementations used as oracles (not as RTL sources) |
| `Inputs/tests/` | external test vectors |

## Documentation map

Everything authoritative lives in `Inputs/doc/MC68030_Doc_More_Readable/`. **Ignore the
`MC68030*` and `MC68881*` directories** — different processors, irrelevant here.

| Need | Read |
|---|---|
| Pin behaviour | `MC68000UM_split/06-section-03-signal-description.pdf` |
| Bus protocol | `MC68000UM_split/08-section-05-16-bit-bus-operation.pdf` (40 pp) |
| Exceptions, stack frames | `MC68000UM_split/09-section-06-exception-processing.pdf` |
| MC68010 cycle counts | `MC68000UM_split/12-section-09-mc68010-instruction-execution-times.pdf` |
| Bus timing figures | `MC68000UM_split/figure-10-*.md` + `ac-electrical-specifications.csv` |
| Loop mode | `MC68000UM_split/15-appendix-a-mc68010-loop-mode-operation.pdf` |
| M6800 interface | `MC68000UM_split/16-appendix-b-m6800-peripheral-interface.pdf` |
| Instruction semantics | `M68000PRM_split/07-section-04-integer-instructions.pdf`, `09-section-06-supervisor-instructions.pdf` |
| Opcode encodings | `M68000PRM_split/11-section-08-instruction-format-summary.pdf` |
| Which instructions exist | `M68000PRM_split/INSTRUCTIONS-BY-CPU.md` (MC68010 = 89 instructions) |

`MC68000UM_split/README.md` documents the manual's own internal contradictions — read it
before "correcting" a spec that looks wrong.

The PDFs have reconstructed outlines and are best read with
`pdftotext -layout <file> -` for a specific section.

## Building and checking

```sh
make lint     # elaborate every rtl module under all four tools
make sim      # directed testbenches (iverilog)
make harte    # one SingleStepTests opcode file: make harte OP=MOVE.w N=200
make harte-all  # the whole sweep, every opcode file the ISA covers
make ucode    # regenerate the microcode ROMs from tools/ucode/
make synth    # Vivado synthesis + timing report
make check    # ucode-check, lint and sim
```

## Tooling notes

- iverilog 12.0, Verilator 5.032, yosys 0.52, ghdl, Vivado 2025.2.
- `m68k-linux-gnu-gcc` / `-as` / `-objcopy` build test programs; `-m68010` works.
- No gtkwave — dump VCD and inspect with a text tool or an external viewer.
