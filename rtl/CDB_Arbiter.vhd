library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;

entity CDB_Arbiter is
    Port (
        branch_req      : in  std_logic;
        branch_tag      : in  Reg_Tag;
        branch_val      : in  Data_Bus;
        branch_rob      : in  Rob_Tag;
        branch_act_pc   : in  Data_Bus;
        
        lsq_req         : in  std_logic;
        lsq_tag         : in  Reg_Tag;
        lsq_val         : in  Data_Bus;
        lsq_rob         : in  Rob_Tag;
        
        alu_req         : in  std_logic;
        alu_tag         : in  Reg_Tag;
        alu_val         : in  Data_Bus;
        alu_rob         : in  Rob_Tag;
        alu_flags       : in  std_logic_vector(1 downto 0);
        alu_mask        : in  std_logic_vector(1 downto 0);
        
        branch_hold     : out std_logic;
        lsq_hold        : out std_logic;
        alu_hold        : out std_logic;
        
        cdb1_valid      : out std_logic;
        cdb1_tag        : out Reg_Tag;
        cdb1_val        : out Data_Bus;
        cdb1_rob        : out Rob_Tag;
        cdb1_act_pc     : out Data_Bus;
        cdb1_flags      : out std_logic_vector(1 downto 0);
        cdb1_mask       : out std_logic_vector(1 downto 0);
        
        cdb2_valid      : out std_logic;
        cdb2_tag        : out Reg_Tag;
        cdb2_val        : out Data_Bus;
        cdb2_rob        : out Rob_Tag;
        cdb2_act_pc     : out Data_Bus;
        cdb2_flags      : out std_logic_vector(1 downto 0);
        cdb2_mask       : out std_logic_vector(1 downto 0)
    );
end CDB_Arbiter;

architecture Combinatorial of CDB_Arbiter is
begin
    process(branch_req, branch_tag, branch_val, branch_rob, branch_act_pc,
            lsq_req, lsq_tag, lsq_val, lsq_rob,
            alu_req, alu_tag, alu_val, alu_rob, alu_flags, alu_mask)
        variable requests : std_logic_vector(2 downto 0);
    begin
        branch_hold <= '0'; lsq_hold <= '0'; alu_hold <= '0';
        cdb1_valid <= '0'; cdb1_tag <= (others => '0'); cdb1_val <= (others => '0'); cdb1_rob <= 0; cdb1_act_pc <= (others => '0'); cdb1_flags <= "00"; cdb1_mask <= "00";
        cdb2_valid <= '0'; cdb2_tag <= (others => '0'); cdb2_val <= (others => '0'); cdb2_rob <= 0; cdb2_act_pc <= (others => '0'); cdb2_flags <= "00"; cdb2_mask <= "00";

        requests := branch_req & lsq_req & alu_req;

        case requests is
            when "000" => null;
            when "001" => 
                cdb1_valid <= '1'; cdb1_tag <= alu_tag; cdb1_val <= alu_val; cdb1_rob <= alu_rob; cdb1_flags <= alu_flags; cdb1_mask <= alu_mask;
            when "010" => 
                cdb1_valid <= '1'; cdb1_tag <= lsq_tag; cdb1_val <= lsq_val; cdb1_rob <= lsq_rob;
            when "100" => 
                cdb1_valid <= '1'; cdb1_tag <= branch_tag; cdb1_val <= branch_val; cdb1_rob <= branch_rob; cdb1_act_pc <= branch_act_pc;
            when "011" => 
                cdb1_valid <= '1'; cdb1_tag <= lsq_tag; cdb1_val <= lsq_val; cdb1_rob <= lsq_rob;
                cdb2_valid <= '1'; cdb2_tag <= alu_tag; cdb2_val <= alu_val; cdb2_rob <= alu_rob; cdb2_flags <= alu_flags; cdb2_mask <= alu_mask;
            when "101" => 
                cdb1_valid <= '1'; cdb1_tag <= branch_tag; cdb1_val <= branch_val; cdb1_rob <= branch_rob; cdb1_act_pc <= branch_act_pc;
                cdb2_valid <= '1'; cdb2_tag <= alu_tag; cdb2_val <= alu_val; cdb2_rob <= alu_rob; cdb2_flags <= alu_flags; cdb2_mask <= alu_mask;
            when "110" => 
                cdb1_valid <= '1'; cdb1_tag <= branch_tag; cdb1_val <= branch_val; cdb1_rob <= branch_rob; cdb1_act_pc <= branch_act_pc;
                cdb2_valid <= '1'; cdb2_tag <= lsq_tag; cdb2_val <= lsq_val; cdb2_rob <= lsq_rob;
            when "111" => 
                cdb1_valid <= '1'; cdb1_tag <= branch_tag; cdb1_val <= branch_val; cdb1_rob <= branch_rob; cdb1_act_pc <= branch_act_pc;
                cdb2_valid <= '1'; cdb2_tag <= lsq_tag; cdb2_val <= lsq_val; cdb2_rob <= lsq_rob;
                alu_hold <= '1';
            when others => null;
        end case;
    end process;
end Combinatorial;