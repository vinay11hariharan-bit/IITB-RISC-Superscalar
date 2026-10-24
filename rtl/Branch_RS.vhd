library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;

entity Branch_RS is
    generic ( RS_DEPTH : integer := 4 );
    Port (
        clk             : in  std_logic;
        rst             : in  std_logic;
        flush           : in  std_logic;
        rs_full         : out std_logic;   -- fewer than two free entries

        -- second dispatch port (slot 2 of the bundle)
        disp_en_b       : in  std_logic;
        bundle_b        : in  Instr_Bundle;
        disp_rob_tag_b  : in  Rob_Tag;
        dest_tag_b      : in  Reg_Tag;
        q1_b            : in  Reg_Tag; v1_val_b : in std_logic; v1_b : in Data_Bus;
        q2_b            : in  Reg_Tag; v2_val_b : in std_logic; v2_b : in Data_Bus;
        
        disp_en         : in  std_logic;
        bundle          : in  Instr_Bundle;
        disp_rob_tag    : in  Rob_Tag;     -- RENAMED to avoid type clash
        dest_tag        : in  Reg_Tag;
        
        q1              : in  Reg_Tag; v1_val : in std_logic; v1 : in Data_Bus;
        q2              : in  Reg_Tag; v2_val : in std_logic; v2 : in Data_Bus;
        q3_ccr          : in  Reg_Tag; v3_val : in std_logic; v3_ccr : in Data_Bus;
        
        cdb_valid_1     : in  std_logic; cdb_tag_1 : in Reg_Tag; cdb_val_1 : in Data_Bus;
        cdb_valid_2     : in  std_logic; cdb_tag_2 : in Reg_Tag; cdb_val_2 : in Data_Bus;
        ccr_cdb_valid   : in  std_logic; ccr_cdb_tag : in Reg_Tag; ccr_cdb_val : in Data_Bus;
        
        issue_valid     : out std_logic;
        issue_opcode    : out std_logic_vector(3 downto 0);
        issue_pc        : out Data_Bus;
        issue_v1        : out Data_Bus;
        issue_v2        : out Data_Bus;
        issue_ccr       : out Data_Bus;
        issue_imm       : out std_logic_vector(8 downto 0);
        issue_dest_tag  : out Reg_Tag;
        issue_rob_tag   : out Rob_Tag
    );
end Branch_RS;

architecture Behavioral of Branch_RS is
    type BRS_Entry is record
        Busy     : std_logic;
        Opcode   : std_logic_vector(3 downto 0);
        PC       : Data_Bus;
        Imm      : std_logic_vector(8 downto 0);
        ROB_Tag  : Rob_Tag; Dest_Tag : Reg_Tag;
        Q1       : Reg_Tag; V1_Valid : std_logic; V1 : Data_Bus;
        Q2       : Reg_Tag; V2_Valid : std_logic; V2 : Data_Bus;
        Q3       : Reg_Tag; V3_Valid : std_logic; V3 : Data_Bus;
    end record;
    
    type BRS_Array is array (0 to RS_DEPTH-1) of BRS_Entry;
    signal rs : BRS_Array;
begin
    process(rs)
        variable n : integer;
    begin
        n := 0;
        for i in 0 to RS_DEPTH-1 loop if rs(i).Busy = '0' then n := n + 1; end if; end loop;
        if n < 2 then rs_full <= '1'; else rs_full <= '0'; end if;
    end process;

    process(clk)
        variable free_slot, free_slot_b : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' or flush = '1' then
                for i in 0 to RS_DEPTH-1 loop rs(i).Busy <= '0'; end loop; 
                issue_valid <= '0';
            else
                -- 1. CDB Wakeup
                for i in 0 to RS_DEPTH-1 loop
                    if rs(i).Busy = '1' then
                        if rs(i).V1_Valid = '0' then
                            if cdb_valid_1 = '1' and rs(i).Q1 = cdb_tag_1 then rs(i).V1_Valid <= '1'; rs(i).V1 <= cdb_val_1;
                            elsif cdb_valid_2 = '1' and rs(i).Q1 = cdb_tag_2 then rs(i).V1_Valid <= '1'; rs(i).V1 <= cdb_val_2; end if;
                        end if;
                        if rs(i).V2_Valid = '0' then
                            if cdb_valid_1 = '1' and rs(i).Q2 = cdb_tag_1 then rs(i).V2_Valid <= '1'; rs(i).V2 <= cdb_val_1;
                            elsif cdb_valid_2 = '1' and rs(i).Q2 = cdb_tag_2 then rs(i).V2_Valid <= '1'; rs(i).V2 <= cdb_val_2; end if;
                        end if;
                        if rs(i).V3_Valid = '0' and ccr_cdb_valid = '1' and rs(i).Q3 = ccr_cdb_tag then
                            rs(i).V3_Valid <= '1'; rs(i).V3 <= ccr_cdb_val;
                        end if;
                    end if;
                end loop;

                -- 2. Issue Logic
                issue_valid <= '0';
                for i in 0 to RS_DEPTH-1 loop
                    if rs(i).Busy = '1' and rs(i).V1_Valid = '1' and rs(i).V2_Valid = '1' and rs(i).V3_Valid = '1' then
                        issue_valid <= '1';
                        issue_opcode <= rs(i).Opcode; issue_pc <= rs(i).PC;
                        issue_v1 <= rs(i).V1; issue_v2 <= rs(i).V2; issue_ccr <= rs(i).V3; issue_imm <= rs(i).Imm;
                        issue_dest_tag <= rs(i).Dest_Tag; issue_rob_tag <= rs(i).ROB_Tag;
                        rs(i).Busy <= '0'; exit;
                    end if;
                end loop;

                -- 3. Dispatch (up to two per cycle)
                free_slot := -1; free_slot_b := -1;
                for i in 0 to RS_DEPTH-1 loop
                    if rs(i).Busy = '0' then
                        if free_slot = -1 then free_slot := i; elsif free_slot_b = -1 then free_slot_b := i; end if;
                    end if;
                end loop;
                
                if disp_en = '1' and bundle.Is_Control = '1' and free_slot /= -1 then
                    rs(free_slot).Busy <= '1';
                    rs(free_slot).Opcode <= bundle.Opcode;
                    rs(free_slot).PC <= bundle.PC; rs(free_slot).Imm <= bundle.Imm;
                    rs(free_slot).ROB_Tag <= disp_rob_tag; rs(free_slot).Dest_Tag <= dest_tag; -- Updated assignment
                    rs(free_slot).Q1 <= q1; rs(free_slot).V1_Valid <= v1_val; rs(free_slot).V1 <= v1;
                    rs(free_slot).Q2 <= q2; rs(free_slot).V2_Valid <= v2_val; rs(free_slot).V2 <= v2;
                    rs(free_slot).Q3 <= q3_ccr; rs(free_slot).V3_Valid <= v3_val; rs(free_slot).V3 <= v3_ccr;
                end if;
                if disp_en_b = '1' and bundle_b.Is_Control = '1' and free_slot_b /= -1 then
                    rs(free_slot_b).Busy <= '1';
                    rs(free_slot_b).Opcode <= bundle_b.Opcode;
                    rs(free_slot_b).PC <= bundle_b.PC; rs(free_slot_b).Imm <= bundle_b.Imm;
                    rs(free_slot_b).ROB_Tag <= disp_rob_tag_b; rs(free_slot_b).Dest_Tag <= dest_tag_b;
                    rs(free_slot_b).Q1 <= q1_b; rs(free_slot_b).V1_Valid <= v1_val_b; rs(free_slot_b).V1 <= v1_b;
                    rs(free_slot_b).Q2 <= q2_b; rs(free_slot_b).V2_Valid <= v2_val_b; rs(free_slot_b).V2 <= v2_b;
                    rs(free_slot_b).Q3 <= q3_ccr; rs(free_slot_b).V3_Valid <= v3_val; rs(free_slot_b).V3 <= v3_ccr;
                end if;
            end if;
        end if;
    end process;
end Behavioral;