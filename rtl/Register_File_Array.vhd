library IEEE; 
use IEEE.STD_LOGIC_1164.ALL; 
use IEEE.NUMERIC_STD.ALL; 
use work.RISC_Types_Pkg.ALL;

entity Register_File_Array is
    Port ( 
        clk, rst : in std_logic;
        
        -- Slot 1 Read/Alloc Ports
        pc_1 : in Data_Bus;
        src1_arf_1 : in Arf_Tag; src1_rrf_1 : in Reg_Tag; src1_busy_1 : in std_logic;
        src2_arf_1 : in Arf_Tag; src2_rrf_1 : in Reg_Tag; src2_busy_1 : in std_logic;
        src3_arf_1 : in Arf_Tag; src3_rrf_1 : in Reg_Tag; src3_busy_1 : in std_logic;
        dest_rrf_1 : in Reg_Tag; alloc_en_1 : in std_logic;
        
        -- Slot 2 Read/Alloc Ports
        pc_2 : in Data_Bus;
        src1_arf_2 : in Arf_Tag; src1_rrf_2 : in Reg_Tag; src1_busy_2 : in std_logic;
        src2_arf_2 : in Arf_Tag; src2_rrf_2 : in Reg_Tag; src2_busy_2 : in std_logic;
        src3_arf_2 : in Arf_Tag; src3_rrf_2 : in Reg_Tag; src3_busy_2 : in std_logic;
        dest_rrf_2 : in Reg_Tag; alloc_en_2 : in std_logic;
        
        -- CDB Snooping Ports (Writeback)
        cdb_valid_1 : in std_logic; cdb_tag_1 : in Reg_Tag; cdb_val_1 : in Data_Bus;
        cdb_valid_2 : in std_logic; cdb_tag_2 : in Reg_Tag; cdb_val_2 : in Data_Bus;
        
        -- ROB Commit Ports (Retirement)
        commit_en_1 : in std_logic; commit_arf_1 : in Arf_Tag; commit_val_1 : in Data_Bus;
        commit_en_2 : in std_logic; commit_arf_2 : in Arf_Tag; commit_val_2 : in Data_Bus;
        
        -- Output Data Buses
        v1_val_1 : out std_logic; v1_1 : out Data_Bus; 
        v2_val_1 : out std_logic; v2_1 : out Data_Bus; 
        v3_val_1 : out std_logic; v3_1 : out Data_Bus;
        
        v1_val_2 : out std_logic; v1_2 : out Data_Bus; 
        v2_val_2 : out std_logic; v2_2 : out Data_Bus; 
        v3_val_2 : out std_logic; v3_2 : out Data_Bus
    );
end Register_File_Array;

architecture Behavioral of Register_File_Array is
    type ARF_Array is array (0 to 7) of Data_Bus; 
    signal arf_data : ARF_Array;
    
    type RRF_Data_Array is array (0 to 15) of Data_Bus; 
    signal rrf_data : RRF_Data_Array;
    signal rrf_valid : std_logic_vector(15 downto 0);
    
    -- Helper procedure to route standard operand reads
    procedure read_operand(
        arf_tag: in Arf_Tag; rrf_tag: in Reg_Tag; rat_busy: in std_logic; instr_pc: in Data_Bus;
        arf_mem: in ARF_Array; rrf_mem: in RRF_Data_Array; rrf_v_flag: in std_logic_vector(15 downto 0);
        v_val_out: out std_logic; v_out: out Data_Bus
    ) is
    begin
        if arf_tag="000" then 
            v_val_out:='1'; v_out:=instr_pc;
        elsif rat_busy='0' then 
            v_val_out:='1'; v_out:=arf_mem(to_integer(unsigned(arf_tag)));
        else
            if rrf_v_flag(to_integer(unsigned(rrf_tag)))='1' then 
                v_val_out:='1'; v_out:=rrf_mem(to_integer(unsigned(rrf_tag)));
            else 
                v_val_out:='0'; v_out:=(others=>'0'); 
            end if;
        end if;
    end procedure;
    
begin
    -- Combinatorial Reads
    process(pc_1, src1_arf_1, src1_rrf_1, src1_busy_1, src2_arf_1, src2_rrf_1, src2_busy_1, src3_arf_1, src3_rrf_1, src3_busy_1,
            pc_2, src1_arf_2, src1_rrf_2, src1_busy_2, src2_arf_2, src2_rrf_2, src2_busy_2, src3_arf_2, src3_rrf_2, src3_busy_2, 
            arf_data, rrf_data, rrf_valid)
        variable val1_1, val2_1, val3_1, val1_2, val2_2, val3_2 : std_logic; 
        variable v1_1_var, v2_1_var, v3_1_var, v1_2_var, v2_2_var, v3_2_var : Data_Bus;
    begin
        read_operand(src1_arf_1, src1_rrf_1, src1_busy_1, pc_1, arf_data, rrf_data, rrf_valid, val1_1, v1_1_var);
        read_operand(src2_arf_1, src2_rrf_1, src2_busy_1, pc_1, arf_data, rrf_data, rrf_valid, val2_1, v2_1_var);
        read_operand(src3_arf_1, src3_rrf_1, src3_busy_1, pc_1, arf_data, rrf_data, rrf_valid, val3_1, v3_1_var);
        read_operand(src1_arf_2, src1_rrf_2, src1_busy_2, pc_2, arf_data, rrf_data, rrf_valid, val1_2, v1_2_var);
        read_operand(src2_arf_2, src2_rrf_2, src2_busy_2, pc_2, arf_data, rrf_data, rrf_valid, val2_2, v2_2_var);
        read_operand(src3_arf_2, src3_rrf_2, src3_busy_2, pc_2, arf_data, rrf_data, rrf_valid, val3_2, v3_2_var);
        
        v1_val_1<=val1_1; v1_1<=v1_1_var; v2_val_1<=val2_1; v2_1<=v2_1_var; v3_val_1<=val3_1; v3_1<=v3_1_var;
        v1_val_2<=val1_2; v1_2<=v1_2_var; v2_val_2<=val2_2; v2_2<=v2_2_var; v3_val_2<=val3_2; v3_2<=v3_2_var;
    end process;

    -- Synchronous Updates
    process(clk) 
    begin
        if rising_edge(clk) then
            if rst='1' then
                for i in 0 to 7 loop arf_data(i)<=(others=>'0'); end loop;
                for i in 0 to 15 loop rrf_data(i)<=(others=>'0'); rrf_valid(i)<='0'; end loop;
            else
                -- 1. Allocate New Destinations (invalidate them until CDB writes back)
                if alloc_en_1='1' then rrf_valid(to_integer(unsigned(dest_rrf_1)))<='0'; end if;
                if alloc_en_2='1' then rrf_valid(to_integer(unsigned(dest_rrf_2)))<='0'; end if;
                
                -- 2. CDB Snooping (Execution finished)
                if cdb_valid_1='1' then 
                    rrf_valid(to_integer(unsigned(cdb_tag_1)))<='1'; 
                    rrf_data(to_integer(unsigned(cdb_tag_1)))<=cdb_val_1; 
                end if;
                if cdb_valid_2='1' then 
                    rrf_valid(to_integer(unsigned(cdb_tag_2)))<='1'; 
                    rrf_data(to_integer(unsigned(cdb_tag_2)))<=cdb_val_2; 
                end if;
                
                -- 3. ROB Commit (Make changes permanent)
                if commit_en_1='1' and commit_arf_1/="000" then 
                    arf_data(to_integer(unsigned(commit_arf_1)))<=commit_val_1; 
                end if;
                if commit_en_2='1' and commit_arf_2/="000" then 
                    arf_data(to_integer(unsigned(commit_arf_2)))<=commit_val_2; 
                end if;
            end if;
        end if;
    end process;
end Behavioral;