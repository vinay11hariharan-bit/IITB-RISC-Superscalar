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
        Pred_PC     : Data_Bus;  -- next PC the fetch stage actually followed (checked by the ROB)
        Dest_ARF, Src1_ARF, Src2_ARF, Src3_ARF : Arf_Tag; -- Src3 holds Old Dest
        Imm         : std_logic_vector(8 downto 0);
    end record;

    -- Data memory size: 2**DMEM_ADDR_BITS words.  DMEM decodes byte-address bits
    -- DMEM_ADDR_BITS downto 1, so the LSQ and Store Buffer must compare exactly
    -- those bits when deciding whether a load and a store touch the same word.
    constant DMEM_ADDR_BITS : integer := 10;

    constant OP_LW : std_logic_vector(3 downto 0) := "0100";
    constant OP_SW : std_logic_vector(3 downto 0) := "0101";
    constant OP_LM : std_logic_vector(3 downto 0) := "0110";
    constant OP_SM : std_logic_vector(3 downto 0) := "0111";

    -- Instructions that write the condition-code register (C, Z).
    -- ADD family, ADI, NAND family, and the flag micro-op of LMF (an LW into the CCR).
    function writes_ccr(op : std_logic_vector(3 downto 0); ccr_mem : std_logic) return boolean;
    function same_word(a, b : Data_Bus) return boolean;
end package;

package body RISC_Types_Pkg is
    function writes_ccr(op : std_logic_vector(3 downto 0); ccr_mem : std_logic) return boolean is
    begin
        return op = "0000" or op = "0001" or op = "0010" or (op = OP_LW and ccr_mem = '1');
    end function;
    function same_word(a, b : Data_Bus) return boolean is
    begin
        return a(DMEM_ADDR_BITS downto 1) = b(DMEM_ADDR_BITS downto 1);
    end function;
end package body;
