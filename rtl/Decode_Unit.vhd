library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;

entity Decode_Unit is
    Port (
        clk             : in  std_logic;
        rst             : in  std_logic;
        
        gen_valid_1     : in  std_logic;
        gen_pc_1        : in  Data_Bus;
        gen_instr_1     : in  std_logic_vector(15 downto 0);
        flag_mem_op_1   : in  std_logic;
        gen_pred_1      : in  Data_Bus;
        
        gen_valid_2     : in  std_logic;
        gen_pc_2        : in  Data_Bus;
        gen_instr_2     : in  std_logic_vector(15 downto 0);
        flag_mem_op_2   : in  std_logic;
        gen_pred_2      : in  Data_Bus;
        
        a_flag_in       : in  std_logic; 
        stall_in        : in  std_logic;
        flush_pipeline  : in  std_logic;
        stall_out       : out std_logic;
        
        decode_valid_1  : out std_logic;
        bundle_1_out    : out Instr_Bundle;
        decode_valid_2  : out std_logic;
        bundle_2_out    : out Instr_Bundle
    );
end Decode_Unit;

architecture Behavioral of Decode_Unit is

    function parse_instruction(
        valid_in  : std_logic;
        pc_in     : Data_Bus;
        pred_in   : Data_Bus;
        ins       : std_logic_vector(15 downto 0);
        is_ccr    : std_logic;
        is_micro_op : std_logic
    ) return Instr_Bundle is
        variable b : Instr_Bundle;
        variable op : std_logic_vector(3 downto 0);
    begin
        b.Valid       := valid_in;
        op            := ins(15 downto 12);
        b.Opcode      := op;
        b.Instr_16    := ins;
        b.PC          := pc_in;
        b.Pred_PC     := pred_in;
        b.Is_CCR_Mem  := is_ccr;
        b.Is_Micro_Op := is_micro_op;
        
        b.Imm         := (others => '0');
        b.Is_Mem      := '0';
        b.Is_Control  := '0';
        
        -- Default Assignments (Safe Zeroes)
        b.Dest_ARF := "000";
        b.Src1_ARF := "000";
        b.Src2_ARF := "000";
        
        -- ==================================================
        -- THE TRUE ASSEMBLER BIT-SLICING
        -- ==================================================
        case op is
            when "0000" | "0010" => -- ADD, NAND (R-Type)
                b.Dest_ARF := ins(11 downto 9);
                b.Src1_ARF := ins(8 downto 6);
                b.Src2_ARF := ins(5 downto 3);

            when "0001" => -- ADI (I-Type)
                b.Dest_ARF := ins(11 downto 9);
                b.Src1_ARF := ins(8 downto 6);
                b.Imm(5 downto 0) := ins(5 downto 0);
                if ins(5) = '1' then b.Imm(8 downto 6) := "111"; end if;

            when "0011" => -- LLI (J-Type)
                b.Dest_ARF := ins(11 downto 9);
                b.Imm := ins(8 downto 0);

            when "0100" => -- LW (I-Type)
                b.Dest_ARF := ins(11 downto 9);
                b.Src1_ARF := ins(8 downto 6); -- Base
                b.Imm(5 downto 0) := ins(5 downto 0);
                if ins(5) = '1' then b.Imm(8 downto 6) := "111"; end if;
                b.Is_Mem := '1';

            when "0101" => -- SW (I-Type)
                b.Src1_ARF := ins(8 downto 6); -- Base
                b.Src2_ARF := ins(11 downto 9); -- Data
                b.Imm(5 downto 0) := ins(5 downto 0);
                if ins(5) = '1' then b.Imm(8 downto 6) := "111"; end if;
                b.Is_Mem := '1';

            when "1000" | "1001" | "1010" => -- Branches (I-Type)
                b.Src1_ARF := ins(11 downto 9);
                b.Src2_ARF := ins(8 downto 6);
                b.Imm(5 downto 0) := ins(5 downto 0);
                if ins(5) = '1' then b.Imm(8 downto 6) := "111"; end if;
                b.Is_Control := '1';

            when "1100" => -- JAL (J-Type)
                b.Dest_ARF := ins(11 downto 9);
                b.Imm := ins(8 downto 0);
                b.Is_Control := '1';

            when "1101" => -- JLR (J-Type)
                b.Dest_ARF := ins(11 downto 9);
                b.Src1_ARF := ins(8 downto 6);
                b.Is_Control := '1';

            when "1111" => -- JRI (J-Type)
                b.Src1_ARF := ins(11 downto 9);
                b.Imm := ins(8 downto 0);
                b.Is_Control := '1';

            when others =>
                null;
        end case;

        -- Capture old destination for conditional writebacks (ADC/NDZ)
        b.Src3_ARF := b.Dest_ARF; 
        return b;
    end function;

begin
    stall_out <= stall_in;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' or flush_pipeline = '1' then
                decode_valid_1 <= '0';
                decode_valid_2 <= '0';
                bundle_1_out.Valid <= '0'; bundle_1_out.Opcode <= "0000";
                bundle_2_out.Valid <= '0'; bundle_2_out.Opcode <= "0000";
            
            elsif stall_in = '0' then
                decode_valid_1 <= gen_valid_1;
                if gen_valid_1 = '1' then
                    bundle_1_out <= parse_instruction(gen_valid_1, gen_pc_1, gen_pred_1, gen_instr_1, flag_mem_op_1, a_flag_in);
                else
                    bundle_1_out.Valid <= '0';
                end if;
                
                decode_valid_2 <= gen_valid_2;
                if gen_valid_2 = '1' then
                    bundle_2_out <= parse_instruction(gen_valid_2, gen_pc_2, gen_pred_2, gen_instr_2, flag_mem_op_2, a_flag_in);
                else
                    bundle_2_out.Valid <= '0';
                end if;
            end if;
        end if;
    end process;
end Behavioral;