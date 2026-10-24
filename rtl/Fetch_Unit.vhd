library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;

entity Fetch_Unit is
    Port (
        clk             : in  std_logic;
        rst             : in  std_logic;
        
        stall           : in  std_logic;
        flush_pipeline  : in  std_logic;
        recovery_pc     : in  Data_Bus;
        
        -- BP Backend Update Interface (From ROB Commit)
        bp_update_en    : in  std_logic;
        bp_update_pc    : in  Data_Bus;
        bp_update_taken : in  std_logic;
        bp_update_target: in  Data_Bus;
        
        imem_pc         : out Data_Bus;
        imem_instr_32   : in  std_logic_vector(31 downto 0); 
        imem_valid      : in  std_logic;
        
        fetch_valid_1   : out std_logic;
        fetch_pc_1      : out Data_Bus;
        fetch_instr_1   : out Data_Bus;
        
        fetch_valid_2   : out std_logic;
        fetch_pc_2      : out Data_Bus;
        fetch_instr_2   : out Data_Bus
    );
end Fetch_Unit;

architecture Behavioral of Fetch_Unit is

    component BP_Unit is
        generic ( BP_DEPTH_BITS : integer := 5 );
        Port (
            clk             : in  std_logic; 
            rst             : in  std_logic;
            fetch_pc_1      : in  Data_Bus; predict_valid_1 : out std_logic; predict_target_1: out Data_Bus;
            fetch_pc_2      : in  Data_Bus; predict_valid_2 : out std_logic; predict_target_2: out Data_Bus;
            update_en       : in  std_logic; update_pc: in Data_Bus; update_taken : in std_logic; update_target: in Data_Bus
        );
    end component;

    signal current_pc : unsigned(DATA_WIDTH-1 downto 0);
    signal pc_wire_1, pc_wire_2 : Data_Bus;
    signal pred_valid_1, pred_valid_2 : std_logic;
    signal pred_target_1, pred_target_2 : Data_Bus;

begin

    pc_wire_1 <= std_logic_vector(current_pc);
    pc_wire_2 <= std_logic_vector(current_pc + 2);

    Inst_BP_Unit: BP_Unit
        generic map ( BP_DEPTH_BITS => 5 )
        port map (
            clk => clk, rst => rst,
            fetch_pc_1 => pc_wire_1, predict_valid_1 => pred_valid_1, predict_target_1 => pred_target_1,
            fetch_pc_2 => pc_wire_2, predict_valid_2 => pred_valid_2, predict_target_2 => pred_target_2,
            update_en => bp_update_en, update_pc => bp_update_pc, 
            update_taken => bp_update_taken, update_target => bp_update_target
        );

    process(clk)
        variable next_pc : unsigned(DATA_WIDTH-1 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                current_pc <= (others => '0');
                fetch_valid_1 <= '0'; fetch_valid_2 <= '0';
            else
                -- Instruction Routing
                if stall = '0' and flush_pipeline = '0' and imem_valid = '1' then
                    fetch_valid_1 <= '1';
                    fetch_pc_1    <= pc_wire_1;
                    fetch_instr_1 <= imem_instr_32(31 downto 16);
                    
                    -- If the predictor recognized slot 1 and predicted it TAKEN, mask out slot 2
                    if pred_valid_1 = '1' then
                        fetch_valid_2 <= '0'; 
                        fetch_pc_2    <= (others => '0');
                        fetch_instr_2 <= (others => '0');
                    else
                        fetch_valid_2 <= '1';
                        fetch_pc_2    <= pc_wire_2;
                        fetch_instr_2 <= imem_instr_32(15 downto 0);
                    end if;
                else
                    fetch_valid_1 <= '0';
                    fetch_valid_2 <= '0';
                end if;

                -- Next PC Calculation
                if flush_pipeline = '1' then
                    next_pc := unsigned(recovery_pc);
                elsif stall = '0' then
                    if pred_valid_1 = '1' then
                        next_pc := unsigned(pred_target_1);
                    elsif pred_valid_2 = '1' then
                        next_pc := unsigned(pred_target_2);
                    else
                        next_pc := current_pc + 4; -- Miss in BTB means predict Not Taken (Sequential)
                    end if;
                else
                    next_pc := current_pc; 
                end if;
                
                current_pc <= next_pc;
            end if;
        end if;
    end process;
    
    imem_pc <= std_logic_vector(current_pc);

end Behavioral;