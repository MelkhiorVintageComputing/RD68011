# RD68011 pinout

Derived from **Table 3-4, Signal Summary** and §3.1–3.11 of
`Inputs/doc/MC68030_Doc_More_Readable/MC68000UM_split/06-section-03-signal-description.pdf`
(Figure 3-1 is the MC68000/MC68HC000/**MC68010** signal set).

The original has three-state and bidirectional pins. This core has none: every such pin is
split into an input `_i`, an output `_o` and an output-enable `_oe`. An external wrapper
recombines them:

```systemverilog
assign pad = core_oe ? core_o : 1'bz;   // three-state pin
assign core_i = pad;
assign pad = core_oe ? 1'b0 : 1'bz;     // open-drain pin (RESET, HALT)
```

`_oe` is **active high — asserted means the core is driving**. Active-low signals keep the
`_n` suffix and are active-low *on the pin*, i.e. `as_n_o == 0` means AS asserted.

## Port list

### Clock

| Port | Dir | Notes |
|---|---|---|
| `clk` | in | Free-running square wave, never gated (§3.9). Both edges are used: one bus state S0–S7 per half period. |
| `rst_n` | in | **Not an MC68010 pin.** Asynchronous hardware reset for simulation/FPGA bring-up, so that every register has a defined value without power-on initialisation. Real reset behaviour is the RESET/HALT pin pair below. |

### Address bus (§3.1)

| Port | Dir | Notes |
|---|---|---|
| `a_o[23:1]` | out | A1–A23. During interrupt acknowledge, A1–A3 carry the level and A4–A23 are driven high. |
| `a_oe` | out | Negated on bus relinquish **and** while RESET is asserted (Table 3-4: Hi-Z on RESET = Yes). |

There is no A0 pin; byte selection is by `UDS`/`LDS`.

### Data bus (§3.2)

| Port | Dir | Notes |
|---|---|---|
| `d_i[15:0]` | in | Sampled on the falling edge of S6 on a read; vector number on D0–D7 during interrupt acknowledge. |
| `d_o[15:0]` | out | |
| `d_oe` | out | Asserted only during the data phase of a write. Negated on bus relinquish and while RESET is asserted. |

### Asynchronous bus control (§3.3)

| Port | Dir | Notes |
|---|---|---|
| `as_n_o`, `as_oe` | out | Address strobe. |
| `rw_o`, `rw_oe` | out | High = read, low = write. |
| `uds_n_o`, `lds_n_o`, `ds_oe` | out | Upper/lower data strobes, shared enable (Table 3-1 gives the byte-lane rules). |
| `dtack_n_i` | in | Data transfer acknowledge. |

`as_oe`, `rw_oe` and `ds_oe` all follow the bus-relinquish enable only — Table 3-4 says
these are *not* Hi-Z on RESET, unlike the address and data buses. They are kept as separate
ports rather than one signal so a wrapper can pad them independently.

### Bus arbitration (§3.4)

| Port | Dir | Notes |
|---|---|---|
| `br_n_i` | in | Bus request; may be asserted at any time. |
| `bg_n_o` | out | Bus grant. Never three-stated — no `_oe`. |
| `bgack_n_i` | in | Bus grant acknowledge. Three-wire arbitration; two-wire works by tying this negated. |

### Interrupt control (§3.5)

| Port | Dir | Notes |
|---|---|---|
| `ipl_n_i[2:0]` | in | Encoded level, active low; `ipl_n_i[0]` is the LSB. 7 is non-maskable. Must be held until acknowledged. Synchronised internally. |

### System control (§3.6)

| Port | Dir | Notes |
|---|---|---|
| `berr_n_i` | in | Bus error. With HALT, selects rerun vs. exception processing. |
| `reset_n_i` | in | External reset input; with HALT asserted, starts initialisation. |
| `reset_n_o`, `reset_n_oe` | out | Open drain. `reset_n_o` is constant 0; the `RESET` instruction asserts `reset_n_oe` for 124 clocks to reset peripherals without disturbing the core. |
| `halt_n_i` | in | Halts bus activity at the end of the current cycle. |
| `halt_n_o`, `halt_n_oe` | out | Open drain. `halt_n_o` is constant 0; driven on double bus fault. |

There is no `MODE` pin — that is MC68HC001/MC68EC000 only.

### M6800 peripheral control (§3.7)

| Port | Dir | Notes |
|---|---|---|
| `e_o` | out | Free-running enable: a 10-clock period, **6 low then 4 high**, from an internal ring counter that runs regardless of bus state. Never three-stated. |
| `vpa_n_i` | in | Valid peripheral address; also requests autovectoring during interrupt acknowledge. |
| `vma_n_o`, `vma_oe` | out | Valid memory address; asserted only in response to `VPA`. |

Because a real ring counter "may come up in any state", `E`'s phase relative to `CLK` is
not architectural. Ours starts from a defined reset state; that is a documented divergence,
and it is a divergence in our favour (deterministic simulation).

### Processor status (§3.8)

| Port | Dir | Notes |
|---|---|---|
| `fc_o[2:0]` | out | Valid whenever AS is asserted. |
| `fc_oe` | out | Bus relinquish only. |

Table 3-3 function codes:

| FC2 FC1 FC0 | Address space |
|---|---|
| 0 0 0 | (undefined, reserved) |
| 0 0 1 | User data |
| 0 1 0 | User program |
| 0 1 1 | (undefined, reserved) |
| 1 0 0 | (undefined, reserved) |
| 1 0 1 | Supervisor data |
| 1 1 0 | Supervisor program |
| 1 1 1 | CPU space |

CPU space (7) covers interrupt acknowledge and, on the MC68010, breakpoint acknowledge.
`MOVES` drives the function code from `SFC`/`DFC` instead, so all eight encodings —
including the reserved ones — can appear on the pins.

## Output-enable domains

Table 3-4's two Hi-Z columns give exactly three behaviours:

| Enable | Covers | Negated when |
|---|---|---|
| `a_oe`, `d_oe` | address bus, data bus | bus relinquished **or** RESET asserted |
| `as_oe`, `rw_oe`, `ds_oe`, `vma_oe`, `fc_oe` | AS, R/W, UDS, LDS, VMA, FC | bus relinquished |
| `reset_n_oe`, `halt_n_oe` | RESET, HALT | open drain — asserted only to pull low |

`bg_n_o` and `e_o` have no enable; they are always driven.
