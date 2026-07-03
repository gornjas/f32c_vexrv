library IEEE;

use IEEE.STD_LOGIC_1164.ALL;

package axi_pkg is
    type T_axi_master_to_slave is record
	-- ADDRESS WRITE CHANNEL
	awaddr: std_logic_vector(31 downto 0);
	awburst: std_logic_vector(1 downto 0);
	awsize: std_logic_vector(2 downto 0);
	awlen: std_logic_vector(7 downto 0);
	awvalid: std_logic;
	-- WRITE CHANNEL
	wdata: std_logic_vector(31 downto 0);
	wstrb: std_logic_vector(3 downto 0);
	wlast: std_logic;
	wvalid: std_logic;
	-- WRITE RESPONSE CHANNEL
	bready: std_logic;
	-- READ ADDRESS CHANNEL
	araddr: std_logic_vector(31 downto 0);
	arburst: std_logic_vector(1 downto 0);
	arsize: std_logic_vector(2 downto 0);
	arlen: std_logic_vector(7 downto 0);
	arvalid: std_logic;
	-- READ DATA CHANNEL
	rready: std_logic;
    end record;

    type T_axi_slave_to_master is record
	-- ADDRESS WRITE CHANNEL
	awready: std_logic;
	-- WRITE CHANNEL
	wready: std_logic;
	-- WRITE RESPONSE CHANNEL
	bresp: std_logic_vector(1 downto 0);
	bvalid: std_logic;
	-- READ ADDRESS CHANNEL
	arready: std_logic;
	-- READ DATA CHANNEL
	rdata: std_logic_vector(31 downto 0);
	rresp: std_logic_vector(1 downto 0);
	rlast: std_logic;
	rvalid: std_logic;
    end record;

    type T_master_to_slave_bus_array is array (natural range<>) of T_axi_master_to_slave;
    type T_slave_to_master_bus_array is array (natural range<>) of T_axi_slave_to_master;
end package axi_pkg;