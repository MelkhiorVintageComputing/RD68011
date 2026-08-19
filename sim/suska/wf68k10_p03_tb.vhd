-- Instruction continuation on the Suska WF68K10: does RTE come back from a
-- format $8 frame?
--
-- Companion to sim/suska/wf68k10_ssw_tb.vhd, which asks what the frame *says*.
-- This asks whether the processor will act on it. sim/programs/p03_fault.S is
-- the MC68010's reason for existing written the way an operating system writes
-- it -- UM 6.3.9.2's "alternate method of handling a bus error", where the
-- handler completes the faulted access in software, sets the rerun flag so the
-- processor does not redo the cycle, and returns through RTE. It passes on
-- RD68011 through `make programs`.
--
-- The fault window is where p03_fault.args puts it, and the acknowledge is
-- asserted alongside the bus error because that is what our own slave model
-- does at that address. Both processors take the fault and build a frame from
-- this stimulus, so it is adequate for both; what differs is the return.
--
-- CLAUDE.md permits Inputs/Suska_Configware/68K10/ to be *run* to validate
-- testbenches and never to be read to work out how to write our RTL. This is
-- the running.
--
-- It is very nearly a copy of wf68k10_ssw_tb.vhd, differing in the image, the
-- fault window and what it reports. Two short files were preferred to one with
-- generics because ghdl's handling of string generics is awkward and the
-- duplication is inert -- neither file is on any critical path and both exist
-- to ask one question each.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity wf68k10_p03_tb is
end entity wf68k10_p03_tb;

architecture sim of wf68k10_p03_tb is

    constant CLK_PERIOD : time := 125 ns;   -- 8 MHz, the part's own speed

    -- Where sim/programs/link.ld and p06_ssw.S put things, in words.
    constant W_RESULT  : integer := 16#400# / 2;
    constant W_DONE    : integer := 16#408# / 2;
    constant W_PROG    : integer := 16#404# / 2;

    signal clk       : std_logic := '0';
    signal adr_out   : std_logic_vector(31 downto 0);
    signal data_in   : std_logic_vector(15 downto 0) := (others => '0');
    signal data_out  : std_logic_vector(15 downto 0);
    signal data_en   : std_logic;
    signal berrn     : std_logic := '1';
    signal reset_inn : std_logic := '0';
    signal reset_out : std_logic;
    signal halt_inn  : std_logic := '0';
    signal halt_outn : std_logic;
    signal fc_out    : std_logic_vector(2 downto 0);
    signal avecn     : std_logic := '1';
    signal ipln      : std_logic_vector(2 downto 0) := "111";
    signal dtackn    : std_logic := '1';
    signal asn       : std_logic;
    signal rwn       : std_logic;
    signal rmcn      : std_logic;
    signal udsn      : std_logic;
    signal ldsn      : std_logic;
    signal dbenn     : std_logic;
    signal bus_en    : std_logic;
    signal e         : std_logic;
    signal vman      : std_logic;
    signal vma_en    : std_logic;
    signal vpan      : std_logic := '1';
    signal brn       : std_logic := '1';
    signal bgn       : std_logic;
    signal bgackn    : std_logic := '1';
    signal k6800n    : std_logic := '1';

    -- 32 KB, which the image fits inside with room to spare.
    type mem_t is array (0 to 16383) of std_logic_vector(15 downto 0);

    impure function load(path : string) return mem_t is
        file f      : text;
        variable l  : line;
        variable v  : std_logic_vector(15 downto 0);
        variable good : boolean;
        variable m  : mem_t := (others => (others => '0'));
        variable i  : integer := 0;
    begin
        file_open(f, path, read_mode);
        while not endfile(f) and i <= mem_t'high loop
            readline(f, l);
            hread(l, v, good);
            if good then
                m(i) := v;
                i := i + 1;
            end if;
        end loop;
        file_close(f);
        return m;
    end function;

    signal mem : mem_t := load("p03_fault.hex");

    -- The one address p03_fault.S treats as a device that is not there.
    -- p03_fault.args gives our own harness +berr=4096, and that address is
    -- inside the slave's decode, so the acknowledge is asserted with the bus
    -- error rather than withheld. Mirrored here so both processors see the
    -- same slave.
    signal in_hole : std_logic;

    function hx(v : std_logic_vector) return string is
        constant D : string(1 to 16) := "0123456789abcdef";
        variable r : string(1 to v'length / 4);
        variable n : integer;
    begin
        for i in r'range loop
            n := to_integer(unsigned(v(v'length - 4 * i + 3 downto
                                       v'length - 4 * i)));
            r(i) := D(n + 1);
        end loop;
        return r;
    end function;

begin

    clk <= not clk after CLK_PERIOD / 2;

    in_hole <= '1' when unsigned(adr_out(23 downto 1)) = 4096 else '0';

    dut : entity work.WF68K10_TOP
        generic map (
            VERSION         => x"20210815",
            NO_PIPELINE     => false,
            NO_LOOP         => false,
            NO_INDEXSCALING => true)
        port map (
            CLK       => clk,
            ADR_OUT   => adr_out,
            DATA_IN   => data_in,
            DATA_OUT  => data_out,
            DATA_EN   => data_en,
            BERRn     => berrn,
            RESET_INn => reset_inn,
            RESET_OUT => reset_out,
            HALT_INn  => halt_inn,
            HALT_OUTn => halt_outn,
            FC_OUT    => fc_out,
            AVECn     => avecn,
            IPLn      => ipln,
            DTACKn    => dtackn,
            ASn       => asn,
            RWn       => rwn,
            RMCn      => rmcn,
            UDSn      => udsn,
            LDSn      => ldsn,
            DBENn     => dbenn,
            BUS_EN    => bus_en,
            E         => e,
            VMAn      => vman,
            VMA_EN    => vma_en,
            VPAn      => vpan,
            BRn       => brn,
            BGn       => bgn,
            BGACKn    => bgackn,
            K6800n    => k6800n);

    -- The memory, and the hole. DTACK on the rising edge as UM 5.6 wants, and
    -- for the hole no DTACK at all -- just BERR, a few clocks in, the way a
    -- bus timeout arrives.
    slave : process(clk)
        variable a     : integer;
        variable stall : integer := 0;
    begin
        if rising_edge(clk) then
            if asn = '0' and in_hole = '0' then
                a := to_integer(unsigned(adr_out(14 downto 1)));
                if rwn = '1' then
                    data_in <= mem(a);
                else
                    if udsn = '0' then
                        mem(a)(15 downto 8) <= data_out(15 downto 8);
                    end if;
                    if ldsn = '0' then
                        mem(a)(7 downto 0) <= data_out(7 downto 0);
                    end if;
                end if;
                dtackn <= '0';
                berrn  <= '1';
                stall  := 0;
            elsif asn = '0' and in_hole = '1' then
                dtackn <= '0';
                berrn  <= '0';
            else
                dtackn <= '1';
                berrn  <= '1';
                stall  := 0;
            end if;
        end if;
    end process slave;

    reset_proc : process
    begin
        reset_inn <= '0';
        halt_inn  <= '0';
        wait for CLK_PERIOD * 20;
        reset_inn <= '1';
        halt_inn  <= '1';
        wait;
    end process reset_proc;

    -- Wait for the program to say it has finished, then read its answers out
    -- of the memory it wrote them into.
    watch : process
        variable n : integer := 0;
    begin
        wait for CLK_PERIOD * 40;
        while mem(W_DONE) = x"0000" and n < 400000 loop
            wait until rising_edge(clk);
            n := n + 1;
        end loop;

        if mem(W_DONE) = x"0000" then
            report "P03 suska: the program never finished" severity note;
        else
            report "P03 suska: result " & hx(mem(W_RESULT)) &
                   hx(mem(W_RESULT + 1)) &
                   "  (600d600d is a pass; anything else is the check that failed)"
                severity note;
        end if;
        report "P03 suska: progress " & hx(mem(W_PROG)) & hx(mem(W_PROG + 1)) &
               "   (the check it was running)" severity note;
        report "P03 suska: END" severity note;
        wait;
    end process watch;

end architecture sim;
