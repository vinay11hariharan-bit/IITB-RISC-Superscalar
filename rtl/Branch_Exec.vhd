library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;

entity Branch_Exec is
    Port (
        clk             : in  std_logic;
        rst             : in  std_logic;
        flush           : in  std_logic;
        
        issue_valid     : in  std_logic;
        issue_opcode    : in  std_logic_vector(3 downto 0);
        issue_pc        : in  Data_Bus;
        issue_v1        : in  Data_Bus;
        issue_v2        : in  Data_Bus;
        issue_ccr       : in  Data_Bus;
        issue_imm       : in  std_logic_vector(8 downto 0);
        issue_dest_tag  : in  Reg_Tag;
        issue_rob_tag   : in  Rob_Tag;
        
        cdb_valid       : out std_logic;
        cdb_tag         : out Reg_Tag;
        cdb_val         : out Data_Bus;       
        cdb_rob_tag     : out Rob_Tag;
        cdb_actual_pc   : out Data_Bus        
    );
end Branch_Exec;

architecture Behavioral of Branch_Exec is
begin
    process(clk)
        variable target   : unsigned(DATA_WIDTH-1 downto 0);
        variable seq_pc   : unsigned(DATA_WIDTH-1 downto 0);
        variable ext_imm  : unsigned(DATA_WIDTH-1 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' or flush = '1' then
                cdb_valid <= '0';
            else
                cdb_valid <= issue_valid;
                cdb_tag   <= issue_dest_tag;
                cdb_rob_tag <= issue_rob_tag;
                
                if issue_valid = '1' then
                    seq_pc  := unsigned(issue_pc) + 2;
                    
                    ext_imm := unsigned(resize(signed(issue_imm), DATA_WIDTH));
                    ext_imm := shift_left(ext_imm, 1); 
                    
                    target   := seq_pc; -- Default to Not Taken
                    
                    case issue_opcode is
                        when "1000" => -- BEQ (V1 == V2)
                            if issue_v1 = issue_v2 then target := unsigned(issue_pc) + ext_imm; end if;
                        when "1001" => -- BLT (V1 < V2)
                            if signed(issue_v1) < signed(issue_v2) then target := unsigned(issue_pc) + ext_imm; end if;
                        when "1010" => -- BLE (V1 <= V2)
                            if signed(issue_v1) <= signed(issue_v2) then target := unsigned(issue_pc) + ext_imm; end if;
                        when "1100" => -- JAL (Jump and Link)
                            target := unsigned(issue_pc) + ext_imm;
                        when "1101" => -- JLR (Jump and Link Register)
                            target := unsigned(issue_v1); 
                        when "1111" => -- JRI (Jump Register Immediate)
                            target := unsigned(issue_v1) + ext_imm;
                        when others =>
                            null;
                    end case;
                    
                    cdb_actual_pc <= std_logic_vector(target);
                    
                    if issue_opcode = "1100" or issue_opcode = "1101" then
                        cdb_val <= std_logic_vector(seq_pc);
                    else
                        cdb_val <= (others => '0');
                    end if;
                end if;
            end if;
        end if;
    end process;
end Behavioral;