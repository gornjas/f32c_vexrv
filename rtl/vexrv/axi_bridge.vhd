library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

use WORK.AXI_PKG.ALL;

entity axi_bridge is
    generic(
        C_axi_ports: natural;
        C_enable_native_read_bursts: boolean;
        C_enable_native_write_bursts: boolean;
        C_read_buffer_max_size: natural;
        C_enable_microblaze_sdram_optimizations: boolean;
        C_experimental_optimizations: boolean := false;
        C_enable_read_buffering: boolean
    );
    port(
        clk: in std_logic;
        reset: in std_logic;
        -- AXI bus
        master_to_slave_i: in T_master_to_slave_bus_array(0 to C_axi_ports - 1);
        slave_to_master_o: out T_slave_to_master_bus_array(0 to C_axi_ports - 1);
        -- Simple bus
        bus_adr: out std_logic_vector(31 downto 0);
        bus_rdata: in std_logic_vector(31 downto 0);
        bus_wdata: out std_logic_vector(31 downto 0);
        bus_burst_len: out std_logic_vector(7 downto 0);
        bus_we: out std_logic;
        bus_bsel: out std_logic_vector(3 downto 0);
        bus_stb: out std_logic;
        bus_ack: in std_logic
    );
end axi_bridge;

architecture rtl of axi_bridge is
    type T_bus_state is (IDLE,
                           READ_NONBUFFERED,
                           READ_BUFFERED,
                           WRITE,
                           WRITE_RESPONSE);
    signal R_bus_state: T_bus_state;
    signal R_bus_addr: std_logic_vector(31 downto 0);
    signal R_burst_total_left: natural range 0 to 255;
    signal R_burst_partial_left: natural range 0 to 255;
    signal R_burst_type: std_logic_vector(1 downto 0);
    signal R_burst_size: std_logic_vector(2 downto 0);
    signal R_burst_len: std_logic_vector(7 downto 0);
    signal R_partial_burst_len: std_logic_vector(7 downto 0);
    signal R_burst_passthrough_enable: std_logic;
    signal wrap_burst_mask_temp: unsigned(31 downto 0);
    signal wrap_burst_mask: std_logic_vector(31 downto 0);
    signal R_locked_master_id: natural range 0 to C_axi_ports - 1;
    signal R_axi_start_treshold: unsigned(7 downto 0);
    signal R_axi_beats_left: unsigned(7 downto 0);

    -- Buffered reads fetch a whole burst length worth of data into the
    -- bridge's internal read buffer before returning it to the requesting
    -- AXI bus. This ensures that the AXI master receives one data word per
    -- cycle which might be necessary for some masters (like MBV cached AXI).
    signal fifo_data_in: std_logic_vector(31 downto 0);
    signal fifo_data_out: std_logic_vector(31 downto 0);
    signal fifo_reset: std_logic;
    signal fifo_put_en: std_logic;
    signal fifo_get_en: std_logic;
    signal fifo_utilization: unsigned(3 downto 0);
    signal fifo_empty: std_logic;
    signal fifo_full: std_logic;
    -- Indicated whether the bridge should start returning read data to the
    -- AXI master
    signal R_axi_running: std_logic;
    -- Indicates whether all data from a burst on the external bus has
    -- been received
    signal R_external_bus_burst_done: std_logic;

    function F_calc_wrap_burst_mask(
      signal burst_len: std_logic_vector(7 downto 0);
      signal burst_size: std_logic_vector(2 downto 0))
      return std_logic_vector is
        variable wrap_burst_mask: std_logic_vector(31 downto 0);
        variable wrap_burst_mask_temp: unsigned(31 downto 0);
    begin
        wrap_burst_mask_temp := (others => '0');
        case burst_len is
        when X"01" =>
            wrap_burst_mask_temp := shift_left
              (X"00000001", to_integer(unsigned(burst_size) + 1));
        when X"03" =>
            wrap_burst_mask_temp := shift_left
              (X"00000001", to_integer(unsigned(burst_size) + 2));
        when X"07" =>
            wrap_burst_mask_temp := shift_left
              (X"00000001", to_integer(unsigned(burst_size) + 3));
        when X"0F" =>
            wrap_burst_mask_temp := shift_left
              (X"00000001", to_integer(unsigned(burst_size) + 4));
        when others =>
        end case;
        wrap_burst_mask := std_logic_vector(wrap_burst_mask_temp - 1);
        return wrap_burst_mask;
    end function;

    function F_calc_words_until_wrap(
      signal start_addr: std_logic_vector(31 downto 0);
      signal burst_size: std_logic_vector(2 downto 0);
      signal burst_len: std_logic_vector(7 downto 0))
      return std_logic_vector is
        variable wrap_burst_mask: std_logic_vector(31 downto 0);
        variable masked_addr: std_logic_vector(31 downto 0);
    begin
        wrap_burst_mask := F_calc_wrap_burst_mask(burst_len, burst_size);
        masked_addr := start_addr and wrap_burst_mask;
        return std_logic_vector(unsigned(burst_len) - unsigned(masked_addr(9 downto 2)));
    end function;

    function F_calc_next_burst_addr(
      signal curr_addr: std_logic_vector(31 downto 0);
      signal burst_len: std_logic_vector(7 downto 0);
      signal burst_size: std_logic_vector(2 downto 0);
      signal burst_type: std_logic_vector(1 downto 0))
      return std_logic_vector is
        variable wrap_burst_mask: std_logic_vector(31 downto 0);
        variable wrap_burst_mask_temp: unsigned(31 downto 0);
        variable bus_addr_next: std_logic_vector(31 downto 0);
    begin
        wrap_burst_mask := F_calc_wrap_burst_mask(burst_len, burst_size);

        case burst_type is
        when "00" =>            -- FIXED
            bus_addr_next := curr_addr;
        when "01" =>            -- INCREMENTAL
            bus_addr_next := std_logic_vector(unsigned(curr_addr) + 4);
        when "10" =>            -- WRAP
            bus_addr_next := (std_logic_vector(unsigned(curr_addr) + 4) and wrap_burst_mask) or
                            (curr_addr and not wrap_burst_mask);
        when "11" =>            -- RESERVED
        when others =>
        end case;
        return bus_addr_next;
    end function;
begin
    I_read_burst_buffer: entity work.axi_bridge_fifo(rtl)
    generic map(
        C_zero_cycle_latency => C_experimental_optimizations
    )
    port map(
        clk => clk,
        reset => fifo_reset,
        data_in => fifo_data_in,
        data_out => fifo_data_out,
        put_en => fifo_put_en,
        get_en => fifo_get_en,
        utilization => fifo_utilization,
        empty => fifo_empty,
        full => fifo_full
    );

    -- State machine control
    process(clk)
    begin
        if rising_edge(clk) then
            if reset = '1' then
                R_bus_state <= IDLE;
            else
                case R_bus_state is
                when IDLE =>
                    -- Pick the highest priority
                    for i in C_axi_ports - 1 downto 0 loop
                        if (master_to_slave_i(i).arvalid = '1' and
                          slave_to_master_o(i).arready = '1') then
                            R_locked_master_id <= i;
                            R_bus_addr <= master_to_slave_i(i).araddr;
                            R_burst_type <= master_to_slave_i(i).arburst;
                            R_burst_size <= master_to_slave_i(i).arsize;
                            R_burst_len <= master_to_slave_i(i).arlen;

                            if C_enable_microblaze_sdram_optimizations = true and
                              ((F_calc_wrap_burst_mask(master_to_slave_i(i).arlen, master_to_slave_i(i).arsize) and
                                master_to_slave_i(i).araddr) = X"00000000") and
                                master_to_slave_i(i).arburst /= "00" then
                              -- Only start AXI transfers early when dealing
                              -- with cacheline aligned bursts from SDRAM since
                              -- it returns a 32-bit word every second cycle.
                              -- AXI starts transfering data when
                              -- half of the required data is received.
                                if C_experimental_optimizations = true then
                                    R_axi_start_treshold <=
                                      '0' & (unsigned(master_to_slave_i(i).arlen(7 downto 1)));
                                else
                                    R_axi_start_treshold <=
                                      '0' & (unsigned(master_to_slave_i(i).arlen(7 downto 1)) + 1);
                                end if;
                            else
                                R_axi_start_treshold <= unsigned(master_to_slave_i(i).arlen);
                            end if;
                            R_partial_burst_len <= F_calc_words_until_wrap(
                              master_to_slave_i(i).araddr,
                              master_to_slave_i(i).arsize,
                              master_to_slave_i(i).arlen);
                            R_burst_total_left <=
                              to_integer(unsigned(master_to_slave_i(i).arlen));
                            R_burst_partial_left <=
                              to_integer(unsigned(F_calc_words_until_wrap(
                              master_to_slave_i(i).araddr,
                              master_to_slave_i(i).arsize,
                              master_to_slave_i(i).arlen)));

                            if master_to_slave_i(i).araddr(31 downto 28) = X"8"
                              and C_enable_native_read_bursts = true then
                                R_burst_passthrough_enable <= '1';
                            else
                                R_burst_passthrough_enable <= '0';
                            end if;

                            if C_enable_read_buffering = true then
                                -- We only need to do buffered reads when we are
                                -- dealing with bursts
                                if master_to_slave_i(i).arlen /= X"00" then
                                    R_bus_state <= READ_BUFFERED;
                                    R_axi_beats_left <= unsigned(master_to_slave_i(i).arlen);
                                    R_axi_running <= '0';
                                    R_external_bus_burst_done <= '0';
                                else
                                    R_bus_state <= READ_NONBUFFERED;
                                end if;
                            else
                                R_bus_state <= READ_NONBUFFERED;
                            end if;
                        elsif (master_to_slave_i(i).awvalid = '1' and
                          slave_to_master_o(i).awready = '1') then
                            R_locked_master_id <= i;
                            R_bus_state <= WRITE;
                            R_bus_addr <= master_to_slave_i(i).awaddr;
                            R_burst_type <= master_to_slave_i(i).awburst;
                            R_burst_size <= master_to_slave_i(i).awsize;
                            R_burst_len <= master_to_slave_i(i).awlen;
                            R_partial_burst_len <= F_calc_words_until_wrap(
                              master_to_slave_i(i).awaddr,
                              master_to_slave_i(i).awsize,
                              master_to_slave_i(i).awlen);
                            R_burst_total_left <=
                              to_integer(unsigned(master_to_slave_i(i).awlen));
                            R_burst_partial_left <=
                              to_integer(unsigned(F_calc_words_until_wrap(
                              master_to_slave_i(i).awaddr,
                              master_to_slave_i(i).awsize,
                              master_to_slave_i(i).awlen)));

                            if master_to_slave_i(i).araddr(31 downto 28) = X"8"
                              and C_enable_native_write_bursts = true then
                                R_burst_passthrough_enable <= '1';
                            else
                                R_burst_passthrough_enable <= '0';
                            end if;
                        end if;
                    end loop;
                when READ_NONBUFFERED =>
                    if master_to_slave_i(R_locked_master_id).rready = '1' and
                      slave_to_master_o(R_locked_master_id).rvalid = '1' then
                        if slave_to_master_o(R_locked_master_id).rlast = '1' then
                            R_bus_state <= IDLE;
                        end if;

                        -- Detect when the first partial burst is over
                        -- (we reached wrap boundary) and start another burst
                        -- from the cacheline aligned address
                        if R_burst_partial_left = 0 then
                            R_burst_partial_left <=
                              to_integer(unsigned(R_burst_len) - unsigned(R_partial_burst_len)) - 1;
                            R_partial_burst_len <=
                              std_logic_vector(unsigned(R_burst_len) - unsigned(R_partial_burst_len) - 1);
                        else
                            R_burst_partial_left <= R_burst_partial_left - 1;
                        end if;

                        R_burst_total_left <= R_burst_total_left - 1;
                        R_bus_addr <= F_calc_next_burst_addr(R_bus_addr,
                            R_burst_len, R_burst_size, R_burst_type);
                    end if;
                when READ_BUFFERED =>
                    -- External bus logic
                    if bus_ack = '1' then
                        if R_external_bus_burst_done = '0' and
                          R_burst_total_left = 0 then
                            R_external_bus_burst_done <= '1';
                        end if;

                        -- Detect when the first partial burst is over
                        -- (we reached wrap boundary) and start another burst
                        -- from the cacheline aligned address
                        if R_burst_partial_left = 0 then
                            R_burst_partial_left <=
                              to_integer(unsigned(R_burst_len) - unsigned(R_partial_burst_len)) - 1;
                            R_partial_burst_len <=
                              std_logic_vector(unsigned(R_burst_len) - unsigned(R_partial_burst_len) - 1);
                        else
                            R_burst_partial_left <= R_burst_partial_left - 1;
                        end if;

                        R_burst_total_left <= R_burst_total_left - 1;
                        R_bus_addr <= F_calc_next_burst_addr(R_bus_addr,
                          R_burst_len, R_burst_size, R_burst_type);

                        R_axi_running <= '1' when
                          fifo_utilization = R_axi_start_treshold;
                    end if;

                    -- AXI bus logic
                    if master_to_slave_i(R_locked_master_id).rready = '1' and
                      slave_to_master_o(R_locked_master_id).rvalid = '1' then
                        -- When FIFO buffer empty prepare for a new IO request
                        if R_axi_beats_left = 0 then
                            R_bus_state <= IDLE;
                            R_axi_running <= '0';
                        end if;
                        R_axi_beats_left <= R_axi_beats_left - 1;
                    end if;
                when WRITE =>
                    if master_to_slave_i(R_locked_master_id).wvalid = '1' and
                      slave_to_master_o(R_locked_master_id).wready = '1' then
                        if master_to_slave_i(R_locked_master_id).wlast = '1' then
                            R_bus_state <= WRITE_RESPONSE;
                        end if;

                        if R_burst_partial_left = 0 then
                            R_burst_partial_left <=
                              to_integer(unsigned(R_burst_len) - unsigned(R_partial_burst_len)) - 1;
                            R_partial_burst_len <=
                              std_logic_vector(unsigned(R_burst_len) - unsigned(R_partial_burst_len) - 1);
                        else
                            R_burst_partial_left <= R_burst_partial_left - 1;
                        end if;

                        R_burst_total_left <= R_burst_total_left - 1;
                        R_bus_addr <= F_calc_next_burst_addr(R_bus_addr,
                          R_burst_len, R_burst_size, R_burst_type);
                    end if;
                when WRITE_RESPONSE =>
                    if master_to_slave_i(R_locked_master_id).bready = '1' and
                      slave_to_master_o(R_locked_master_id).bvalid = '1' then
                        R_bus_state <= IDLE;
                    end if;
                when others =>
                end case;
            end if;
        end if;
    end process;

    -- AXI - Simple bus interconnect control
    process(bus_rdata, bus_ack, R_bus_state, R_burst_total_left, R_bus_addr,
      master_to_slave_i, slave_to_master_o, R_burst_passthrough_enable,
      R_partial_burst_len, R_axi_running, fifo_data_out, fifo_empty,
      R_external_bus_burst_done, R_locked_master_id, R_axi_beats_left)
    begin
        bus_wdata <= (others => '0');
        bus_adr <= R_bus_addr;
        bus_burst_len <= (others => '0');
        bus_bsel <= "0000";
        bus_we <= '0';
        bus_stb <= '0';

        fifo_data_in <= bus_rdata;
        fifo_reset <= '0';
        fifo_put_en <= '0';
        fifo_get_en <= '0';

        for i in 0 to C_axi_ports - 1 loop
            slave_to_master_o(i).awready <= '0';
            slave_to_master_o(i).wready <= '0';
            slave_to_master_o(i).bresp <= "00";
            slave_to_master_o(i).bvalid <= '0';
            slave_to_master_o(i).arready <= '0';
            slave_to_master_o(i).rdata <= bus_rdata;
            slave_to_master_o(i).rresp <= "00";
            slave_to_master_o(i).rlast <= '0';
            slave_to_master_o(i).rvalid <= '0';
        end loop;
        case R_bus_state is
        when IDLE =>
            -- Only the highest priority master can be ready at any moment
            for i in 0 to C_axi_ports - 1 loop
                slave_to_master_o(i).arready <= '1';
                slave_to_master_o(i).awready <= '1';
                -- Make sure that we don't accidentaly accept both a read
                -- and a write request at the same time since we can only
                -- service one at a time. If the current AXI port
                -- has both valid requests (read and write) then service reads
                -- first
                if master_to_slave_i(i).arvalid = '1' then
                    slave_to_master_o(i).awready <= '0';
                end if;
                -- Check whether there is a higher priority port with a
                -- valid (and servicable) read / write request and if
                -- there is then don't accept any requests on this port
                if i > 0 then
                    for j in 0 to i - 1 loop
                        if (slave_to_master_o(j).awready = '1' and master_to_slave_i(j).awvalid = '1') or
                          (slave_to_master_o(j).arready = '1' and master_to_slave_i(j).arvalid = '1') then
                            slave_to_master_o(i).awready <= '0';
                            slave_to_master_o(i).arready <= '0';
                        end if;
                    end loop;
                end if;
            end loop;
        when READ_NONBUFFERED =>
            slave_to_master_o(R_locked_master_id).rlast <= '1' when
              R_burst_total_left = 0 else '0';
            slave_to_master_o(R_locked_master_id).rvalid <= bus_ack;
            if R_burst_passthrough_enable = '1' then
                bus_burst_len <= R_partial_burst_len;
            end if;
            bus_stb <= master_to_slave_i(R_locked_master_id).rready;
        when READ_BUFFERED =>
            fifo_put_en <= bus_ack;
            fifo_get_en <= R_axi_running and master_to_slave_i(R_locked_master_id).rready;

            bus_stb <= '1' when R_external_bus_burst_done = '0' else '0';
            if R_burst_passthrough_enable = '1' then
                bus_burst_len <= R_partial_burst_len;
            end if;

            slave_to_master_o(R_locked_master_id).rlast <= '1' when
              R_axi_beats_left = 0 else '0';
            slave_to_master_o(R_locked_master_id).rvalid <=
              R_axi_running and not fifo_empty;
            slave_to_master_o(R_locked_master_id).rdata <=
              fifo_data_out;
        when WRITE =>
            bus_wdata <= master_to_slave_i(R_locked_master_id).wdata;
            bus_bsel <= master_to_slave_i(R_locked_master_id).wstrb;
            if R_burst_passthrough_enable = '1' then
                bus_burst_len <= R_partial_burst_len;
            end if;
            bus_we <= '1';
            bus_stb <= master_to_slave_i(R_locked_master_id).wvalid;
            slave_to_master_o(R_locked_master_id).wready <= bus_ack;
        when WRITE_RESPONSE =>
            slave_to_master_o(R_locked_master_id).bvalid <= '1';
        when others =>
        end case;
    end process;
end rtl;