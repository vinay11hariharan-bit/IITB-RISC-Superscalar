library IEEE; use IEEE.STD_LOGIC_1164.ALL; use IEEE.NUMERIC_STD.ALL;
package RISC_Types_Pkg is
    constant DATA_WIDTH : integer := 16; constant ROB_DEPTH : integer := 16;
    subtype Data_Bus is std_logic_vector(DATA_WIDTH-1 downto 0);
    subtype Reg_Tag  is std_logic_vector(3 downto 0); 
    subtype Rob_Tag  is integer range 0 to ROB_DEPTH-1;
    subtype Arf_Tag  is std_logic_vector(2 downto 0);
    type Instr_Bundle is record
        Valid, Is_Control, Is_Mem, Is_CCR_Mem, Is_Micro_Op : std_logic;
        Opcode      : std_logic_vector(3 downto 0);
        Instr_16    : std_logic_vector(15 downto 0); -- RAW instruction for exact ALU parsing
        PC          : Data_Bus;
        Dest_ARF, Src1_ARF, Src2_ARF, Src3_ARF : Arf_Tag; -- Src3 holds Old Dest
        Imm         : std_logic_vector(8 downto 0);
    end record;
end package;