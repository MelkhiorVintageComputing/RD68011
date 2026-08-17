-- The Suska WF68K10 behind RD68011's pin bundle.
--
-- WHY THIS EXISTS
--
-- The AC-timing testbench asks one question of two processors: where does each
-- pin move, in nanoseconds, relative to the clock. To ask it once rather than
-- twice, both designs have to present the same pins. This entity does that for
-- the Suska core -- our 32-pin bundle outside, its own port list inside.
--
-- Keeping the whole adaptation in VHDL means the SystemVerilog side sees one
-- identical interface for either DUT, and the mixed-language boundary is a
-- plain std_logic port list, which is the case Vivado supports best.
--
-- WHAT IT WAS WRITTEN FROM
--
-- CLAUDE.md permits Inputs/Suska_Configware/ to be *run* to validate
-- testbenches and never to be *read* to work out how to write our own code.
-- Everything below comes from the entity declaration of wf68k10_top.vhd -- the
-- port list, which is what an instantiation needs and is the whole of the
-- sanctioned use -- and from the MC68010 user manual. No architecture body was
-- opened.
--
-- Four of the mappings are hypotheses rather than facts, because a port list
-- gives names and directions and not polarities. Each is marked below, and each
-- is confirmed by *observing* this core run, never by reading it; what the
-- observations said is recorded in doc/ac-timing.md.

library ieee;
use ieee.std_logic_1164.all;

-- The Suska units are analysed into a library of their own, both here and in
-- the existing ghdl flow (the Makefile's --work=wf68k10), so the instantiation
-- below names it rather than relying on whichever library this file lands in.
library wf68k10;

entity wf68k10_pins is
    generic (
        -- Passed through, so the testbench chooses them once.
        VERSION         : std_logic_vector(31 downto 0) := x"20210815";
        NO_PIPELINE     : boolean := false;
        NO_LOOP         : boolean := false;
        NO_INDEXSCALING : boolean := true
    );
    port (
        clk        : in  std_logic;
        rst_n      : in  std_logic;                     -- no counterpart; ignored

        a_o        : out std_logic_vector(23 downto 1);
        a_oe       : out std_logic;

        d_i        : in  std_logic_vector(15 downto 0);
        d_o        : out std_logic_vector(15 downto 0);
        d_oe       : out std_logic;

        as_n_o     : out std_logic;
        as_oe      : out std_logic;
        rw_o       : out std_logic;
        rw_oe      : out std_logic;
        uds_n_o    : out std_logic;
        lds_n_o    : out std_logic;
        ds_oe      : out std_logic;
        dtack_n_i  : in  std_logic;

        br_n_i     : in  std_logic;
        bg_n_o     : out std_logic;
        bgack_n_i  : in  std_logic;

        ipl_n_i    : in  std_logic_vector(2 downto 0);

        berr_n_i   : in  std_logic;
        reset_n_i  : in  std_logic;
        reset_n_o  : out std_logic;
        reset_n_oe : out std_logic;
        halt_n_i   : in  std_logic;
        halt_n_o   : out std_logic;
        halt_n_oe  : out std_logic;

        e_o        : out std_logic;
        vpa_n_i    : in  std_logic;
        vma_n_o    : out std_logic;
        vma_oe     : out std_logic;

        fc_o       : out std_logic_vector(2 downto 0);
        fc_oe      : out std_logic;

        -- Not MC68010 pins, and so not part of the bundle: RMC is an MC68020
        -- signal and DBEN is an external data-buffer enable. They are brought
        -- out anyway because RMC marks a read-modify-write cycle, which makes
        -- aligning the two traces much easier. Nothing asserts against them.
        rmc_n_x    : out std_logic;
        dben_n_x   : out std_logic
    );
end entity wf68k10_pins;

architecture wrap of wf68k10_pins is

    signal adr      : std_logic_vector(31 downto 0);
    signal fc       : std_logic_vector(2 downto 0);
    signal bus_en   : std_logic;
    signal data_en  : std_logic;
    signal reset_out, halt_outn : std_logic;
    signal avecn, vpan : std_logic;

begin

    -- HYPOTHESIS 1: VPA and AVEC. We have one pin where this core has two.
    -- doc/pinout.md records that our vpa_n_i "also requests autovectoring
    -- during interrupt acknowledge", which is UM 3.7 and 6.3.2 -- one signal
    -- doing both jobs, told apart by whether the cycle is in CPU space. So the
    -- one pin is fanned out by function code, which is exactly the distinction
    -- the manual draws.
    avecn <= vpa_n_i when fc = "111" else '1';
    vpan  <= vpa_n_i when fc /= "111" else '1';

    dut : entity wf68k10.WF68K10_TOP
        generic map (
            VERSION         => VERSION,
            NO_PIPELINE     => NO_PIPELINE,
            NO_LOOP         => NO_LOOP,
            NO_INDEXSCALING => NO_INDEXSCALING)
        port map (
            CLK       => clk,
            ADR_OUT   => adr,
            DATA_IN   => d_i,
            DATA_OUT  => d_o,
            DATA_EN   => data_en,
            BERRn     => berr_n_i,
            RESET_INn => reset_n_i,
            RESET_OUT => reset_out,
            HALT_INn  => halt_n_i,
            HALT_OUTn => halt_outn,
            FC_OUT    => fc,
            AVECn     => avecn,
            IPLn      => ipl_n_i,
            DTACKn    => dtack_n_i,
            ASn       => as_n_o,
            RWn       => rw_o,
            RMCn      => rmc_n_x,
            UDSn      => uds_n_o,
            LDSn      => lds_n_o,
            DBENn     => dben_n_x,
            BUS_EN    => bus_en,
            E         => e_o,
            VMAn      => vma_n_o,
            VMA_EN    => vma_oe,
            VPAn      => vpan,
            BRn       => br_n_i,
            BGn       => bg_n_o,
            BGACKn    => bgack_n_i,
            K6800n    => '1');   -- no MC68010 counterpart; sim/suska ties it too

    a_o <= adr(23 downto 1);
    fc_o <= fc;

    -- HYPOTHESIS 2: BUS_EN is one active-high "the core is driving" for the
    -- whole bus. Our seven enables collapse onto it. That is a real structural
    -- divergence rather than a bug -- table 3-4 gives three distinct release
    -- behaviours and this core exposes one -- and it is recorded as such.
    a_oe  <= bus_en;
    as_oe <= bus_en;
    rw_oe <= bus_en;
    ds_oe <= bus_en;
    fc_oe <= bus_en;

    -- HYPOTHESIS 3: DATA_EN is active high for "driving", like our d_oe.
    d_oe <= data_en;

    -- HYPOTHESIS 4: RESET_OUT is active *high* for asserted, where HALT_OUTn is
    -- active low. The naming asymmetry in the port list is the only evidence,
    -- so it is confirmed by running a RESET instruction and watching which way
    -- the pin goes. Both are open drain here, as ours are: the level is a
    -- constant 0 and the enable does the work (doc/pinout.md).
    reset_n_o  <= '0';
    reset_n_oe <= reset_out;
    halt_n_o   <= '0';
    halt_n_oe  <= not halt_outn;

end architecture wrap;
