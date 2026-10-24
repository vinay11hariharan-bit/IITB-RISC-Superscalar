library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;

entity BP_Unit is
    generic ( BP_DEPTH_BITS : integer := 5 );
    Port (
        clk             : in  std_logic;
        rst             : in  std_logic;
        
        -- Combinatorial Reads for Fetch
        fetch_pc_1      : in  Data_Bus; predict_valid_1 : out std_logic; predict_target_1: out Data_Bus;
        fetch_pc_2      : in  Data_Bus; predict_valid_2 : out std_logic; predict_target_2: out Data_Bus;
        
        -- Synchronous Writes driven exclusively by ROB Commit
        update_en       : in  std_logic;
        update_pc       : in  Data_Bus;
        update_taken    : in  std_logic;
        update_target   : in  Data_Bus
    );
end BP_Unit;

architecture Behavioral of BP_Unit is

    constant SNT : std_logic_vector(1 downto 0) := "00"; -- Strongly Not Taken
    constant WNT : std_logic_vector(1 downto 0) := "01"; -- Weakly Not Taken
    constant WT  : std_logic_vector(1 downto 0) := "10"; -- Weakly Taken
    constant ST  : std_logic_vector(1 downto 0) := "11"; -- Strongly Taken

    type BP_Entry is record
        Valid      : std_logic;
        Tag        : std_logic_vector((DATA_WIDTH - BP_DEPTH_BITS - 2) downto 0);
        History    : std_logic_vector(1 downto 0);
        Taken_PC   : Data_Bus;
    end record;
    
    constant NUM_ENTRIES : integer := 2**BP_DEPTH_BITS;
    type BP_Array is array (0 to NUM_ENTRIES-1) of BP_Entry;
    signal bp_table : BP_Array;

    function get_index(pc : Data_Bus) return integer is
    begin return to_integer(unsigned(pc(BP_DEPTH_BITS downto 1))); end function;
    
    function get_tag(pc : Data_Bus) return std_logic_vector is
    begin return pc(DATA_WIDTH-1 downto BP_DEPTH_BITS+1); end function;

begin

    -- Combinatorial Prediction
    process(fetch_pc_1, fetch_pc_2, bp_table)
        variable idx_1, idx_2 : integer;
        variable tag_1, tag_2 : std_logic_vector((DATA_WIDTH - BP_DEPTH_BITS - 2) downto 0);
    begin
        predict_valid_1 <= '0'; predict_target_1 <= (others => '0');
        predict_valid_2 <= '0'; predict_target_2 <= (others => '0');
        idx_1 := get_index(fetch_pc_1); tag_1 := get_tag(fetch_pc_1);
        idx_2 := get_index(fetch_pc_2); tag_2 := get_tag(fetch_pc_2);
        
        if bp_table(idx_1).Valid = '1' and bp_table(idx_1).Tag = tag_1 then
            if bp_table(idx_1).History = WT or bp_table(idx_1).History = ST then
                predict_valid_1 <= '1'; predict_target_1 <= bp_table(idx_1).Taken_PC;
            end if;
        end if;
        if bp_table(idx_2).Valid = '1' and bp_table(idx_2).Tag = tag_2 then
            if bp_table(idx_2).History = WT or bp_table(idx_2).History = ST then
                predict_valid_2 <= '1'; predict_target_2 <= bp_table(idx_2).Taken_PC;
            end if;
        end if;
    end process;

    -- Synchronous Table Management
    process(clk)
        variable u_idx : integer;
        variable u_tag : std_logic_vector((DATA_WIDTH - BP_DEPTH_BITS - 2) downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                for i in 0 to NUM_ENTRIES-1 loop
                    bp_table(i).Valid <= '0'; bp_table(i).History <= SNT;
                end loop;
            else
                if update_en = '1' then
                    u_idx := get_index(update_pc); 
                    u_tag := get_tag(update_pc);
                    
                    if bp_table(u_idx).Valid = '1' and bp_table(u_idx).Tag = u_tag then
                        -- BTB Hit: Transition the existing 2-bit state machine
                        if update_taken = '1' then
                            if bp_table(u_idx).History = SNT then bp_table(u_idx).History <= WNT;
                            elsif bp_table(u_idx).History = WNT then bp_table(u_idx).History <= WT;
                            elsif bp_table(u_idx).History = WT  then bp_table(u_idx).History <= ST;
                            end if;
                        else
                            if bp_table(u_idx).History = ST  then bp_table(u_idx).History <= WT;
                            elsif bp_table(u_idx).History = WT  then bp_table(u_idx).History <= WNT;
                            elsif bp_table(u_idx).History = WNT then bp_table(u_idx).History <= SNT;
                            end if;
                        end if;
                        bp_table(u_idx).Taken_PC <= update_target;
                    else
                        -- BTB Miss: New branch finished executing, allocate it now
                        bp_table(u_idx).Valid <= '1';
                        bp_table(u_idx).Tag <= u_tag;
                        bp_table(u_idx).Taken_PC <= update_target;
                        
                        -- Set initial state based on what just actually happened
                        if update_taken = '1' then
                            bp_table(u_idx).History <= WT; 
                        else
                            bp_table(u_idx).History <= WNT;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

end Behavioral;