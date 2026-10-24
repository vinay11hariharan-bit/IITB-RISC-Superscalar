library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;

entity Store_Buffer is
    generic (
        BUFFER_DEPTH : integer := 8
    );
    Port (
        clk             : in  std_logic;
        rst             : in  std_logic;
        
        -- Input from ROB Commit Stage
        commit_valid    : in  std_logic;
        commit_is_store : in  std_logic;
        commit_addr     : in  Data_Bus;
        commit_data     : in  Data_Bus;
        
        -- LSQ Snooping Interface (Store-to-Load Forwarding)
        snoop_addr      : in  Data_Bus;
        snoop_hit       : out std_logic;
        snoop_data      : out Data_Bus;
        
        -- Output to Actual Data Memory (DMEM)
        dmem_req        : out std_logic;
        dmem_rw         : out std_logic; -- 1 = Write
        dmem_addr       : out Data_Bus;
        dmem_wdata      : out Data_Bus;
        dmem_ack        : in  std_logic
    );
end Store_Buffer;

architecture Behavioral of Store_Buffer is

    type SB_Entry is record
        Valid : std_logic;
        Addr  : Data_Bus;
        Data  : Data_Bus;
    end record;
    
    type SB_Array is array (0 to BUFFER_DEPTH-1) of SB_Entry;
    signal sb_fifo : SB_Array;
    signal head, tail, count : integer range 0 to BUFFER_DEPTH := 0;

begin

    -- =========================================================
    -- LSQ Snooping Logic (Combinatorial)
    -- =========================================================
    -- If a Load in the LSQ has the same address as a pending Store, 
    -- it MUST get its data from here, not RAM. (Searches from newest to oldest).
    process(snoop_addr, sb_fifo, count, tail)
        variable hit : std_logic;
        variable fwd_data : Data_Bus;
        variable idx : integer;
    begin
        hit := '0';
        fwd_data := (others => '0');
        
        if count > 0 then
            -- Iterate backwards from tail to head to find the most recent matching store
            for i in 1 to BUFFER_DEPTH loop
                if i <= count then
                    idx := (tail - i + BUFFER_DEPTH) mod BUFFER_DEPTH;
                    if sb_fifo(idx).Valid = '1' and sb_fifo(idx).Addr = snoop_addr then
                        hit := '1';
                        fwd_data := sb_fifo(idx).Data;
                        exit; -- Found the most recent, stop looking
                    end if;
                end if;
            end loop;
        end if;
        
        snoop_hit <= hit;
        snoop_data <= fwd_data;
    end process;

    -- =========================================================
    -- FIFO Management & DMEM Issue
    -- =========================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                head <= 0; tail <= 0; count <= 0;
                dmem_req <= '0';
                for i in 0 to BUFFER_DEPTH-1 loop sb_fifo(i).Valid <= '0'; end loop;
            else
                
                -- 1. Pop from FIFO to DMEM
                if count > 0 and sb_fifo(head).Valid = '1' then
                    dmem_req <= '1';
                    dmem_rw  <= '1'; -- Stores are always writes
                    dmem_addr <= sb_fifo(head).Addr;
                    dmem_wdata <= sb_fifo(head).Data;
                    
                    if dmem_ack = '1' then
                        -- Memory accepted the write, retire it
                        sb_fifo(head).Valid <= '0';
                        head <= (head + 1) mod BUFFER_DEPTH;
                        count <= count - 1;
                        dmem_req <= '0';
                    end if;
                else
                    dmem_req <= '0';
                end if;

                -- 2. Push into FIFO from ROB Commit
                if commit_valid = '1' and commit_is_store = '1' and count < BUFFER_DEPTH then
                    sb_fifo(tail).Valid <= '1';
                    sb_fifo(tail).Addr  <= commit_addr;
                    sb_fifo(tail).Data  <= commit_data;
                    
                    tail <= (tail + 1) mod BUFFER_DEPTH;
                    
                    -- If we also popped this cycle, count doesn't change
                    if not (count > 0 and sb_fifo(head).Valid = '1' and dmem_ack = '1') then
                        count <= count + 1;
                    end if;
                end if;

            end if;
        end if;
    end process;

end Behavioral;