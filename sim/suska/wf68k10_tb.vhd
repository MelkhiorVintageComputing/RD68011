-- A bus-trace testbench for the Suska WF68K10, under ghdl.
--
-- WHY THIS EXISTS
--
-- Inputs/Suska_Configware/68K10/ is another MC68010-compatible design, and
-- CLAUDE.md is explicit about what it is for: it may be run to validate
-- testbenches, and it may never be read to work out how to write our RTL. This
-- is the running.
--
-- The question it answers is a narrow one. Our bus testbenches assert where
-- each signal moves inside the S0-S7 ruler -- AS at the rising edge entering
-- S2, the data strobes a half clock later on a read and two clocks later on a
-- write, read data latched on the falling edge of S6. Those assertions were
-- written from UM section 5 and figure 10-4. If they were misread, every one
-- of our bus tests would agree with the misreading and pass. A second
-- implementation, built by somebody else from the same manual, cannot make the
-- same mistake by accident.
--
-- What came of asking is in doc/suska-crosscheck.md, and the short version is
-- that the edge placement cannot be compared at all: this core runs a two-clock
-- bus cycle with AS asserting on a falling edge, where the manual's is four
-- clocks with AS asserting on a rising one. So what is printed here is the
-- transaction list -- which addresses, in which order, read or write, in which
-- address space -- which is protocol-independent and can be compared.
--
-- Nothing here was written from reading Suska's source. Its entity declaration
-- is what an instantiation needs and is all that was looked at.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity wf68k10_tb is
end entity wf68k10_tb;

architecture sim of wf68k10_tb is

    constant CLK_PERIOD : time := 125 ns;   -- 8 MHz, the part's own speed
    constant HALVES     : integer := 2000;  -- how much of the trace to print

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

    -- The same memory the SystemVerilog testbenches model: word wide, at zero.
    type mem_t is array (0 to 1023) of std_logic_vector(15 downto 0);

    -- Read from the same image sim/suska/rd68011_bus_tb.sv loads, so that
    -- there is one program and not two that have to be kept in step.
    impure function load(path : string) return mem_t is
        file     f    : text;
        variable l    : line;
        variable m    : mem_t := (others => (others => '0'));
        variable v    : std_logic_vector(15 downto 0);
        variable i    : integer := 0;
        variable good : boolean;
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

    signal mem : mem_t := load("bus_probe.hex");

begin

    clk <= not clk after CLK_PERIOD / 2;

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

    -- The memory. UM 5.6 wants DTACK asserted and negated on the rising edge
    -- of the processor clock, which is what the SystemVerilog model does too,
    -- so both processors see the same slave.
    slave : process(clk)
        variable a : integer;
    begin
        if rising_edge(clk) then
            if asn = '0' then
                a := to_integer(unsigned(adr_out(10 downto 1)));
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
            else
                dtackn <= '1';
            end if;
        end if;
    end process slave;

    -- Release the processor the way the manual says: RESET and HALT asserted
    -- together, then let go (UM 5.5).
    reset_proc : process
    begin
        reset_inn <= '0';
        halt_inn  <= '0';
        wait for CLK_PERIOD * 20;   -- ten was not enough for this core
        reset_inn <= '1';
        halt_inn  <= '1';
        wait;
    end process reset_proc;

    -- One line per bus cycle: the address, whether it was a read, and the
    -- function code. What is *not* printed is where in the cycle each edge
    -- fell, because that turns out not to be comparable -- see
    -- doc/suska-crosscheck.md.
    trace : process
        variable n : integer := 0;

        function hex24(v : std_logic_vector(31 downto 0)) return string is
            variable r : string(1 to 6);
            variable k : integer;
            constant D : string(1 to 16) := "0123456789abcdef";
        begin
            for i in 0 to 5 loop
                k := to_integer(unsigned(v(4 * (5 - i) + 3 downto 4 * (5 - i))));
                r(i + 1) := D(k + 1);
            end loop;
            return r;
        end function;

        function s(v : std_logic) return character is
        begin
            if v = '0' then return '0'; elsif v = '1' then return '1';
            else return 'x'; end if;
        end function;
    begin
        loop
            wait until falling_edge(asn);
            wait for 1 ns;
            exit when n >= 400;
            report "CYCLE " & hex24(adr_out) & " " & s(rwn) & " " &
                   s(fc_out(2)) & s(fc_out(1)) & s(fc_out(0)) & " " &
                   s(udsn) & s(ldsn)
                severity note;
            n := n + 1;
        end loop;
        report "CYCLE END" severity note;
        wait;
    end process trace;

end architecture sim;
