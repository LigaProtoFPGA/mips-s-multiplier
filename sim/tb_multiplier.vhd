--------------------------------------------------------------------------
--  tb_multiplier - self-checking testbench for the 32-bit multipliers
--
--  Drives the serial reference and the Booth radix-4 unit with the same
--  stimulus, checks both products against an integer golden model and
--  measures the latency of each, in clock cycles, from the falling edge
--  of `start` to the cycle in which endop = '1'.
--
--  The run fails (severity failure) on the first mismatch, so it is
--  usable as a regression gate in CI.
--
--  Liga ProtoFPGA - UFSC
--------------------------------------------------------------------------
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity tb_multiplier is
    generic(N : integer := 32);
end tb_multiplier;

architecture testbench of tb_multiplier is

    constant PERIOD : time := 10 ns;

    signal clock   : std_logic := '0';
    signal start   : std_logic := '1';
    signal running : boolean   := true;

    signal Mpland : std_logic_vector(N-1 downto 0) := (others => '0');
    signal Mplier : std_logic_vector(N-1 downto 0) := (others => '0');

    signal endop_ser   : std_logic;
    signal product_ser : std_logic_vector(2*N-1 downto 0);
    signal endop_bth   : std_logic;
    signal product_bth : std_logic_vector(2*N-1 downto 0);

    -- Latency counters, one per unit. Reset by `start`, frozen by endop.
    signal cyc_ser  : natural := 0;
    signal cyc_bth  : natural := 0;
    signal done_ser : boolean := false;
    signal done_bth : boolean := false;

    signal errors : natural := 0;

    -- Golden model, computed with unbounded integers so it is independent
    -- of the RTL under test.
    function golden(a, b : std_logic_vector) return std_logic_vector is
        variable p : unsigned(2*N-1 downto 0);
    begin
        p := unsigned(a) * unsigned(b);
        return std_logic_vector(p);
    end function;

    function hex(v : std_logic_vector) return string is
        constant DIGITS : string := "0123456789ABCDEF";
        variable u : unsigned(v'length-1 downto 0) := unsigned(v);
        variable s : string(1 to v'length/4);
    begin
        for i in s'range loop
            s(i) := DIGITS(to_integer(u(v'length-1 downto v'length-4)) + 1);
            u := shift_left(u, 4);
        end loop;
        return s;
    end function;

begin

    ----------------------------------------------------------------------
    -- Clock
    ----------------------------------------------------------------------
    clock <= (not clock) after PERIOD/2 when running else '0';

    ----------------------------------------------------------------------
    -- Units under test - identical stimulus, identical interface
    ----------------------------------------------------------------------
    dut_serial : entity work.multiplier
        generic map(N => N)
        port map(clock   => clock,
                 start   => start,
                 Mpland  => Mpland,
                 Mplier  => Mplier,
                 endop   => endop_ser,
                 Product => product_ser);

    dut_booth : entity work.multiplier_booth
        generic map(N => N)
        port map(clock   => clock,
                 start   => start,
                 Mpland  => Mpland,
                 Mplier  => Mplier,
                 endop   => endop_bth,
                 Product => product_bth);

    ----------------------------------------------------------------------
    -- Latency measurement
    ----------------------------------------------------------------------
    count_serial : process(clock, start)
    begin
        if start = '1' then
            cyc_ser  <= 0;
            done_ser <= false;
        elsif rising_edge(clock) then
            if not done_ser then
                cyc_ser <= cyc_ser + 1;
                if endop_ser = '1' then
                    done_ser <= true;
                end if;
            end if;
        end if;
    end process;

    count_booth : process(clock, start)
    begin
        if start = '1' then
            cyc_bth  <= 0;
            done_bth <= false;
        elsif rising_edge(clock) then
            if not done_bth then
                cyc_bth <= cyc_bth + 1;
                if endop_bth = '1' then
                    done_bth <= true;
                end if;
            end if;
        end if;
    end process;

    ----------------------------------------------------------------------
    -- Stimulus and checking
    ----------------------------------------------------------------------
    stimulus : process

        procedure check(a, b : in std_logic_vector(N-1 downto 0);
                        tag : in string) is
            variable expected : std_logic_vector(2*N-1 downto 0);
        begin
            expected := golden(a, b);

            -- Assert reset, present operands, release on a falling edge.
            start  <= '1';
            Mpland <= a;
            Mplier <= b;
            wait until rising_edge(clock);
            wait for PERIOD/4;
            start <= '0';

            -- Both units are running; wait for the slower one.
            wait until done_ser and done_bth;
            wait for PERIOD/4;

            if product_ser /= expected then
                report "SERIAL mismatch [" & tag & "]: got " &
                       hex(product_ser) & ", expected " & hex(expected)
                       severity error;
                errors <= errors + 1;
            end if;

            if product_bth /= expected then
                report "BOOTH  mismatch [" & tag & "]: got " &
                       hex(product_bth) & ", expected " & hex(expected)
                       severity error;
                errors <= errors + 1;
            end if;

            report tag & ": " & hex(a) & " x " & hex(b) & " = " &
                   hex(expected) &
                   "  |  serial " & integer'image(cyc_ser) &
                   " cycles, booth " & integer'image(cyc_bth) & " cycles"
                   severity note;

            wait until rising_edge(clock);
        end procedure;

        -- Deterministic 32-bit pseudo-random source (xorshift32), so the
        -- regression is reproducible across simulators.
        variable rnd : unsigned(31 downto 0) := x"1D872B41";
        impure function next_rand return std_logic_vector is
        begin
            rnd := rnd xor shift_left(rnd, 13);
            rnd := rnd xor shift_right(rnd, 17);
            rnd := rnd xor shift_left(rnd, 5);
            return std_logic_vector(rnd);
        end function;

    begin
        report "=== 32-bit multiplier regression ===" severity note;

        -- Directed cases: identities, boundaries, all-ones.
        check(x"00000000", x"00000000", "zero x zero");
        check(x"00000001", x"00000001", "one x one");
        check(x"0000000F", x"00000000", "n x zero");
        check(x"00000000", x"0000000F", "zero x n");
        check(x"00000005", x"00000003", "5 x 3");
        check(x"FFFFFFFF", x"00000001", "max x one");
        check(x"00000001", x"FFFFFFFF", "one x max");
        check(x"FFFFFFFF", x"FFFFFFFF", "max x max");
        check(x"80000000", x"00000002", "msb x two");
        check(x"7FFFFFFF", x"7FFFFFFF", "int_max x int_max");
        check(x"AAAAAAAA", x"55555555", "alternating");

        -- Values taken from the report worked example and the waveform.
        check(x"00E30023", x"005200E2", "report vector");

        -- Randomised sweep.
        for i in 0 to 63 loop
            check(next_rand, next_rand, "random " & integer'image(i));
        end loop;

        if errors = 0 then
            report "=== PASS: all vectors matched the golden model ==="
                   severity note;
        else
            report "=== FAIL: " & integer'image(errors) & " mismatches ==="
                   severity failure;
        end if;

        running <= false;
        wait;
    end process;

end testbench;
