-- The special status word of a faulted bus cycle, on the Suska WF68K10.
--
-- Companion to sim/programs/p06_ssw.S, which is the same image this runs and
-- which sim/tb/core_program_tb.sv runs on RD68011. The program faults a bus
-- cycle in each of seven shapes -- supervisor and user, data and program, read
-- and write, word and byte, and a read-modify-write -- and checks the special
-- status word the processor pushed against UM figure 6-9. Two implementations
-- disagreed about the first of those, so it is worth having the answer from
-- something other than the implementation being questioned.
--
-- CLAUDE.md permits Inputs/Suska_Configware/68K10/ to be *run* to validate
-- testbenches and never to be read to work out how to write our RTL. This is
-- the running. Nothing here was written from its source; its entity
-- declaration is what an instantiation needs and is all that was looked at.
--
-- Unlike wf68k10_tb.vhd this reports the program's own answers rather than a
-- bus trace, because the program is self-checking and the interesting values
-- are in its memory when it stops.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity wf68k10_ssw_tb is
end entity wf68k10_ssw_tb;

architecture sim of wf68k10_ssw_tb is

    constant CLK_PERIOD : time := 125 ns;   -- 8 MHz, the part's own speed

    -- Where sim/programs/link.ld and p06_ssw.S put things, in words.
    constant W_RESULT  : integer := 16#400# / 2;
    constant W_DONE    : integer := 16#408# / 2;
    constant W_SSWTAB  : integer := 16#A4E# / 2;
    constant W_NFAULT  : integer := 16#A72# / 2;

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

    signal mem : mem_t := load("p06_ssw.hex");

    -- Anything with address bit 23 set decodes to nothing, so a cycle there
    -- gets a bus error and never an acknowledge: a timeout rather than a
    -- retry, which is what p06_ssw.S wants faulted.
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

    in_hole <= adr_out(23);

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
                dtackn <= '1';
                if stall >= 3 then
                    berrn <= '0';
                else
                    stall := stall + 1;
                end if;
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
            report "SSW suska: the program never finished" severity note;
        else
            report "SSW suska: result " & hx(mem(W_RESULT)) &
                   hx(mem(W_RESULT + 1)) &
                   "  (600d600d is a pass; anything else is the check that failed)"
                severity note;
        end if;
        report "SSW suska: faults taken " & hx(mem(W_NFAULT)) severity note;
        for i in 0 to 7 loop
            report "SSW suska: ssw[" & integer'image(i) & "] = " &
                   hx(mem(W_SSWTAB + i)) severity note;
        end loop;
        report "SSW suska: END" severity note;
        wait;
    end process watch;

end architecture sim;
