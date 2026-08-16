// RD68011 - SystemVerilog MC68010
//
// Shared types and constants.
//
// References are to the split Motorola manuals under
// Inputs/doc/MC68030_Doc_More_Readable/ :
//   UM  = MC68000UM_split  (M68000 8-/16-/32-Bit Microprocessors User's Manual)
//   PRM = M68000PRM_split  (M68000 Family Programmer's Reference Manual)

`ifndef RD68011_PKG_SV
`define RD68011_PKG_SV

package rd68011_pkg;

  // ---------------------------------------------------------------------------
  // Function codes -- UM Table 3-3
  // ---------------------------------------------------------------------------
  localparam logic [2:0] FC_UNDEF0   = 3'b000;
  localparam logic [2:0] FC_USER_D   = 3'b001;
  localparam logic [2:0] FC_USER_P   = 3'b010;
  localparam logic [2:0] FC_UNDEF3   = 3'b011;
  localparam logic [2:0] FC_UNDEF4   = 3'b100;
  localparam logic [2:0] FC_SUPER_D  = 3'b101;
  localparam logic [2:0] FC_SUPER_P  = 3'b110;
  localparam logic [2:0] FC_CPU      = 3'b111;

  // ---------------------------------------------------------------------------
  // Bus states -- UM section 5. One state per CLK half period; a minimum-length
  // asynchronous cycle is S0..S7, i.e. four clocks. Wait states are inserted by
  // repeating S4/S5 until DTACK, BERR or VPA is recognised.
  // ---------------------------------------------------------------------------
  typedef enum logic [3:0] {
    BS_S0    = 4'd0,
    BS_S1    = 4'd1,
    BS_S2    = 4'd2,
    BS_S3    = 4'd3,
    BS_S4    = 4'd4,
    BS_S5    = 4'd5,
    BS_S6    = 4'd6,
    BS_S7    = 4'd7,
    BS_IDLE  = 4'd8,   // bus held, no cycle in progress
    BS_WAIT  = 4'd9,   // the repeated S4/S5 wait pair
    BS_ARB   = 4'd10,  // bus relinquished to an external master
    BS_HALT  = 4'd11,  // halted by HALT input or double bus fault
    BS_M6800 = 4'd12   // synchronous cycle, waiting on E -- UM Appendix B
  } bus_state_e;

  // ---------------------------------------------------------------------------
  // Operand sizes
  // ---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    SZ_BYTE = 2'b00,
    SZ_WORD = 2'b01,
    SZ_LONG = 2'b10
  } opsize_e;

  // ---------------------------------------------------------------------------
  // Bus cycle kinds the sequencer can request of the bus interface.
  // ---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    CT_READ  = 3'd0,
    CT_WRITE = 3'd1,
    CT_RMW_R = 3'd2,  // TAS read half, AS stays asserted
    CT_RMW_W = 3'd3,  // TAS write half
    CT_IACK  = 3'd4,  // interrupt acknowledge, CPU space
    CT_BKPT  = 3'd5   // breakpoint acknowledge, CPU space -- MC68010 only
  } cycle_kind_e;

  // How a bus cycle ended.
  typedef enum logic [2:0] {
    CE_NONE    = 3'd0,  // still running
    CE_DTACK   = 3'd1,  // normal termination
    CE_BERR    = 3'd2,  // bus error -> exception
    CE_RERUN   = 3'd3,  // BERR + HALT -> retry the cycle
    CE_VPA     = 3'd4,  // M6800 synchronous termination / autovector
    CE_AVEC    = 3'd5   // autovector during interrupt acknowledge
  } cycle_end_e;

  // ---------------------------------------------------------------------------
  // Status register bit positions -- PRM section 1
  // ---------------------------------------------------------------------------
  localparam int SR_C  = 0;
  localparam int SR_V  = 1;
  localparam int SR_Z  = 2;
  localparam int SR_N  = 3;
  localparam int SR_X  = 4;
  localparam int SR_I0 = 8;
  localparam int SR_S  = 13;
  localparam int SR_T  = 15;   // MC68010 has a single trace bit (T0/T1 is 68020+)

  localparam logic [15:0] SR_IMPLEMENTED = 16'b1010_0111_0001_1111;

  // ---------------------------------------------------------------------------
  // Exception vector numbers -- UM Table 6-2 / PRM Appendix B
  // ---------------------------------------------------------------------------
  localparam logic [7:0] VEC_RESET_SP    = 8'd0;
  localparam logic [7:0] VEC_RESET_PC    = 8'd1;
  localparam logic [7:0] VEC_BUS_ERROR   = 8'd2;
  localparam logic [7:0] VEC_ADDR_ERROR  = 8'd3;
  localparam logic [7:0] VEC_ILLEGAL     = 8'd4;
  localparam logic [7:0] VEC_ZERO_DIV    = 8'd5;
  localparam logic [7:0] VEC_CHK         = 8'd6;
  localparam logic [7:0] VEC_TRAPV       = 8'd7;
  localparam logic [7:0] VEC_PRIVILEGE   = 8'd8;
  localparam logic [7:0] VEC_TRACE       = 8'd9;
  localparam logic [7:0] VEC_LINE_A      = 8'd10;
  localparam logic [7:0] VEC_LINE_F      = 8'd11;
  localparam logic [7:0] VEC_FORMAT_ERR  = 8'd14;  // MC68010: RTE on a bad frame
  localparam logic [7:0] VEC_UNINIT_IRQ  = 8'd15;
  localparam logic [7:0] VEC_SPURIOUS    = 8'd24;
  localparam logic [7:0] VEC_AUTOVEC0    = 8'd24;  // autovector n is 24+n
  localparam logic [7:0] VEC_TRAP0       = 8'd32;

  // ---------------------------------------------------------------------------
  // Stack frame format codes -- UM section 6. The MC68010 defines two:
  // format 0 (four words) for everything except bus and address error, and
  // format 8 (twenty-nine words) for those two.
  // ---------------------------------------------------------------------------
  localparam logic [3:0] FRAME_SHORT = 4'h0;
  localparam logic [3:0] FRAME_FAULT = 4'h8;

  // ---------------------------------------------------------------------------
  // M6800 enable -- UM section 3.7: ten clock periods, six low then four high.
  // Specification 41 measures the E transition from CLK low, so E is generated
  // in the negative-edge domain and these are counted in whole clocks.
  // ---------------------------------------------------------------------------
  localparam logic [3:0] E_PERIOD_CLKS = 4'd10;
  localparam logic [3:0] E_LOW_CLKS    = 4'd6;

endpackage

`endif
