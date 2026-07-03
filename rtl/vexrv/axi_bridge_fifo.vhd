library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use IEEE.MATH_REAL.ALL;

entity axi_bridge_fifo is
    generic(
        C_data_width: natural := 32;
        C_fifo_size: natural := 8;      -- MUST BE POWER OF 2!
        C_zero_cycle_latency: boolean
    );
    port(
        clk: in std_logic;
        reset: in std_logic;
        data_in: in std_logic_vector(C_data_width - 1 downto 0);
        data_out: out std_logic_vector(C_data_width - 1 downto 0);
        put_en: in std_logic;
        get_en: in std_logic;
        utilization: out unsigned(3 downto 0);
        empty: out std_logic;
        full: out std_logic
    );
end axi_bridge_fifo;

architecture rtl of axi_bridge_fifo is
    constant C_head_tail_reg_width: natural := natural(ceil(log2(real(C_fifo_size))));
    constant C_util_reg_width: natural := natural(ceil(log2(real(C_fifo_size)))) + 1;

    type T_fifo is array (0 to C_fifo_size - 1) of std_logic_vector(C_data_width - 1 downto 0);
    signal M_fifo: T_fifo;
    signal R_fifo_head: unsigned(C_head_tail_reg_width - 1 downto 0) := (others => '0');
    signal R_fifo_tail: unsigned(C_head_tail_reg_width - 1 downto 0) := (others => '0');
    signal R_fifo_util: unsigned(C_util_reg_width - 1 downto 0) := (others => '0');
    signal R_data_out: std_logic_vector(C_data_width - 1 downto 0);
    signal fifo_almost_empty: std_logic;
    signal fifo_empty: std_logic;
    signal fifo_full: std_logic;
begin
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                R_fifo_head <= (others => '0');
                R_fifo_tail <= (others => '0');
                R_fifo_util <= (others => '0');
            else
                R_data_out <= M_fifo(to_integer(R_fifo_head));
                if put_en = '1' and get_en = '1' then
                    if fifo_empty = '1' then
                        R_data_out <= data_in;
                        M_fifo(to_integer(R_fifo_tail)) <= data_in;
                        R_fifo_tail <= R_fifo_tail + 1;
                        if C_zero_cycle_latency = false then
                            R_fifo_util <= R_fifo_util + 1;
                        else
                            R_fifo_head <= R_fifo_head + 1;
                        end if;
                    else
                        if fifo_almost_empty = '1' then
                            R_data_out <= data_in;
                        else
                            R_data_out <= M_fifo(to_integer(R_fifo_head + 1));
                        end if;
                        M_fifo(to_integer(R_fifo_tail)) <= data_in;
                        R_fifo_tail <= R_fifo_tail + 1;
                        R_fifo_head <= R_fifo_head + 1;
                    end if;
                elsif put_en = '1' and fifo_full = '0' then
                    if fifo_empty = '1' then
                        R_data_out <= data_in;
                        M_fifo(to_integer(R_fifo_tail)) <= data_in;
                        R_fifo_tail <= R_fifo_tail + 1;
                        R_fifo_util <= R_fifo_util + 1;
                    else
                        M_fifo(to_integer(R_fifo_tail)) <= data_in;
                        R_fifo_tail <= R_fifo_tail + 1;
                        R_fifo_util <= R_fifo_util + 1;
                    end if;
                elsif get_en = '1' and fifo_empty = '0' then
                    R_data_out <= M_fifo(to_integer(R_fifo_head + 1));
                    R_fifo_head <= R_fifo_head + 1;
                    R_fifo_util <= R_fifo_util - 1;
                end if;
            end if;
        end if;
    end process;

    process(R_fifo_util, R_data_out, fifo_empty, put_en, data_in)
    begin
        if C_zero_cycle_latency = true then
            if fifo_empty = '1' and put_en = '1' then
                data_out <= data_in;
                empty <= '0';
            else
                data_out <= R_data_out;
                empty <= fifo_empty;
            end if;
        else
            data_out <= R_data_out;
        end if;
    end process;
    fifo_almost_empty <= '1' when R_fifo_util = 1 else '0';
    fifo_empty <= '1' when R_fifo_util = 0 else '0';
    fifo_full <= '1' when R_fifo_util = C_fifo_size else '0';
    full <= fifo_full;
    utilization <= R_fifo_util;
end rtl;
