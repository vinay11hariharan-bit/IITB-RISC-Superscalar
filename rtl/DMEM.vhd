-- =====================================================================
-- Data memory: byte-addressed, 16-bit words, two independent ports
--   * read port  (LSQ loads)       : synchronous, data valid next cycle
--   * write port (Store Buffer)    : synchronous
-- A read and a write to the same word in the same cycle returns the old
-- value; the LSQ never relies on that, because a store still in the Store
-- Buffer is forwarded instead.
-- =====================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;
use work.Mem_Init_Pkg.ALL;

entity DMEM is
    generic (
        ADDR_BITS : integer := DMEM_ADDR_BITS;  -- 2**10 words = 2 KB (keep equal to DMEM_ADDR_BITS)
        INIT_FILE : string  := ""      -- optional hex file (see Mem_Init_Pkg)
    );
    Port (
        clk      : in  std_logic;
        rd_en    : in  std_logic;
        rd_addr  : in  Data_Bus;
        rd_data  : out Data_Bus;
        we       : in  std_logic;
        wr_addr  : in  Data_Bus;
        wr_data  : in  Data_Bus
    );
end DMEM;

architecture Behavioral of DMEM is
    constant DEFAULT_CONTENTS : Word_Array(0 to 2**ADDR_BITS-1) := (
        0 => x"0000", 1 => x"0001", 2 => x"0002", 3 => x"0003",
        4 => x"0004", 5 => x"0005", 6 => x"0006", 7 => x"0007",
        others => x"0000");
    signal ram : Word_Array(0 to 2**ADDR_BITS-1) := load_hex(INIT_FILE, 2**ADDR_BITS, DEFAULT_CONTENTS);
begin
    process(clk)
    begin
        if rising_edge(clk) then
            if rd_en = '1' then
                rd_data <= ram(to_integer(unsigned(rd_addr(ADDR_BITS downto 1))));
            end if;
            if we = '1' then
                ram(to_integer(unsigned(wr_addr(ADDR_BITS downto 1)))) <= wr_data;
            end if;
        end if;
    end process;
end Behavioral;
