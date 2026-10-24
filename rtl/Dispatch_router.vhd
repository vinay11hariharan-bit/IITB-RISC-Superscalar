library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;

entity Dispatch_Router is
    Port (
        -- Inputs from RR_Unit (Fully renamed, ready to be dispatched)
        rr_en_1          : in  std_logic;
        rr_bundle_1      : in  Instr_Bundle;
        rr_dest_tag_1    : in  Reg_Tag;
        rr_q1_1          : in  Reg_Tag;
        rr_q2_1          : in  Reg_Tag;
        
        rr_en_2          : in  std_logic;
        rr_bundle_2      : in  Instr_Bundle;
        rr_dest_tag_2    : in  Reg_Tag;
        rr_q1_2          : in  Reg_Tag;
        rr_q2_2          : in  Reg_Tag;
        
        -- Specialized CCR Flag Tags (If coming from RR unit, or bypassed)
        rr_q3_ccr_1      : in  Reg_Tag;
        rr_q3_ccr_2      : in  Reg_Tag;
        
        -- Backpressure Inputs (From backend data structures)
        rob_full         : in  std_logic;
        alu_rs_full      : in  std_logic;
        branch_rs_full   : in  std_logic;
        lsq_full         : in  std_logic;
        
        -- Output to Front-End (Stalls RR_Unit and Decode)
        scheduler_stall  : out std_logic;
        
        -- Outputs to ALU Reservation Station
        alu_en_1         : out std_logic;
        alu_en_2         : out std_logic;
        
        -- Outputs to Branch Reservation Station
        branch_en_1      : out std_logic;
        branch_en_2      : out std_logic;
        
        -- Outputs to Load/Store Queue (LSQ)
        lsq_en_1         : out std_logic;
        lsq_en_2         : out std_logic
        
        -- Note: The actual data buses (bundle, tags, values) are wired 
        -- directly in parallel to ALL Reservation stations at the top level.
        -- The RS units use these enable signals to know if the data on the bus belongs to them.
    );
end Dispatch_Router;

architecture Combinatorial of Dispatch_Router is

    signal stall_internal : std_logic;

begin

    -- 1. Centralized Backpressure Logic
    -- If any execution queue or the ROB is full, we must stall the Front-End 
    -- to prevent dropping instructions.
    stall_internal <= rob_full or alu_rs_full or branch_rs_full or lsq_full;
    scheduler_stall <= stall_internal;

    -- 2. Routing Logic (Demultiplexing based on Instruction Type)
    process(stall_internal, rr_en_1, rr_bundle_1, rr_en_2, rr_bundle_2)
    begin
        -- Default to off
        alu_en_1    <= '0'; alu_en_2    <= '0';
        branch_en_1 <= '0'; branch_en_2 <= '0';
        lsq_en_1    <= '0'; lsq_en_2    <= '0';

        -- Only route if the backend has space
        if stall_internal = '0' then
            
            -- Route Slot 1
            if rr_en_1 = '1' then
                if rr_bundle_1.Is_Mem = '1' then
                    lsq_en_1 <= '1';
                elsif rr_bundle_1.Is_Control = '1' then
                    branch_en_1 <= '1';
                else
                    alu_en_1 <= '1';
                end if;
            end if;

            -- Route Slot 2
            if rr_en_2 = '1' then
                if rr_bundle_2.Is_Mem = '1' then
                    lsq_en_2 <= '1';
                elsif rr_bundle_2.Is_Control = '1' then
                    branch_en_2 <= '1';
                else
                    alu_en_2 <= '1';
                end if;
            end if;
            
        end if;
    end process;

end Combinatorial;