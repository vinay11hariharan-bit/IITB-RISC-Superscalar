-- =====================================================================
-- Store Buffer (post-commit)
--
-- Holds stores that the ROB has already committed and drains them, oldest
-- first, into DMEM through its own write port (one store per cycle).
-- Every entry here is architecturally committed, so this buffer is NOT
-- cleared by a pipeline flush.
--
-- Loads in the LSQ look up their address here: the youngest matching
-- store forwards its data, since DMEM has not been written yet.
-- =====================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;

entity Store_Buffer is
    generic ( BUFFER_DEPTH : integer := 8 );
    Port (
        clk, rst    : in  std_logic;

        -- Committed stores from the LSQ (push 1 is older than push 2)
        push_1      : in  std_logic; addr_1 : in Data_Bus; data_1 : in Data_Bus;
        push_2      : in  std_logic; addr_2 : in Data_Bus; data_2 : in Data_Bus;
        sb_ready    : out std_logic;  -- room for two more stores (the ROB may commit two per cycle)
        sb_empty    : out std_logic;

        -- Forwarding lookup
        snoop_addr  : in  Data_Bus;
        snoop_hit   : out std_logic;
        snoop_data  : out Data_Bus;

        -- DMEM write port
        dmem_we     : out std_logic;
        dmem_addr   : out Data_Bus;
        dmem_wdata  : out Data_Bus
    );
end Store_Buffer;

architecture Behavioral of Store_Buffer is
    type SB_Entry is record Addr, Data : Data_Bus; end record;
    type SB_Array is array (0 to BUFFER_DEPTH-1) of SB_Entry;
    signal sb    : SB_Array;
    signal head, tail : integer range 0 to BUFFER_DEPTH-1 := 0;
    signal count : integer range 0 to BUFFER_DEPTH := 0;
begin
    sb_ready <= '1' when count <= BUFFER_DEPTH-2 else '0';
    sb_empty <= '1' when count = 0 else '0';

    -- drain the oldest store every cycle
    dmem_we    <= '1' when count > 0 else '0';
    dmem_addr  <= sb(head).Addr;
    dmem_wdata <= sb(head).Data;

    -- youngest matching store (same DMEM word, see same_word in RISC_Types_Pkg)
    process(snoop_addr, sb, head, count)
        variable idx : integer range 0 to BUFFER_DEPTH-1;
    begin
        snoop_hit <= '0'; snoop_data <= (others => '0');
        for k in 0 to BUFFER_DEPTH-1 loop          -- oldest -> youngest, later match overrides
            if k < count then
                idx := (head + k) mod BUFFER_DEPTH;
                if same_word(sb(idx).Addr, snoop_addr) then
                    snoop_hit <= '1'; snoop_data <= sb(idx).Data;
                end if;
            end if;
        end loop;
    end process;

    process(clk)
        variable nh, nt : integer range 0 to BUFFER_DEPTH-1;
        variable nc : integer range 0 to BUFFER_DEPTH;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                head <= 0; tail <= 0; count <= 0;
            else
                nh := head; nt := tail; nc := count;
                if nc > 0 then nh := (nh + 1) mod BUFFER_DEPTH; nc := nc - 1; end if;  -- written to DMEM this edge
                if push_1 = '1' then sb(nt) <= (addr_1, data_1); nt := (nt + 1) mod BUFFER_DEPTH; nc := nc + 1; end if;
                if push_2 = '1' then sb(nt) <= (addr_2, data_2); nt := (nt + 1) mod BUFFER_DEPTH; nc := nc + 1; end if;
                head <= nh; tail <= nt; count <= nc;
            end if;
        end if;
    end process;
end Behavioral;
