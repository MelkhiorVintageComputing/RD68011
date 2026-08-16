# RD68011 coding standard

The RTL must elaborate under **iverilog 12.0, Verilator 5.032, yosys 0.52 and Vivado
2025.2**. That intersection, not the SystemVerilog LRM, is the language this project is
written in. `make lint` runs the first three; `make synth` runs the fourth.

Everything below marked *(measured)* was established by trying it on this machine, not
assumed.

## The subset

**yosys is the constraint.** It is markedly stricter than the other three, so it decides
what the RTL may use.

### Forbidden — yosys rejects it *(measured)*

| Construct | What happens |
|---|---|
| `import pkg::*;` in a module header | `ERROR: syntax error, unexpected TOK_ID` |
| `import pkg::*;` in the module body | `ERROR: syntax error, unexpected TOK_PACKAGESEP` |
| `import pkg::name;` | same |

There is no working form of `import`. **Refer to package members with their full scope
every time**: `rd68011_pkg::FC_SUPER_P`, `rd68011_pkg::bus_state_e`. It is verbose; it is
also unambiguous about where a constant came from, which for a design transcribed out of a
manual is worth something.

### Allowed — all four tools accept it *(measured)*

- `package` / `endpackage` with `localparam`, `typedef enum`, `typedef struct packed`
- enum and packed-struct **variables** inside modules, including struct field assignment
  (`r.a <= 4'd1`) and enum comparison
- `always_ff` / `always_comb`, `unique case`, `logic`, `'0` fill
- **Dual-edge design**: a `posedge clk` block and a `negedge clk` block in the same module.
  yosys infers `$_DFF_PN0_` and `$_DFF_NN0_` correctly. This matters — the whole bus-state
  scheme depends on it.
- Asynchronous active-low reset in the sensitivity list

### Forbidden — project rules rather than tool limits

| Rule | Why |
|---|---|
| No `initial` blocks in `rtl/` | ASIC has no power-on state |
| No initialisers on register declarations | same |
| No `assert property` / SVA in `rtl/` | iverilog and yosys do not support it |
| No interfaces, classes, queues, dynamic arrays, `unions` | not portable |
| No `$random`, `$display` in `rtl/` | not synthesisable |
| No non-constant loop bounds | not synthesisable |
| No user types on module **ports** | keeps yosys and cross-tool elaboration happy; use plain `logic [N:0]` and convert inside |
| No inline `lint_off` pragmas | waivers go in `rtl/rd68011.vlt` with a reason |

Testbenches under `sim/` are not bound by these: they only ever run under iverilog or
Verilator, and may use `initial`, `$display`, tasks, `realtime` and the rest.

## Reset

Every register is reset. There is no exception and no "don't care" register.

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    q <= '0;          // explicit value for every register in the block
  end else begin
    q <= d;
  end
end
```

`rst_n` is **not** an MC68010 pin. It is the hardware/simulation initialisation input that
gives every flop a defined value; the architectural reset behaviour (RESET+HALT asserted
together, vector fetch from 0 and 4) is a separate sequence driven by `reset_n_i` and
`halt_n_i`. Do not conflate them.

## Naming

| Suffix | Meaning |
|---|---|
| `_n` | active low **at the pin** — `as_n_o == 0` means AS asserted |
| `_i` | input pin |
| `_o` | output pin |
| `_oe` | output enable, **active high = core is driving** |
| `_q` | registered version of a combinational signal, where both exist |
| `_e` | enum type name (`bus_state_e`) |
| `_t` | struct type name |

Modules are `rd68011_<unit>` in `rtl/rd68011_<unit>.sv`, one module per file.
Package members are `UPPER_SNAKE` for constants and `UPPER` for enum values.

## Comments

Cite the source. A line of RTL that implements something from the manual says which page
it came from:

```systemverilog
// UM 3.7: six clocks low, four high. Specification 41 measures the transition
// from CLK low, so this lives in the negative-edge domain.
```

`UM` is `MC68000UM_split`, `PRM` is `M68000PRM_split`. Specification numbers refer to
`ac-electrical-specifications.csv`. This is not decoration: when a behaviour is later
questioned, the citation is what settles it.

## Lint waivers

Two exist, both in `rtl/rd68011.vlt`:

- `UNUSEDPARAM` on `rd68011_pkg.sv` — the package is a catalogue of architectural
  constants and no single module uses all of them.
- `UNUSEDSIGNAL` on the top level's `unused_inputs` sink, which names inputs the design
  does not consume yet so that the list shrinks visibly as the design fills in.

Two file-format gotchas, both hit in practice *(measured)*: `` `verilator_config `` must be
the first token in a `.vlt` file, and **no comment in it may start with the word
"verilator"** — Verilator parses those as directives and reports a syntax error. Waiver
globs are matched against the path as given on the command line, so `*rtl/foo.sv` matches
and `*/rtl/foo.sv` does not.

## Known tool quirks *(measured)*

| Tool | Quirk | Workaround |
|---|---|---|
| iverilog | `always_comb` that reads nothing warns "process has no sensitivities" | drive constants with `assign` |
| iverilog | declarations inside an unnamed `begin`/`end` are a syntax error | declare at module scope |
| Verilator | `-Wall` flags every unused package parameter | the `.vlt` waiver above |
| yosys | no `import` in any form | fully-scoped references |
| Vivado | needs the package file read before its users | `synth.tcl` sorts `rd68011_pkg.sv` first |

Add to this table whenever a tool surprises you. It is cheaper than rediscovering it.
