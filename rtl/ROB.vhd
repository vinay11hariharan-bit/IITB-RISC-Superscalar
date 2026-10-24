library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;

entity ROB is
    Port (
        clk             : in  std_logic;
        rst             : in  std_logic;
        
        next_alloc_1    : out Rob_Tag;
        next_alloc_2    : out Rob_Tag;
        rob_full        : out std_logic;
        
        disp_en_1       : in  std_logic;
        bundle_1        : in  Instr_Bundle;
        dest_tag_1      : in  Reg_Tag;
        is_micro_op_1   : in  std_logic;
        
        disp_en_2       : in  std_logic;
        bundle_2        : in  Instr_Bundle;
        dest_tag_2      : in  Reg_Tag;
        is_micro_op_2   : in  std_logic;
        
        cdb1_valid      : in  std_logic;
        cdb1_rob_tag    : in  Rob_Tag;
        cdb1_val        : in  Data_Bus;
        cdb1_act_pc     : in  Data_Bus;
        cdb1_flags      : in  std_logic_vector(1 downto 0);
        cdb1_mask       : in  std_logic_vector(1 downto 0);
        
        cdb2_valid      : in  std_logic;
        cdb2_rob_tag    : in  Rob_Tag;
        cdb2_val        : in  Data_Bus;
        cdb2_act_pc     : in  Data_Bus;
        cdb2_flags      : in  std_logic_vector(1 downto 0);
        cdb2_mask       : in  std_logic_vector(1 downto 0);
        
        commit_en_1     : out std_logic;
        commit_opcode_1 : out std_logic_vector(3 downto 0);
        commit_rob_tag_1: out Rob_Tag;
        commit_arf_1    : out Arf_Tag;
        commit_rrf_1    : out Reg_Tag;
        commit_val_1    : out Data_Bus;
        commit_flags_1  : out std_logic_vector(1 downto 0);
        commit_mask_1   : out std_logic_vector(1 downto 0);
        
        commit_en_2     : out std_logic;
        commit_opcode_2 : out std_logic_vector(3 downto 0);
        commit_rob_tag_2: out Rob_Tag;
        commit_arf_2    : out Arf_Tag;
        commit_rrf_2    : out Reg_Tag;
        commit_val_2    : out Data_Bus;
        commit_flags_2  : out std_logic_vector(1 downto 0);
        commit_mask_2   : out std_logic_vector(1 downto 0);
        
        -- Store Buffer has room for two committed stores
        sb_ready        : in  std_logic;

        flush_pipeline  : out std_logic;
        recovery_pc     : out Data_Bus;
        
        bp_train_en     : out std_logic;
        bp_train_pc     : out Data_Bus;
        bp_train_target : out Data_Bus;
        bp_train_taken  : out std_logic
    );
end ROB;

architecture Behavioral of ROB is
    type ROB_Entry is record
        Busy         : std_logic;
        Valid        : std_logic;
        Opcode       : std_logic_vector(3 downto 0);
        Instr_PC     : Data_Bus;   
        Dest_ARF     : Arf_Tag;
        Dest_RRF     : Reg_Tag;
        Predicted_PC : Data_Bus;
        Actual_PC    : Data_Bus;
        Is_Control   : std_logic;
        Is_Micro_Op  : std_logic;
        Value        : Data_Bus;
        Flags        : std_logic_vector(1 downto 0);
        Mask         : std_logic_vector(1 downto 0);
    end record;
    
    type ROB_Array is array (0 to ROB_DEPTH-1) of ROB_Entry;
    signal rob_table : ROB_Array;
    signal head, tail : integer range 0 to ROB_DEPTH-1 := 0;
    signal count      : integer range 0 to ROB_DEPTH   := 0;
begin

    next_alloc_1 <= tail;
    next_alloc_2 <= (tail + 1) mod ROB_DEPTH;
    rob_full <= '1' when count >= (ROB_DEPTH - 1) else '0';

    process(clk)
        variable n_head, n_tail, n_count : integer;
        variable cdb1_idx, cdb2_idx      : integer;
        variable v_flush                 : std_logic; -- THE FIX: Internal variable for flush state
        variable store_ok                : boolean;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                head <= 0; tail <= 0; count <= 0; flush_pipeline <= '0';
                commit_en_1 <= '0'; commit_en_2 <= '0';
                bp_train_en <= '0'; bp_train_pc <= (others=>'0'); bp_train_target <= (others=>'0'); bp_train_taken <= '0';
                for i in 0 to ROB_DEPTH-1 loop rob_table(i).Busy <= '0'; end loop;
            else
                n_head := head; n_tail := tail; n_count := count;
                flush_pipeline <= '0'; commit_en_1 <= '0'; commit_en_2 <= '0'; 
                bp_train_en <= '0'; 
                v_flush := '0'; -- Reset flush tracking variable
                store_ok := sb_ready = '1';

                -- PROCESS THE HEAD OF THE ROB
                if n_count > 0 and rob_table(n_head).Busy = '1' and rob_table(n_head).Valid = '1'
                   and (store_ok or rob_table(n_head).Opcode /= OP_SW) then
                    
                    -- 1. BP Training 
                    if rob_table(n_head).Is_Control = '1' then
                        bp_train_en     <= '1';
                        bp_train_pc     <= rob_table(n_head).Instr_PC;
                        bp_train_target <= rob_table(n_head).Actual_PC;
                        
                        if rob_table(n_head).Actual_PC /= std_logic_vector(unsigned(rob_table(n_head).Instr_PC) + 2) then
                            bp_train_taken <= '1';
                        else
                            bp_train_taken <= '0';
                        end if;
                    end if;

                    -- 2. Misprediction Flush Check
                    if rob_table(n_head).Is_Control = '1' and (rob_table(n_head).Actual_PC /= rob_table(n_head).Predicted_PC) then
                        flush_pipeline <= '1';
                        v_flush := '1'; -- Log the flush internally
                        recovery_pc    <= rob_table(n_head).Actual_PC;
                        -- the control instruction itself still retires (JAL/JLR link register)
                        commit_en_1      <= '1';
                        commit_opcode_1  <= rob_table(n_head).Opcode;
                        commit_rob_tag_1 <= n_head;
                        commit_arf_1     <= rob_table(n_head).Dest_ARF;
                        commit_rrf_1     <= rob_table(n_head).Dest_RRF;
                        commit_val_1     <= rob_table(n_head).Value;
                        commit_flags_1   <= rob_table(n_head).Flags;
                        commit_mask_1    <= rob_table(n_head).Mask;
                        head <= 0; tail <= 0; count <= 0;
                        for i in 0 to ROB_DEPTH-1 loop rob_table(i).Busy <= '0'; end loop;
                        
                    else
                        -- 3. Normal Commit Logic
                        commit_en_1      <= '1';
                        commit_opcode_1  <= rob_table(n_head).Opcode;
                        commit_rob_tag_1 <= n_head;
                        commit_arf_1     <= rob_table(n_head).Dest_ARF;
                        commit_rrf_1     <= rob_table(n_head).Dest_RRF;
                        commit_val_1     <= rob_table(n_head).Value;
                        commit_flags_1   <= rob_table(n_head).Flags;
                        commit_mask_1    <= rob_table(n_head).Mask;
                        
                        rob_table(n_head).Busy <= '0';
                        n_head := (n_head + 1) mod ROB_DEPTH; n_count := n_count - 1;
                        
                        if n_count > 0 and rob_table(n_head).Busy = '1' and rob_table(n_head).Valid = '1'
                           and (store_ok or rob_table(n_head).Opcode /= OP_SW) then
                            if not (rob_table(n_head).Is_Control = '1' and rob_table(n_head).Actual_PC /= rob_table(n_head).Predicted_PC) then
                                commit_en_2      <= '1';
                                commit_opcode_2  <= rob_table(n_head).Opcode;
                                commit_rob_tag_2 <= n_head;
                                commit_arf_2     <= rob_table(n_head).Dest_ARF;
                                commit_rrf_2     <= rob_table(n_head).Dest_RRF;
                                commit_val_2     <= rob_table(n_head).Value;
                                commit_flags_2   <= rob_table(n_head).Flags;
                                commit_mask_2    <= rob_table(n_head).Mask;
                                
                                rob_table(n_head).Busy <= '0';
                                n_head := (n_head + 1) mod ROB_DEPTH; n_count := n_count - 1;
                            end if;
                        end if;
                    end if;
                end if;

                -- CDB Snooping
                if cdb1_valid = '1' then
                    cdb1_idx := cdb1_rob_tag;
                    rob_table(cdb1_idx).Valid     <= '1';
                    rob_table(cdb1_idx).Value     <= cdb1_val;
                    rob_table(cdb1_idx).Actual_PC <= cdb1_act_pc;
                    rob_table(cdb1_idx).Flags     <= cdb1_flags;
                    rob_table(cdb1_idx).Mask      <= cdb1_mask;
                end if;
                
                if cdb2_valid = '1' then
                    cdb2_idx := cdb2_rob_tag;
                    rob_table(cdb2_idx).Valid     <= '1';
                    rob_table(cdb2_idx).Value     <= cdb2_val;
                    rob_table(cdb2_idx).Actual_PC <= cdb2_act_pc;
                    rob_table(cdb2_idx).Flags     <= cdb2_flags;
                    rob_table(cdb2_idx).Mask      <= cdb2_mask;
                end if;

                -- Dispatch Allocation (ONLY if we didn't just flush!)
                if v_flush = '0' then
                    if disp_en_1 = '1' and n_count < ROB_DEPTH then
                        rob_table(n_tail).Busy <= '1'; 
                        rob_table(n_tail).Valid <= '0';
                        rob_table(n_tail).Opcode <= bundle_1.Opcode; 
                        rob_table(n_tail).Instr_PC <= bundle_1.PC; 
                        rob_table(n_tail).Dest_ARF <= bundle_1.Dest_ARF;
                        rob_table(n_tail).Dest_RRF <= dest_tag_1; 
                        rob_table(n_tail).Predicted_PC <= bundle_1.Pred_PC;
                        rob_table(n_tail).Is_Control <= bundle_1.Is_Control; 
                        rob_table(n_tail).Is_Micro_Op <= is_micro_op_1;
                        rob_table(n_tail).Flags <= "00"; 
                        rob_table(n_tail).Mask <= "00";
                        n_tail := (n_tail + 1) mod ROB_DEPTH; n_count := n_count + 1;
                        
                        if disp_en_2 = '1' and n_count < ROB_DEPTH then
                            rob_table(n_tail).Busy <= '1'; 
                            rob_table(n_tail).Valid <= '0';
                            rob_table(n_tail).Opcode <= bundle_2.Opcode; 
                            rob_table(n_tail).Instr_PC <= bundle_2.PC; 
                            rob_table(n_tail).Dest_ARF <= bundle_2.Dest_ARF;
                            rob_table(n_tail).Dest_RRF <= dest_tag_2; 
                            rob_table(n_tail).Predicted_PC <= bundle_2.Pred_PC;
                            rob_table(n_tail).Is_Control <= bundle_2.Is_Control; 
                            rob_table(n_tail).Is_Micro_Op <= is_micro_op_2;
                            rob_table(n_tail).Flags <= "00"; 
                            rob_table(n_tail).Mask <= "00";
                            n_tail := (n_tail + 1) mod ROB_DEPTH; n_count := n_count + 1;
                        end if;
                    end if;

                    -- Only update head/tail pointers if we didn't just wipe them to 0
                    head <= n_head; tail <= n_tail; count <= n_count;
                end if;
            end if;
        end if;
    end process;
end Behavioral;