library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;

entity DMEM is
    generic (
        ADDR_BITS : integer := 10 
    );
    Port (
        clk        : in  std_logic;
        
        -- Interface from LSQ / Store_Buffer
        mem_req    : in  std_logic;
        mem_rw     : in  std_logic; -- 0 = Read, 1 = Write
        mem_addr   : in  Data_Bus;
        mem_wdata  : in  Data_Bus;
        
        -- Outputs back to LSQ
        mem_rdata  : out Data_Bus;
        mem_ack    : out std_logic
    );
end DMEM;

architecture Behavioral of DMEM is

    -- 16-bit (2 byte) wide array
    type Mem_Array is array (0 to (2**ADDR_BITS)-1) of std_logic_vector(15 downto 0);
    signal ram : Mem_Array := (
        0 => x"0000",
        1 => x"0001",
        2 => x"0002",
        3 => x"0003",
        4 => x"0004",
        5 => x"0005",
        6 => x"0006",
        7 => x"0007",
        others => x"0000"
    );

    signal word_addr : unsigned(ADDR_BITS-1 downto 0);

begin

    -- Strip the LSB for 16-bit word alignment
    word_addr <= unsigned(mem_addr(ADDR_BITS downto 1));

    process(clk)
    begin
        if rising_edge(clk) then
            -- Default state
            mem_ack <= '0';
            
            if mem_req = '1' then
                if mem_rw = '1' then
                    -- Write Operation (2 bytes)
                    ram(to_integer(word_addr)) <= mem_wdata;
                    mem_ack <= '1';
                else
                    -- Read Operation (2 bytes)
                    mem_rdata <= ram(to_integer(word_addr));
                    mem_ack <= '1';
                end if;
            end if;
        end if;
    end process;

end Behavioral;