library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;

entity ALU_Exec is
    Port (
        clk             : in  std_logic;
        rst             : in  std_logic;
        
        issue_valid     : in  std_logic;
        issue_opcode    : in  std_logic_vector(3 downto 0);
        issue_16        : in  std_logic_vector(15 downto 0);
        issue_v1        : in  Data_Bus;
        issue_v2        : in  Data_Bus;
        issue_v3        : in  Data_Bus;
        issue_c         : in  Data_Bus;
        issue_imm       : in  std_logic_vector(8 downto 0);
        issue_dest_tag  : in  Reg_Tag;
        issue_rob_tag   : in  Rob_Tag;
        
        hold            : in  std_logic;
        exec_stall      : out std_logic;
        
        alu_req         : out std_logic;
        alu_tag         : out Reg_Tag;
        alu_val         : out Data_Bus;
        alu_rob         : out Rob_Tag;
        alu_flags       : out std_logic_vector(1 downto 0);
        alu_mask        : out std_logic_vector(1 downto 0)
    );
end ALU_Exec;

architecture Behavioral of ALU_Exec is
    signal req_internal : std_logic := '0';
begin

    exec_stall <= req_internal and hold;
    alu_req    <= req_internal;

    process(clk)
        variable op1, op2: unsigned(15 downto 0);
        variable r17     : unsigned(16 downto 0);
        variable we      : std_logic;
        variable cf, zf  : std_logic;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                req_internal <= '0';
            elsif hold = '1' and req_internal = '1' then
                null; 
            else
                req_internal <= issue_valid;
                alu_tag <= issue_dest_tag;
                alu_rob <= issue_rob_tag;

                if issue_valid = '1' then
                    op1 := unsigned(issue_v1);
                    cf  := issue_c(1);
                    zf  := issue_c(0);
                    we  := '1';
                    
                    if issue_16(2) = '1' and (issue_opcode = "0000" or issue_opcode = "0010") then 
                        op2 := not unsigned(issue_v2); 
                    else 
                        op2 := unsigned(issue_v2); 
                    end if;

                    if issue_opcode = "0000" then -- ADD / ADC / ADZ / AWC
                        if issue_16(1 downto 0) = "10" and cf = '0' then we := '0'; 
                        elsif issue_16(1 downto 0) = "01" and zf = '0' then we := '0'; end if;
                        
                        if issue_16(1 downto 0) = "11" then 
                            if cf = '1' then
                                r17 := resize(op1, 17) + resize(op2, 17) + 1;
                            else
                                r17 := resize(op1, 17) + resize(op2, 17);
                            end if;
                        else 
                            r17 := resize(op1, 17) + resize(op2, 17); 
                        end if;
                        
                        if we = '1' then 
                            alu_val <= std_logic_vector(r17(15 downto 0)); 
                            if r17(15 downto 0) = x"0000" then
                                alu_flags <= r17(16) & '1';
                            else
                                alu_flags <= r17(16) & '0';
                            end if;
                            alu_mask <= "11";
                        else 
                            alu_val <= issue_v3; 
                            alu_flags <= cf & zf; 
                            alu_mask <= "00"; 
                        end if;

                    elsif issue_opcode = "0010" then -- NAND / NDC / NDZ
                        if issue_16(1 downto 0) = "10" and cf = '0' then we := '0'; 
                        elsif issue_16(1 downto 0) = "01" and zf = '0' then we := '0'; end if;
                        
                        r17 := resize(unsigned(not (std_logic_vector(op1) and std_logic_vector(op2))), 17);
                        
                        if we = '1' then 
                            alu_val <= std_logic_vector(r17(15 downto 0)); 
                            if r17(15 downto 0) = x"0000" then
                                alu_flags <= cf & '1';
                            else
                                alu_flags <= cf & '0';
                            end if;
                            alu_mask <= "01"; 
                        else 
                            alu_val <= issue_v3; 
                            alu_flags <= cf & zf; 
                            alu_mask <= "00"; 
                        end if;

                    elsif issue_opcode = "0001" then -- ADI
                        r17 := resize(op1, 17) + resize(unsigned(signed(issue_imm)), 17); 
                        alu_val <= std_logic_vector(r17(15 downto 0)); 
                        if r17(15 downto 0) = x"0000" then
                            alu_flags <= r17(16) & '1';
                        else
                            alu_flags <= r17(16) & '0';
                        end if;
                        alu_mask <= "11";

                    elsif issue_opcode = "0011" then -- LLI
                        alu_val <= std_logic_vector(resize(unsigned(issue_imm), 16)); 
                        alu_flags <= "00"; 
                        alu_mask <= "00"; 
                    end if;
                end if;
            end if;
        end if;
    end process;
end Behavioral;