library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;

entity MF_Sequencer is
    Port (
        clk            : in  std_logic;
        rst            : in  std_logic;
        
        -- Dual Inputs from Fetch Unit
        fetch_valid_1  : in  std_logic;
        fetch_pc_1     : in  Data_Bus;
        instr_pr1_1    : in  std_logic_vector(15 downto 0);
        
        fetch_valid_2  : in  std_logic;
        fetch_pc_2     : in  Data_Bus;
        instr_pr1_2    : in  std_logic_vector(15 downto 0);
        
        -- Dual Outputs to Decode/Dispatch
        gen_valid_1    : out std_logic;
        gen_pc_1       : out Data_Bus;
        gen_instr_1    : out std_logic_vector(15 downto 0);
        
        gen_valid_2    : out std_logic;
        gen_pc_2       : out Data_Bus;
        gen_instr_2    : out std_logic_vector(15 downto 0);
        
        -- Control Flags
        freeze_fetch   : out std_logic;
        a              : out std_logic;       -- 1 = generate1d micro-op cycle
        flag_mem_op_1  : out std_logic;       -- 1 = Port 1 targets the Flag Reg (CCR)
        flag_mem_op_2  : out std_logic        -- 1 = Port 2 targets the Flag Reg (CCR)
    );
end MF_Sequencer;

architecture Strict_Sync of MF_Sequencer is

    type state_type is (idle1, generate1);
    signal state : state_type;

    -- Latches to remember the original instruction context
    signal latched_mask   : std_logic_vector(7 downto 0);
    signal latched_base   : std_logic_vector(2 downto 0);
    signal latched_is_sw  : std_logic;
    signal latched_pc     : Data_Bus;
    signal current_offset : unsigned(5 downto 0);

    alias op1_in   : std_logic_vector(3 downto 0) is instr_pr1_1(15 downto 12);
    alias flag1_in : std_logic is instr_pr1_1(8);
    alias mask1_in : std_logic_vector(7 downto 0) is instr_pr1_1(7 downto 0);
    alias base1_in : std_logic_vector(2 downto 0) is instr_pr1_1(11 downto 9);

    alias op2_in   : std_logic_vector(3 downto 0) is instr_pr1_2(15 downto 12);
    alias flag2_in : std_logic is instr_pr1_2(8);
    alias mask2_in : std_logic_vector(7 downto 0) is instr_pr1_2(7 downto 0);
    alias base2_in : std_logic_vector(2 downto 0) is instr_pr1_2(11 downto 9);

begin
	--Combinational Circuit 
    process(state, fetch_valid_1, fetch_pc_1, instr_pr1_1, op1_in, flag1_in, mask1_in, base1_in, 
            fetch_valid_2, fetch_pc_2, instr_pr1_2, op2_in, flag2_in, mask2_in, base2_in, 
            latched_mask, latched_base, latched_is_sw, latched_pc, current_offset)
        
        variable eval_mask  : std_logic_vector(7 downto 0);
        variable out_opcode : std_logic_vector(3 downto 0);
        variable out_base   : std_logic_vector(2 downto 0);
        variable target_1, target_2 : std_logic_vector(2 downto 0);
        variable bit1_found, bit2_found : boolean;
        variable off_1, off_2 : unsigned(5 downto 0);
    begin
        -- Default: Pass-through mode
        freeze_fetch  <= '0';
        a             <= '0';
        flag_mem_op_1 <= '0';
        flag_mem_op_2 <= '0';
        
        gen_valid_1 <= fetch_valid_1;
        gen_pc_1    <= fetch_pc_1;
        gen_instr_1 <= instr_pr1_1;
        
        gen_valid_2 <= fetch_valid_2;
        gen_pc_2    <= fetch_pc_2;
        gen_instr_2 <= instr_pr1_2;
        
        target_1 := "000"; target_2 := "000";
        bit1_found := false; bit2_found := false;

        if state = idle1 then
            -- Instruction 1 is MF (Instruction 2 is paused)
            if fetch_valid_1 = '1' and (op1_in = "0110" or op1_in = "0111") then
                freeze_fetch <= '1';
                a            <= '0'; -- First cycle of MF is still technically Cycle 1
                gen_valid_2  <= '0'; -- Suppress original slot 2
                out_base := base1_in;
                if op1_in = "0110" then out_opcode := "0100"; else out_opcode := "0101"; end if;
                
                if flag1_in = '1' then
                    gen_valid_1   <= '1';
                    gen_pc_1      <= fetch_pc_1;
                    flag_mem_op_1 <= '1'; -- Port 1 handles Flag
                    gen_instr_1   <= out_opcode & "000" & out_base & "000000";
                    
                    eval_mask := mask1_in;
                    off_2 := to_unsigned(2, 6);
                    if    eval_mask(0) = '1' then target_2 := "111"; bit2_found := true;
                    elsif eval_mask(1) = '1' then target_2 := "110"; bit2_found := true;
                    elsif eval_mask(2) = '1' then target_2 := "101"; bit2_found := true;
                    elsif eval_mask(3) = '1' then target_2 := "100"; bit2_found := true;
                    elsif eval_mask(4) = '1' then target_2 := "011"; bit2_found := true;
                    elsif eval_mask(5) = '1' then target_2 := "010"; bit2_found := true;
                    elsif eval_mask(6) = '1' then target_2 := "001"; bit2_found := true;
                    elsif eval_mask(7) = '1' then target_2 := "000"; bit2_found := true;
                    end if;
                    
                    if bit2_found then
                        gen_valid_2   <= '1';
                        gen_pc_2      <= fetch_pc_1; 
                        flag_mem_op_2 <= '0'; -- Port 2 is a normal GPR
                        gen_instr_2   <= out_opcode & target_2 & out_base & std_logic_vector(off_2);
                    end if;
                else
                    eval_mask := mask1_in;
                    if    eval_mask(0) = '1' then target_1 := "111"; eval_mask(0) := '0'; bit1_found := true;
                    elsif eval_mask(1) = '1' then target_1 := "110"; eval_mask(1) := '0'; bit1_found := true;
                    elsif eval_mask(2) = '1' then target_1 := "101"; eval_mask(2) := '0'; bit1_found := true;
                    elsif eval_mask(3) = '1' then target_1 := "100"; eval_mask(3) := '0'; bit1_found := true;
                    elsif eval_mask(4) = '1' then target_1 := "011"; eval_mask(4) := '0'; bit1_found := true;
                    elsif eval_mask(5) = '1' then target_1 := "010"; eval_mask(5) := '0'; bit1_found := true;
                    elsif eval_mask(6) = '1' then target_1 := "001"; eval_mask(6) := '0'; bit1_found := true;
                    elsif eval_mask(7) = '1' then target_1 := "000"; eval_mask(7) := '0'; bit1_found := true;
                    end if;
                    
                    if bit1_found then
                        gen_valid_1   <= '1';
                        gen_pc_1      <= fetch_pc_1;
                        flag_mem_op_1 <= '0';
                        gen_instr_1   <= out_opcode & target_1 & out_base & "000000";
                        
                        if    eval_mask(0) = '1' then target_2 := "111"; bit2_found := true;
                        elsif eval_mask(1) = '1' then target_2 := "110"; bit2_found := true;
                        elsif eval_mask(2) = '1' then target_2 := "101"; bit2_found := true;
                        elsif eval_mask(3) = '1' then target_2 := "100"; bit2_found := true;
                        elsif eval_mask(4) = '1' then target_2 := "011"; bit2_found := true;
                        elsif eval_mask(5) = '1' then target_2 := "010"; bit2_found := true;
                        elsif eval_mask(6) = '1' then target_2 := "001"; bit2_found := true;
                        elsif eval_mask(7) = '1' then target_2 := "000"; bit2_found := true;
                        end if;

                        if bit2_found then
                            gen_valid_2   <= '1';
                            gen_pc_2      <= fetch_pc_1;
                            flag_mem_op_2 <= '0';
                            gen_instr_2   <= out_opcode & target_2 & out_base & "000010";
                        end if;
                    end if;
                end if;

            -- Instruction 1 is Normal, Instruction 2 is MF
            elsif fetch_valid_2 = '1' and (op2_in = "0110" or op2_in = "0111") then
                freeze_fetch <= '1';
                a            <= '0';
                out_base := base2_in;
                if op2_in = "0110" then out_opcode := "0100"; else out_opcode := "0101"; end if;
                
                if flag2_in = '1' then
                    gen_valid_2   <= '1';
                    gen_pc_2      <= fetch_pc_2;
                    flag_mem_op_2 <= '1'; -- Port 2 handles Flag
                    gen_instr_2   <= out_opcode & "000" & out_base & "000000";
                else
                    eval_mask := mask2_in;
                    if    eval_mask(0) = '1' then target_2 := "111"; bit2_found := true;
                    elsif eval_mask(1) = '1' then target_2 := "110"; bit2_found := true;
                    elsif eval_mask(2) = '1' then target_2 := "101"; bit2_found := true;
                    elsif eval_mask(3) = '1' then target_2 := "100"; bit2_found := true;
                    elsif eval_mask(4) = '1' then target_2 := "011"; bit2_found := true;
                    elsif eval_mask(5) = '1' then target_2 := "010"; bit2_found := true;
                    elsif eval_mask(6) = '1' then target_2 := "001"; bit2_found := true;
                    elsif eval_mask(7) = '1' then target_2 := "000"; bit2_found := true;
                    end if;

                    if bit2_found then
                        gen_valid_2   <= '1';
                        gen_pc_2      <= fetch_pc_2;
                        flag_mem_op_2 <= '0';
                        gen_instr_2   <= out_opcode & target_2 & out_base & "000000";
                    else
                        gen_valid_2 <= '0';
                    end if;
                end if;
            end if;

        elsif state = generate1 then
            -- CYCLE 2+: Generating from latched data
            freeze_fetch  <= '1';
            a             <= '1'; -- We are officially generating!
            flag_mem_op_1 <= '0'; -- Flags are always handled in cycle 1
            flag_mem_op_2 <= '0'; 
            
            out_base := latched_base;
            off_1 := current_offset;
            if latched_is_sw = '0' then out_opcode := "0100"; else out_opcode := "0101"; end if;

            eval_mask := latched_mask;
            
            if    eval_mask(0) = '1' then target_1 := "111"; eval_mask(0) := '0'; bit1_found := true;
            elsif eval_mask(1) = '1' then target_1 := "110"; eval_mask(1) := '0'; bit1_found := true;
            elsif eval_mask(2) = '1' then target_1 := "101"; eval_mask(2) := '0'; bit1_found := true;
            elsif eval_mask(3) = '1' then target_1 := "100"; eval_mask(3) := '0'; bit1_found := true;
            elsif eval_mask(4) = '1' then target_1 := "011"; eval_mask(4) := '0'; bit1_found := true;
            elsif eval_mask(5) = '1' then target_1 := "010"; eval_mask(5) := '0'; bit1_found := true;
            elsif eval_mask(6) = '1' then target_1 := "001"; eval_mask(6) := '0'; bit1_found := true;
            elsif eval_mask(7) = '1' then target_1 := "000"; eval_mask(7) := '0'; bit1_found := true;
            end if;

            if bit1_found then
                gen_valid_1 <= '1';
                gen_pc_1    <= latched_pc;
                gen_instr_1 <= out_opcode & target_1 & out_base & std_logic_vector(off_1);
                
                off_2 := off_1 + 2;
                if    eval_mask(0) = '1' then target_2 := "111"; bit2_found := true;
                elsif eval_mask(1) = '1' then target_2 := "110"; bit2_found := true;
                elsif eval_mask(2) = '1' then target_2 := "101"; bit2_found := true;
                elsif eval_mask(3) = '1' then target_2 := "100"; bit2_found := true;
                elsif eval_mask(4) = '1' then target_2 := "011"; bit2_found := true;
                elsif eval_mask(5) = '1' then target_2 := "010"; bit2_found := true;
                elsif eval_mask(6) = '1' then target_2 := "001"; bit2_found := true;
                elsif eval_mask(7) = '1' then target_2 := "000"; bit2_found := true;
                end if;
                
                if bit2_found then
                    gen_valid_2 <= '1';
                    gen_pc_2    <= latched_pc;
                    gen_instr_2 <= out_opcode & target_2 & out_base & std_logic_vector(off_2);
                else
                    gen_valid_2 <= '0';
                end if;
            else
                freeze_fetch <= '0';
                gen_valid_1 <= '0';
                gen_valid_2 <= '0';
            end if;
        end if;
    end process;

    --Sequential Circuit 
    process(clk, rst)
        variable next_mask : std_logic_vector(7 downto 0);
    begin
        if rst = '1' then
            state <= idle1;
            latched_mask <= (others => '0');
            latched_base <= (others => '0');
            latched_is_sw <= '0';
            latched_pc <= (others => '0');
            current_offset <= (others => '0');
            
        elsif rising_edge(clk) then
            case state is
                when idle1 =>
                    if fetch_valid_1 = '1' and (op1_in = "0110" or op1_in = "0111") then
                        latched_base <= base1_in;
                        latched_pc   <= fetch_pc_1;
                        if op1_in = "0111" then latched_is_sw <= '1'; else latched_is_sw <= '0'; end if;
                        
                        next_mask := mask1_in;
                        if flag1_in = '1' then
                            -- One bit processed (the flag), clear one mask bit if it exists
                            if    next_mask(0) = '1' then next_mask(0) := '0';
                            elsif next_mask(1) = '1' then next_mask(1) := '0';
                            elsif next_mask(2) = '1' then next_mask(2) := '0';
                            elsif next_mask(3) = '1' then next_mask(3) := '0';
                            elsif next_mask(4) = '1' then next_mask(4) := '0';
                            elsif next_mask(5) = '1' then next_mask(5) := '0';
                            elsif next_mask(6) = '1' then next_mask(6) := '0';
                            elsif next_mask(7) = '1' then next_mask(7) := '0';
                            end if;
                            current_offset <= to_unsigned(4, 6);
                        else
                            -- Clear up to two bits
                            if    next_mask(0) = '1' then next_mask(0) := '0';
                            elsif next_mask(1) = '1' then next_mask(1) := '0';
                            elsif next_mask(2) = '1' then next_mask(2) := '0';
                            elsif next_mask(3) = '1' then next_mask(3) := '0';
                            elsif next_mask(4) = '1' then next_mask(4) := '0';
                            elsif next_mask(5) = '1' then next_mask(5) := '0';
                            elsif next_mask(6) = '1' then next_mask(6) := '0';
                            elsif next_mask(7) = '1' then next_mask(7) := '0';
                            end if;
                            
                            if    next_mask(0) = '1' then next_mask(0) := '0';
                            elsif next_mask(1) = '1' then next_mask(1) := '0';
                            elsif next_mask(2) = '1' then next_mask(2) := '0';
                            elsif next_mask(3) = '1' then next_mask(3) := '0';
                            elsif next_mask(4) = '1' then next_mask(4) := '0';
                            elsif next_mask(5) = '1' then next_mask(5) := '0';
                            elsif next_mask(6) = '1' then next_mask(6) := '0';
                            elsif next_mask(7) = '1' then next_mask(7) := '0';
                            end if;
                            current_offset <= to_unsigned(4, 6);
                        end if;
                        
                        latched_mask <= next_mask;
                        if next_mask /= "00000000" then state <= generate1; end if;

                    elsif fetch_valid_2 = '1' and (op2_in = "0110" or op2_in = "0111") then
                        latched_base <= base2_in;
                        latched_pc   <= fetch_pc_2;
                        if op2_in = "0111" then latched_is_sw <= '1'; else latched_is_sw <= '0'; end if;
                        
                        next_mask := mask2_in;
                        if flag2_in = '1' then
                            current_offset <= to_unsigned(2, 6);
                        else
                            if    next_mask(0) = '1' then next_mask(0) := '0';
                            elsif next_mask(1) = '1' then next_mask(1) := '0';
                            elsif next_mask(2) = '1' then next_mask(2) := '0';
                            elsif next_mask(3) = '1' then next_mask(3) := '0';
                            elsif next_mask(4) = '1' then next_mask(4) := '0';
                            elsif next_mask(5) = '1' then next_mask(5) := '0';
                            elsif next_mask(6) = '1' then next_mask(6) := '0';
                            elsif next_mask(7) = '1' then next_mask(7) := '0';
                            end if;
                            current_offset <= to_unsigned(2, 6);
                        end if;
                        
                        latched_mask <= next_mask;
                        if next_mask /= "00000000" then state <= generate1; end if;
                    end if;

                when generate1 =>
                    next_mask := latched_mask;
                    -- Clear up to two bits
                    if    next_mask(0) = '1' then next_mask(0) := '0';
                    elsif next_mask(1) = '1' then next_mask(1) := '0';
                    elsif next_mask(2) = '1' then next_mask(2) := '0';
                    elsif next_mask(3) = '1' then next_mask(3) := '0';
                    elsif next_mask(4) = '1' then next_mask(4) := '0';
                    elsif next_mask(5) = '1' then next_mask(5) := '0';
                    elsif next_mask(6) = '1' then next_mask(6) := '0';
                    elsif next_mask(7) = '1' then next_mask(7) := '0';
                    end if;
                    
                    if    next_mask(0) = '1' then next_mask(0) := '0'; current_offset <= current_offset + 4;
                    elsif next_mask(1) = '1' then next_mask(1) := '0'; current_offset <= current_offset + 4;
                    elsif next_mask(2) = '1' then next_mask(2) := '0'; current_offset <= current_offset + 4;
                    elsif next_mask(3) = '1' then next_mask(3) := '0'; current_offset <= current_offset + 4;
                    elsif next_mask(4) = '1' then next_mask(4) := '0'; current_offset <= current_offset + 4;
                    elsif next_mask(5) = '1' then next_mask(5) := '0'; current_offset <= current_offset + 4;
                    elsif next_mask(6) = '1' then next_mask(6) := '0'; current_offset <= current_offset + 4;
                    elsif next_mask(7) = '1' then next_mask(7) := '0'; current_offset <= current_offset + 4;
                    else  
                        current_offset <= current_offset + 2;
                    end if;

                    latched_mask <= next_mask;
                    if next_mask = "00000000" then state <= idle1; end if;
            end case;
        end if;
    end process;
end Strict_Sync;