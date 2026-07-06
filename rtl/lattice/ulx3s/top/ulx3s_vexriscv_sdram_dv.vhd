library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;

library ecp5u;
use ecp5u.components.all;


entity ulx3s_vexriscv_sdram is
    generic (
	C_clk_freq_hz: natural := 74250000;
	C_spi: natural := 2
    );
    port (
	clk_25m: in std_logic;

	-- SDRAM
	sdram_clk: out std_logic;
	sdram_cke: out std_logic;
	sdram_csn: out std_logic;
	sdram_rasn: out std_logic;
	sdram_casn: out std_logic;
	sdram_wen: out std_logic;
	sdram_a: out std_logic_vector(12 downto 0);
	sdram_ba: out std_logic_vector(1 downto 0);
	sdram_dqm: out std_logic_vector(1 downto 0);
	sdram_d: inout std_logic_vector(15 downto 0);

	-- On-board simple IO
	led: out std_logic_vector(7 downto 0);

	-- SIO0 (FTDI)
	rs232_tx: out std_logic;
	rs232_rx: in std_logic;

	-- SPI flash (SPI #0)
	flash_so: inout std_logic;
	flash_si: inout std_logic;
	flash_cen: out std_logic;
	--flash_sck: out std_logic; -- accessed via special ECP5 primitive
	flash_holdn, flash_wpn: out std_logic := '1';

	-- SD card (SPI #1)
	sd_cmd: inout std_logic;
	sd_clk: out std_logic;
	sd_d: inout std_logic_vector(3 downto 0);
	sd_cdn: in std_logic;
	sd_wp: in std_logic;

	-- '1' = power off
	shutdown: out std_logic := '0'
    );
end ulx3s_vexriscv_sdram;

architecture x of ulx3s_vexriscv_sdram is
    signal clk, pll_lock: std_logic;
    signal cpu_reset: std_logic;
    signal sio_break: std_logic;
    signal flash_sck: std_logic;
    signal flash_csn: std_logic;

begin
    -- VexRiscV SoC
    I_top: entity work.glue_vexriscv_sdram
    generic map (
	C_clk_freq_hz => C_clk_freq_hz,
	C_spi => C_spi,
	C_bootloader_filename => "../../../../../soc/boot/riscv_spi.srec"
    )
    port map (
	clk => clk,
	reset => cpu_reset,

	sdram_clk => open,
	sdram_cke => sdram_cke,
	sdram_cs => sdram_csn,
	sdram_we => sdram_wen,
	sdram_ba => sdram_ba,
	sdram_dqm => sdram_dqm,
	sdram_ras => sdram_rasn,
	sdram_cas => sdram_casn,
	sdram_addr => sdram_a,
	sdram_data => sdram_d,

	spi_ss0(0) => flash_csn,
	spi_ss0(1) => sd_d(3),
	spi_sck(0) => flash_sck,
	spi_sck(1) => sd_clk,
	spi_mosi(0) => flash_si,
	spi_mosi(1) => sd_cmd,
	spi_miso(0) => flash_so,
	spi_miso(1) => sd_d(0),

	sio_rxd(0) => rs232_rx,
	sio_txd(0) => rs232_tx,
	sio_break(0) => sio_break,

	simple_out(7 downto 0) => led
    );

    -- Route SDRAM clock through a DDR register for precise signal timings
    I_sdram_clk: ODDRX1F
    port map (sclk => clk, rst => '0', d0 => '0', d1 => '1', Q => sdram_clk);

    -- SPI flash clock has to be routed through a ECP5-specific primitive
    I_flash_mux: USRMCLK
    port map (
	USRMCLKTS => flash_csn,
	USRMCLKI => flash_sck
    );
    flash_cen <= flash_csn;

    I_pll: entity work.pll_25m
    port map (
	clk_25m => clk_25m,
	clk_74m25 => clk,
	lock => pll_lock
    );

    cpu_reset <= sio_break or not pll_lock;
end x;
