library IEEE;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;

use work.sdram_pack.all;
use work.axi_pkg.all;

entity glue_vexriscv_sdram is
    generic(
	C_clk_freq_hz: integer;

	-- SoC configuration options
	C_sdram: boolean := true;
	C_sio: integer := 1;
	C_sio_init_baudrate: integer := 115200;
	C_sio_fixed_baudrate: boolean := false;
	C_sio_break_detect: boolean := true;
	C_boot_spi: boolean := true;
	C_spi: integer := 0;
	C_spi_fixed_speed: std_logic_vector := "1111";
	C_simple_in: natural := 32;
	C_simple_out: natural := 32;
	C_rtc: boolean := true;

	-- SDRAM parameters
	C_sdram_address_width: integer := 24;
	C_sdram_column_bits: integer := 9;
	C_sdram_startup_cycles: integer := 10100;
	C_sdram_cycles_per_refresh: integer := 1524;

	-- ROM initialization file
	C_bootloader_filename: string := ""
    );
    port(
	clk: in std_logic;
	reset: in std_logic := '0';
	sdram_addr: out std_logic_vector(12 downto 0);
	sdram_data: inout std_logic_vector(15 downto 0);
	sdram_ba: out std_logic_vector(1 downto 0);
	sdram_dqm: out std_logic_vector(1 downto 0);
	sdram_ras, sdram_cas: out std_logic;
	sdram_cke, sdram_clk: out std_logic;
	sdram_we, sdram_cs: out std_logic;
	sio_rxd: in std_logic_vector(C_sio - 1 downto 0) := (others => '1');
	sio_txd, sio_break: out std_logic_vector(C_sio - 1 downto 0);
	spi_sck, spi_ss0, spi_ss1, spi_ss2, spi_ss3: out std_logic_vector(C_spi - 1 downto 0);
	spi_miso, spi_mosi: inout std_logic_vector(C_spi - 1 downto 0);
	simple_in: in std_logic_vector(C_simple_in - 1 downto 0) :=
	  (others => '0');
	simple_out: out std_logic_vector(C_simple_out - 1 downto 0)
    );
end glue_vexriscv_sdram;

architecture x of glue_vexriscv_sdram is
    signal resetn: std_logic;

    -- Bus signals
    signal bus_adr: std_logic_vector(31 downto 0);
    signal bus_rdata: std_logic_vector(31 downto 0);
    signal bus_wdata: std_logic_vector(31 downto 0);
    signal bus_burst_len: std_logic_vector(7 downto 0);
    signal bus_we: std_logic;
    signal bus_bsel: std_logic_vector(3 downto 0);
    signal bus_stb: std_logic;
    signal bus_ack: std_logic;
    signal bus_ack_delay_1c: std_logic;

    -- AXI CPU Bus
    constant C_axi_ibus_id: natural := 0;
    constant C_axi_dbus_id: natural := 1;
    signal axi_master_to_slave: T_master_to_slave_bus_array(0 to 1);
    signal axi_slave_to_master: T_slave_to_master_bus_array(0 to 1);

    -- Boot ROM
    signal rom_strobe: std_logic;
    signal rom_ready: std_logic;
    signal rom_rdata: std_logic_vector(31 downto 0);

    -- SDRAM
    constant C_ras: natural range 2 to 3 := 2 + C_clk_freq_hz / 137000000;
    constant C_cas: natural range 2 to 3 := 2 + C_clk_freq_hz / 137000000;
    constant C_pre: natural range 2 to 3 := 2 + C_clk_freq_hz / 137000000;
    constant C_clock_range: natural range 0 to 2
      := 1 + C_clk_freq_hz / 101000000;
    signal sdram_req: sdram_req_array;
    signal sdram_resp: sdram_resp_array;
    signal sdram_strobe: std_logic := '0';

    -- I/O
    signal io_write: std_logic;
    signal io_strobe: std_logic;
    signal io_addr: std_logic_vector(11 downto 2);
    signal cpu_to_io, io_to_cpu: std_logic_vector(31 downto 0);
    signal io_byte_sel: std_logic_vector(3 downto 0);

    -- Serial I/O (RS232): 0x300 .. 0x33F
    constant C_io_sio0: std_logic_vector(7 downto 0) := x"30";
    constant C_io_sio1: std_logic_vector(7 downto 0) := x"31";
    constant C_io_sio2: std_logic_vector(7 downto 0) := x"32";
    constant C_io_sio3: std_logic_vector(7 downto 0) := x"33";
    signal sio_io_range: boolean;
    type from_sio_type is array (0 to C_sio - 1) of
      std_logic_vector(31 downto 0);
    signal from_sio: from_sio_type;
    signal sio_ce: std_logic_vector(C_sio - 1 downto 0) := (others => '0');
    signal sio_tx, sio_rx: std_logic_vector(C_sio - 1 downto 0);

    -- RTC: 0x780 .. 0x78F
    constant C_io_rtc: std_logic_vector(7 downto 0) := x"78";
    signal rtc_io_range: boolean;
    signal rtc_ce: std_logic;
    signal from_rtc: std_logic_vector(31 downto 0);

    -- SPI (on-board Flash, SD card, others...): 0x340 .. 0x37F
    constant C_io_spi0: std_logic_vector(7 downto 0) := x"34";
    constant C_io_spi1: std_logic_vector(7 downto 0) := x"35";
    constant C_io_spi2: std_logic_vector(7 downto 0) := x"36";
    constant C_io_spi3: std_logic_vector(7 downto 0) := x"37";
    signal spi_io_range: boolean;
    type from_spi_type is array (0 to C_spi - 1) of
      std_logic_vector(31 downto 0);
    signal from_spi: from_spi_type;
    signal spi_ce: std_logic_vector(C_spi - 1 downto 0);

    -- Simple input (buttons and switches): 0x700 .. 070F
    constant C_io_simple_in: std_logic_vector(7 downto 0) := x"70";
    signal R_simple_in: std_logic_vector(31 downto 0);

    -- Simple output (onboard LEDs): 0x710 .. 0x71F
    constant C_io_simple_out: std_logic_vector(7 downto 0) := x"71";
    signal R_simple_out: std_logic_vector(31 downto 0);

    signal R_utime: unsigned(63 downto 0) := (others => '0');
begin
    resetn <= not reset;

    process(clk)
    begin
	if rising_edge(clk) then
	    if reset = '1' then
		R_utime <= (others => '0');
	    else
		R_utime <= R_utime + 1;
	    end if;
	end if;
    end process;

    I_cpu : entity work.VexRiscv
    port map(
        debug_resetOut => open,
        timerInterrupt => '0',
        externalInterrupt => '0',
        softwareInterrupt => '0',
	utime => R_utime,
        iBusAxi_ar_valid => axi_master_to_slave(C_axi_ibus_id).arvalid,
        iBusAxi_ar_ready => axi_slave_to_master(C_axi_ibus_id).arready,
        std_logic_vector(iBusAxi_ar_payload_addr) => axi_master_to_slave(C_axi_ibus_id).araddr,
        iBusAxi_ar_payload_id => open,
        iBusAxi_ar_payload_region => open,
        std_logic_vector(iBusAxi_ar_payload_len) => axi_master_to_slave(C_axi_ibus_id).arlen,
        std_logic_vector(iBusAxi_ar_payload_size) => axi_master_to_slave(C_axi_ibus_id).arsize,
        iBusAxi_ar_payload_burst => axi_master_to_slave(C_axi_ibus_id).arburst,
        iBusAxi_ar_payload_lock => open,
        iBusAxi_ar_payload_cache => open,
        iBusAxi_ar_payload_qos => open,
        iBusAxi_ar_payload_prot => open,
        iBusAxi_r_valid => axi_slave_to_master(C_axi_ibus_id).rvalid,
        iBusAxi_r_ready => axi_master_to_slave(C_axi_ibus_id).rready,
        iBusAxi_r_payload_data => axi_slave_to_master(C_axi_ibus_id).rdata,
        iBusAxi_r_payload_id => "0",
        iBusAxi_r_payload_resp => axi_slave_to_master(C_axi_ibus_id).rresp,
        iBusAxi_r_payload_last => axi_slave_to_master(C_axi_ibus_id).rlast,
        dBusAxi_aw_valid => axi_master_to_slave(C_axi_dbus_id).awvalid,
        dBusAxi_aw_ready => axi_slave_to_master(C_axi_dbus_id).awready,
        std_logic_vector(dBusAxi_aw_payload_addr) => axi_master_to_slave(C_axi_dbus_id).awaddr,
        dBusAxi_aw_payload_id => open,
        dBusAxi_aw_payload_region => open,
        std_logic_vector(dBusAxi_aw_payload_len) => axi_master_to_slave(C_axi_dbus_id).awlen,
        std_logic_vector(dBusAxi_aw_payload_size) => axi_master_to_slave(C_axi_dbus_id).awsize,
        std_logic_vector(dBusAxi_aw_payload_burst) => axi_master_to_slave(C_axi_dbus_id).awburst,
        dBusAxi_aw_payload_lock => open,
        dBusAxi_aw_payload_cache => open,
        dBusAxi_aw_payload_qos => open,
        dBusAxi_aw_payload_prot => open,
        dBusAxi_w_valid => axi_master_to_slave(C_axi_dbus_id).wvalid,
        dBusAxi_w_ready => axi_slave_to_master(C_axi_dbus_id).wready,
        dBusAxi_w_payload_data => axi_master_to_slave(C_axi_dbus_id).wdata,
        dBusAxi_w_payload_strb => axi_master_to_slave(C_axi_dbus_id).wstrb,
        dBusAxi_w_payload_last => axi_master_to_slave(C_axi_dbus_id).wlast,
        dBusAxi_b_valid => axi_slave_to_master(C_axi_dbus_id).bvalid,
        dBusAxi_b_ready => axi_master_to_slave(C_axi_dbus_id).bready,
        dBusAxi_b_payload_id => "0",
        dBusAxi_b_payload_resp => axi_slave_to_master(C_axi_dbus_id).bresp,
        dBusAxi_ar_valid => axi_master_to_slave(C_axi_dbus_id).arvalid,
        dBusAxi_ar_ready => axi_slave_to_master(C_axi_dbus_id).arready,
        std_logic_vector(dBusAxi_ar_payload_addr) => axi_master_to_slave(C_axi_dbus_id).araddr,
        dBusAxi_ar_payload_id => open,
        dBusAxi_ar_payload_region => open,
        std_logic_vector(dBusAxi_ar_payload_len) => axi_master_to_slave(C_axi_dbus_id).arlen,
        std_logic_vector(dBusAxi_ar_payload_size) => axi_master_to_slave(C_axi_dbus_id).arsize,
        std_logic_vector(dBusAxi_ar_payload_burst) => axi_master_to_slave(C_axi_dbus_id).arburst,
        dBusAxi_ar_payload_lock => open,
        dBusAxi_ar_payload_cache => open,
        dBusAxi_ar_payload_qos => open,
        dBusAxi_ar_payload_prot => open,
        dBusAxi_r_valid => axi_slave_to_master(C_axi_dbus_id).rvalid,
        dBusAxi_r_ready => axi_master_to_slave(C_axi_dbus_id).rready,
        dBusAxi_r_payload_data => axi_slave_to_master(C_axi_dbus_id).rdata,
        dBusAxi_r_payload_id => "0",
        dBusAxi_r_payload_resp => axi_slave_to_master(C_axi_dbus_id).rresp,
        dBusAxi_r_payload_last => axi_slave_to_master(C_axi_dbus_id).rlast,
        jtag_tms => '0',
        jtag_tck => '0',
        jtag_tdi => '0',
        jtag_tdo => open,
        clk => clk,
        reset => reset,
        debugReset => '0'
    );
    --
    -- Boot ROM
    --
    I_rom: entity work.rom
    generic map (
	C_arch => 1, -- riscv
	C_big_endian => false,
	C_boot_spi => C_boot_spi,
	C_srec_file => C_bootloader_filename
    )
    port map (
	clk => clk,
	strobe => rom_strobe,
	addr(11 downto 2) => io_addr,
	addr(31 downto 12) => (others => '0'),
	data_out => rom_rdata,
	data_ready => rom_ready
    );

    --
    -- RS232 SIO
    --
    G_sio: for i in 0 to C_sio - 1 generate
	I_sio: entity work.sio
	generic map (
	    C_clk_freq => C_clk_freq_hz / 1000000,
	    C_init_baudrate => C_sio_init_baudrate,
	    C_fixed_baudrate => C_sio_fixed_baudrate,
	    C_break_detect => C_sio_break_detect,
	    C_break_resets_baudrate => C_sio_break_detect
	)
	port map (
	    clk => clk, txd => sio_tx(i), rxd => sio_rx(i), ce => sio_ce(i),
	    bus_write => io_write, bus_addr => io_addr(3 downto 2),
	    bus_in => cpu_to_io, bus_out => from_sio(i),
	    rx_ready => open, break => sio_break(i)
	);
	sio_ce(i) <= io_strobe and not sio_ce(i) when sio_io_range and
	  conv_integer(io_addr(5 downto 4)) = i and rising_edge(clk);
    end generate;
    sio_io_range <= io_addr(11 downto 4) = C_io_sio0
      or io_addr(11 downto 4) = C_io_sio1
      or io_addr(11 downto 4) = C_io_sio2
      or io_addr(11 downto 4) = C_io_sio3;
    sio_txd(0) <= sio_tx(0);
    sio_rx(0) <= sio_rxd(0);

    --
    -- RTC
    --
    G_rtc: if C_rtc generate
    I_rtc: entity work.rtc
    generic map (
	C_clk_freq_hz => C_clk_freq_hz
    )
    port map (
	clk => clk, ce => rtc_ce,
	bus_addr => io_addr(3 downto 2),
	bus_write => io_write, byte_sel => io_byte_sel,
	bus_in => cpu_to_io, bus_out => from_rtc
    );
    rtc_ce <= io_strobe when rtc_io_range else '0';
    rtc_io_range <= io_addr(11 downto 4) = C_io_rtc;
    end generate;

    --
    -- SDRAM
    --
    sdram: entity work.sdram_controller
    generic map (
	C_ports => 1,
	C_ras => C_ras, C_cas => C_cas, C_pre => C_pre,
	C_clock_range => C_clock_range,
	C_address_width => C_sdram_address_width,
	C_column_bits => C_sdram_column_bits,
	C_startup_cycles => C_sdram_startup_cycles,
	C_cycles_per_refresh => C_sdram_cycles_per_refresh
    )
    port map (
	clk => clk, reset => reset,
	-- internal connections
	req => sdram_req, resp => sdram_resp,
	snoop_cycle => open, snoop_addr => open,
	-- external SDRAM interface
	sdram_addr => sdram_addr, sdram_data => sdram_data,
	sdram_ba => sdram_ba, sdram_dqm => sdram_dqm,
	sdram_ras => sdram_ras, sdram_cas => sdram_cas,
	sdram_cke => sdram_cke, sdram_clk => sdram_clk,
	sdram_we => sdram_we, sdram_cs => sdram_cs
    );
    sdram_req(0).addr <= bus_adr(31 downto 2);
    sdram_req(0).data_in <= bus_wdata;
    sdram_req(0).byte_sel <= bus_bsel;
    sdram_req(0).burst_len <= bus_burst_len;
    sdram_req(0).write <= bus_we;
    sdram_req(0).strobe <= sdram_strobe;

    --
    -- Simple I/O
    --
    process(clk)
    begin
	if rising_edge(clk) then
	    -- Simple input synchronizer
	    if C_simple_in > 0 then
		R_simple_in(C_simple_in - 1 downto 0) <=
		  simple_in(C_simple_in - 1 downto 0);
	    end if;
	end if;

	if rising_edge(clk) and io_strobe = '1'
	  and io_write = '1' then
	    -- simple out
	    if C_simple_out > 0 and
	      io_addr(11 downto 4) = C_io_simple_out then
		if io_byte_sel(0) = '1' then
		    R_simple_out(7 downto 0) <= cpu_to_io(7 downto 0);
		end if;
		if io_byte_sel(1) = '1' then
		    R_simple_out(15 downto 8) <= cpu_to_io(15 downto 8);
		end if;
		if io_byte_sel(2) = '1' then
		    R_simple_out(23 downto 16) <= cpu_to_io(23 downto 16);
		end if;
		if io_byte_sel(3) = '1' then
		    R_simple_out(31 downto 24) <= cpu_to_io(31 downto 24);
		end if;
	    end if;
	end if;
    end process;
    simple_out <= R_simple_out;

    --
    -- SPI
    --
    G_spi: for i in 0 to C_spi - 1 generate
	I_spi: entity work.spi
	generic map (
	    C_fixed_speed => C_spi_fixed_speed(i) = '1'
	)
	port map (
	    clk => clk, ce => spi_ce(i),
	    bus_write => io_write, byte_sel => io_byte_sel,
	    bus_in => cpu_to_io, bus_out => from_spi(i),
	    spi_sck => spi_sck(i),
	    spi_cen(0) => spi_ss0(i), spi_cen(1) => spi_ss1(i),
	    spi_cen(2) => spi_ss2(i), spi_cen(3) => spi_ss3(i),
	    spi_miso => spi_miso(i), spi_mosi => spi_mosi(i)
	);
	spi_ce(i) <= io_strobe when spi_io_range and
	  conv_integer(io_addr(5 downto 4)) = i else '0';
    end generate;
    spi_io_range <= io_addr(11 downto 4) = C_io_spi0
      or io_addr(11 downto 4) = C_io_spi1
      or io_addr(11 downto 4) = C_io_spi2
      or io_addr(11 downto 4) = C_io_spi3;

    --
    -- General Address Decoder
    --
    process(bus_stb, bus_adr, io_to_cpu, io_strobe, rom_rdata, rom_ready,
      bus_ack_delay_1c, sdram_strobe, sdram_resp)
    begin
	sdram_strobe <= '0';
	rom_strobe <= '0';
	bus_rdata <= (others => '0');
	bus_ack <= '0';
	if bus_adr(31 downto 28) = X"8" then
	    sdram_strobe <= bus_stb;
	end if;

	if io_strobe = '1' then
	    bus_rdata <= io_to_cpu;
	    bus_ack <= bus_ack_delay_1c;
	elsif sdram_strobe = '1' then
	    bus_rdata <= sdram_resp(0).data_out;
	    bus_ack <= sdram_resp(0).data_ready;
	else
	    rom_strobe <= bus_stb;
	    bus_rdata <= rom_rdata;
	    bus_ack <= rom_ready;
	end if;
    end process;
    bus_ack_delay_1c <= io_strobe and not bus_ack_delay_1c when rising_edge(clk);

    --
    -- I/O Address Decoder
    --
    io_strobe <= '1' when bus_adr(31 downto 28) = X"F" and bus_stb = '1' else '0';
    io_addr <= '0' & bus_adr(10 downto 2);
    io_byte_sel <= bus_bsel;
    io_write <= bus_we;
    cpu_to_io <= bus_wdata;
    process(io_addr, from_sio, from_spi, from_rtc, R_simple_in, R_simple_out)
    begin
	io_to_cpu <= (others => '0');
	case io_addr(11 downto 4) is
	when C_io_sio0 | C_io_sio1 | C_io_sio2 | C_io_sio3 =>
	    for i in 0 to C_sio - 1 loop
		if conv_integer(io_addr(5 downto 4)) = i then
		    io_to_cpu <= from_sio(i);
		end if;
	    end loop;
	when C_io_spi0 | C_io_spi1 | C_io_spi2 | C_io_spi3 =>
	    for i in 0 to C_spi - 1 loop
		if conv_integer(io_addr(5 downto 4)) = i then
		    io_to_cpu <= from_spi(i);
		end if;
	    end loop;
	when C_io_simple_in =>
	    for i in 0 to (C_simple_in + 31) / 4 - 1 loop
		if conv_integer(io_addr(3 downto 2)) = i then
		    io_to_cpu(C_simple_in - i * 32 - 1 downto i * 32) <=
		      R_simple_in(C_simple_in - i * 32 - 1 downto i * 32);
		end if;
	    end loop;
	when C_io_simple_out =>
	    for i in 0 to (C_simple_out + 31) / 4 - 1 loop
		if conv_integer(io_addr(3 downto 2)) = i then
		    io_to_cpu(C_simple_out - i * 32 - 1 downto i * 32) <=
		      R_simple_out(C_simple_out - i * 32 - 1 downto i * 32);
		end if;
	    end loop;
	when C_io_rtc =>
	    io_to_cpu <= from_rtc;
	when others  =>
	    io_to_cpu <= (others => '0');
	end case;
    end process;

    --
    -- AXI4 to External Bus Conversion Logic
    --
    I_axi_bridge: entity work.axi_bridge
    generic map(
        C_axi_ports => 2,
        C_enable_native_read_bursts => true,
        C_enable_native_write_bursts => true,
        C_enable_read_buffering => false,
	C_enable_microblaze_sdram_optimizations => false,
        C_read_buffer_max_size => 8
    )
    port map(
        clk => clk,
        reset => reset,
        master_to_slave_i(0) => axi_master_to_slave(0),
        master_to_slave_i(1) => axi_master_to_slave(1),
        slave_to_master_o(0) => axi_slave_to_master(0),
        slave_to_master_o(1) => axi_slave_to_master(1),

        bus_adr => bus_adr,
        bus_rdata => bus_rdata,
        bus_wdata => bus_wdata,
        bus_burst_len => bus_burst_len,
        bus_we => bus_we,
        bus_bsel => bus_bsel,
        bus_stb => bus_stb,
        bus_ack => bus_ack
    );
end x;
