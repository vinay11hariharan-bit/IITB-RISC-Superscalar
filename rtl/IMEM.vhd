library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;
use work.Mem_Init_Pkg.ALL;

entity IMEM is
    generic (
        -- Memory depth in words (e.g., 10 means 2^10 = 1024 words = 2048 bytes)
        ADDR_BITS : integer := 10;
        -- Optional program file (one hex word per line, see Mem_Init_Pkg).
        -- Empty string = use the built-in program below.
        INIT_FILE : string  := ""
    );
    Port (
        clk             : in  std_logic;
        imem_pc         : in  Data_Bus;
        
        -- Outputs to Fetch Unit
        imem_instr_32   : out std_logic_vector(31 downto 0); 
        imem_valid      : out std_logic
    );
end IMEM;

architecture Behavioral of IMEM is

    -- The memory array is strictly 16 bits (2 bytes) wide
    -- Built-in program (used when INIT_FILE is empty)
    constant DEFAULT_PROGRAM : Word_Array(0 to (2**ADDR_BITS)-1) := (
        -- Word 0: LLI R1, 32 -> Opcode:0011(3), RA:001(1), Imm:000100000(0x20)
        0  => x"3220", 
        
        -- Word 1: LMF R1, {Flag, R2, R1} -> Opcode:0110(6), RA:001(1), Imm:1_0000_0110
        -- Note: Imm bit 8 is the Flag identifier.
        1  => x"6306", 
        
        -- Word 2: ADD R4, R5, R6 -> Opcode:0001, Dest:100, Src1:101, Src2:110
        2  => x"1970", 
        
        others => x"0000"
    );
    signal ram : Word_Array(0 to (2**ADDR_BITS)-1) := load_hex(INIT_FILE, 2**ADDR_BITS, DEFAULT_PROGRAM);

    signal word_addr_A : unsigned(ADDR_BITS-1 downto 0);
    signal word_addr_B : unsigned(ADDR_BITS-1 downto 0);
    
    signal instr_1 : std_logic_vector(15 downto 0);
    signal instr_2 : std_logic_vector(15 downto 0);

begin

    -- Convert the byte-addressable PC into a 16-bit word index by stripping bit(0)
    word_addr_A <= unsigned(imem_pc(ADDR_BITS downto 1));
    
    -- Port B reads the very next 16-bit word (PC + 2 bytes)
    word_addr_B <= unsigned(imem_pc(ADDR_BITS downto 1)) + 1;

	 -- FIXED (asynchronous/combinatorial read — zero latency)
	 imem_instr_32 <= ram(to_integer(word_addr_A)) & ram(to_integer(word_addr_B));
	 imem_valid <= '1'; 

end Behavioral;