library IEEE; 
use IEEE.STD_LOGIC_1164.ALL; 
use IEEE.NUMERIC_STD.ALL; 
use work.RISC_Types_Pkg.ALL;

entity ALU_RS is
    generic ( RS_DEPTH : integer := 8 );
    Port ( 
        clk, rst, exec_stall, disp_en_1, disp_en_2 : in std_logic;
        flush : in std_logic;
        rs_full : out std_logic;   -- fewer than two free entries
        bundle_1, bundle_2 : in Instr_Bundle; 
        rob_tag_1, rob_tag_2 : in Rob_Tag;
        dest_tag_1, dest_tag_2 : in Reg_Tag;
        
        q1_1, q2_1, q3_1, qc_1 : in Reg_Tag; 
        v1_val_1, v2_val_1, v3_val_1, vc_val_1 : in std_logic; 
        v1_1, v2_1, v3_1, vc_1 : in Data_Bus;
        
        q1_2, q2_2, q3_2, qc_2 : in Reg_Tag; 
        v1_val_2, v2_val_2, v3_val_2, vc_val_2 : in std_logic; 
        v1_2, v2_2, v3_2, vc_2 : in Data_Bus;
        
        cdb_v1: in std_logic; cdb_t1: in Reg_Tag; cdb_val1: in Data_Bus; cdb_f1: in std_logic_vector(1 downto 0);
        cdb_v2: in std_logic; cdb_t2: in Reg_Tag; cdb_val2: in Data_Bus; cdb_f2: in std_logic_vector(1 downto 0);
        
        issue_v : out std_logic; 
        issue_op : out std_logic_vector(3 downto 0); 
        issue_16 : out std_logic_vector(15 downto 0);
        issue_v1, issue_v2, issue_v3, issue_c : out Data_Bus; 
        issue_imm : out std_logic_vector(8 downto 0);
        issue_dest : out Reg_Tag; 
        issue_rob : out Rob_Tag
    );
end ALU_RS;

architecture Behavioral of ALU_RS is
    type RS_Entry is record 
        Busy: std_logic; 
        Op: std_logic_vector(3 downto 0); 
        Ins: std_logic_vector(15 downto 0); 
        Imm: std_logic_vector(8 downto 0); -- FIXED: Added Imm back to record!
        RTag: Rob_Tag; 
        DTag: Reg_Tag;
        Q1: Reg_Tag; V1V: std_logic; V1: Data_Bus; 
        Q2: Reg_Tag; V2V: std_logic; V2: Data_Bus;
        Q3: Reg_Tag; V3V: std_logic; V3: Data_Bus; 
        QC: Reg_Tag; VCV: std_logic; VC: Data_Bus; 
    end record;
    
    type RS_Array is array(0 to RS_DEPTH-1) of RS_Entry; 
    signal rs : RS_Array;
begin
    process(rs)
        variable n : integer;
    begin
        n := 0;
        for i in 0 to RS_DEPTH-1 loop if rs(i).Busy = '0' then n := n + 1; end if; end loop;
        if n < 2 then rs_full <= '1'; else rs_full <= '0'; end if;
    end process;

    process(clk) 
        variable f1, f2 : integer; 
    begin
        if rising_edge(clk) then
            if rst='1' or flush='1' then 
                for i in 0 to RS_DEPTH-1 loop rs(i).Busy<='0'; end loop; 
                issue_v<='0'; 
            else
                -- 1. CDB Wakeup Snooping
                for i in 0 to RS_DEPTH-1 loop
                    if rs(i).Busy='1' then
                        if rs(i).V1V='0' then 
                            if cdb_v1='1' and rs(i).Q1=cdb_t1 then rs(i).V1V<='1'; rs(i).V1<=cdb_val1; 
                            elsif cdb_v2='1' and rs(i).Q1=cdb_t2 then rs(i).V1V<='1'; rs(i).V1<=cdb_val2; end if; 
                        end if;
                        if rs(i).V2V='0' then 
                            if cdb_v1='1' and rs(i).Q2=cdb_t1 then rs(i).V2V<='1'; rs(i).V2<=cdb_val1; 
                            elsif cdb_v2='1' and rs(i).Q2=cdb_t2 then rs(i).V2V<='1'; rs(i).V2<=cdb_val2; end if; 
                        end if;
                        if rs(i).V3V='0' then 
                            if cdb_v1='1' and rs(i).Q3=cdb_t1 then rs(i).V3V<='1'; rs(i).V3<=cdb_val1; 
                            elsif cdb_v2='1' and rs(i).Q3=cdb_t2 then rs(i).V3V<='1'; rs(i).V3<=cdb_val2; end if; 
                        end if;
                        if rs(i).VCV='0' then 
                            if cdb_v1='1' and rs(i).QC=cdb_t1 then rs(i).VCV<='1'; rs(i).VC(1 downto 0)<=cdb_f1; 
                            elsif cdb_v2='1' and rs(i).QC=cdb_t2 then rs(i).VCV<='1'; rs(i).VC(1 downto 0)<=cdb_f2; end if; 
                        end if;
                    end if;
                end loop;
                
                -- 2. Issue Logic
                issue_v<='0';
                if exec_stall='0' then
                    for i in 0 to RS_DEPTH-1 loop
                        if rs(i).Busy='1' and rs(i).V1V='1' and rs(i).V2V='1' and rs(i).V3V='1' and rs(i).VCV='1' then
                            issue_v<='1'; 
                            issue_op<=rs(i).Op; 
                            issue_16<=rs(i).Ins; 
                            issue_imm<=rs(i).Imm; -- FIXED: Issue the immediate to the ALU
                            issue_v1<=rs(i).V1; 
                            issue_v2<=rs(i).V2; 
                            issue_v3<=rs(i).V3; 
                            issue_c<=rs(i).VC; 
                            issue_dest<=rs(i).DTag; 
                            issue_rob<=rs(i).RTag;
                            rs(i).Busy<='0'; 
                            exit;
                        end if;
                    end loop;
                end if;
                
                -- 3. Dual Dispatch
                f1:=-1; f2:=-1; 
                for i in 0 to RS_DEPTH-1 loop 
                    if rs(i).Busy='0' then 
                        if f1=-1 then f1:=i; 
                        elsif f2=-1 then f2:=i; exit; end if; 
                    end if; 
                end loop;
                
                if disp_en_1='1' and bundle_1.Is_Control='0' and bundle_1.Is_Mem='0' and f1/=-1 then
                    rs(f1).Busy<='1'; 
                    rs(f1).Op<=bundle_1.Opcode; 
                    rs(f1).Ins<=bundle_1.Instr_16; 
                    rs(f1).Imm<=bundle_1.Imm; -- FIXED: Store Imm
                    rs(f1).RTag<=rob_tag_1; 
                    rs(f1).DTag<=dest_tag_1;
                    rs(f1).Q1<=q1_1; rs(f1).V1V<=v1_val_1; rs(f1).V1<=v1_1; 
                    rs(f1).Q2<=q2_1; rs(f1).V2V<=v2_val_1; rs(f1).V2<=v2_1;
                    rs(f1).Q3<=q3_1; rs(f1).V3V<=v3_val_1; rs(f1).V3<=v3_1; 
                    rs(f1).QC<=qc_1; rs(f1).VCV<=vc_val_1; rs(f1).VC<=vc_1;
                end if;
                
                if disp_en_2='1' and bundle_2.Is_Control='0' and bundle_2.Is_Mem='0' and f2/=-1 then
                    rs(f2).Busy<='1'; 
                    rs(f2).Op<=bundle_2.Opcode; 
                    rs(f2).Ins<=bundle_2.Instr_16; 
                    rs(f2).Imm<=bundle_2.Imm; -- FIXED: Store Imm
                    rs(f2).RTag<=rob_tag_2; 
                    rs(f2).DTag<=dest_tag_2;
                    rs(f2).Q1<=q1_2; rs(f2).V1V<=v1_val_2; rs(f2).V1<=v1_2; -- FIXED: rs(f2) instead of rs(f1)
                    rs(f2).Q2<=q2_2; rs(f2).V2V<=v2_val_2; rs(f2).V2<=v2_2;
                    rs(f2).Q3<=q3_2; rs(f2).V3V<=v3_val_2; rs(f2).V3<=v3_2; 
                    rs(f2).QC<=qc_2; rs(f2).VCV<=vc_val_2; rs(f2).VC<=vc_2;
                end if;
            end if;
        end if;
    end process;
end Behavioral;