-- =====================================================================
-- MF Sequencer: expands LM / SM / LMF / SMF into LW / SW micro-ops
--
-- Instruction:  op(15:12) RA(11:9) F(8) MASK(7:0)      op = 0110 LM, 0111 SM
--   RA     base address register
--   F = 1  LMF / SMF: the condition-code register is transferred first,
--          at M[RA] (flag micro-op, Is_CCR_Mem = 1)
--   MASK   bit k selects register R(7-k); bits are processed from bit 0 up,
--          each at the next word: offset = 2*F + 2*(number of selected bits
--          below k)
--
-- Up to two micro-ops are emitted per cycle.  The fetch unit is frozen
-- while a sequence is in progress.
--
-- Fixes over the original version:
--   * LM/SM in slot 1: the instruction in slot 2 used to be dropped.  The
--     fetch unit is now redirected to PC+2 so it is fetched again.
--   * flush_pipeline returns the unit to IDLE (wrong-path LM/SM squashed).
--   * hold (decode stall) freezes the sequencer instead of losing micro-ops.
--   * LM that loads its own base register: that load is moved to the end of
--     the sequence, so every micro-op uses the original base value.
-- =====================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;

entity MF_Sequencer is
    Port (
        clk, rst       : in  std_logic;
        flush_pipeline : in  std_logic;
        hold           : in  std_logic;   -- decode stage is stalled

        -- Dual Inputs from Fetch Unit
        fetch_valid_1  : in  std_logic;
        fetch_pc_1     : in  Data_Bus;
        instr_pr1_1    : in  std_logic_vector(15 downto 0);
        fetch_pred_1   : in  Data_Bus;
        fetch_valid_2  : in  std_logic;
        fetch_pc_2     : in  Data_Bus;
        instr_pr1_2    : in  std_logic_vector(15 downto 0);
        fetch_pred_2   : in  Data_Bus;

        -- Dual Outputs to Decode
        gen_valid_1    : out std_logic;
        gen_pc_1       : out Data_Bus;
        gen_instr_1    : out std_logic_vector(15 downto 0);
        gen_pred_1     : out Data_Bus;
        gen_valid_2    : out std_logic;
        gen_pc_2       : out Data_Bus;
        gen_instr_2    : out std_logic_vector(15 downto 0);
        gen_pred_2     : out Data_Bus;

        -- Control Flags
        freeze_fetch   : out std_logic;   -- more micro-ops follow: fetch must not advance
        redirect_en    : out std_logic;   -- refetch from redirect_pc (instruction after an LM/SM in slot 1)
        redirect_pc    : out Data_Bus;
        a              : out std_logic;   -- 1 = emitting micro-ops from the latched instruction
        flag_mem_op_1  : out std_logic;   -- 1 = slot 1 micro-op transfers the CCR
        flag_mem_op_2  : out std_logic    -- 1 = slot 2 micro-op transfers the CCR
    );
end MF_Sequencer;

architecture Strict_Sync of MF_Sequencer is

    type state_type is (idle1, generate1);
    signal state : state_type := idle1;

    -- Latched sequence context
    signal l_is_sw, l_flag, l_flag_pend, l_defer : std_logic;
    signal l_base   : std_logic_vector(2 downto 0);
    signal l_orig, l_rem : std_logic_vector(7 downto 0);
    signal l_pc     : Data_Bus;

    -- Next-state values computed combinationally
    signal n_state  : state_type;
    signal n_is_sw, n_flag, n_flag_pend, n_defer : std_logic;
    signal n_base   : std_logic_vector(2 downto 0);
    signal n_orig, n_rem : std_logic_vector(7 downto 0);
    signal n_pc     : Data_Bus;

    function is_mf(v : std_logic; ins : std_logic_vector(15 downto 0)) return boolean is
    begin return v = '1' and (ins(15 downto 12) = OP_LM or ins(15 downto 12) = OP_SM); end function;

    function popcount_below(m : std_logic_vector(7 downto 0); k : integer) return integer is
        variable n : integer := 0;
    begin
        for i in 0 to 7 loop if i < k and m(i) = '1' then n := n + 1; end if; end loop;
        return n;
    end function;

    function lowest_bit(m : std_logic_vector(7 downto 0)) return integer is
    begin
        for i in 0 to 7 loop if m(i) = '1' then return i; end if; end loop;
        return -1;
    end function;
begin

    process(all)
        -- working copy of the sequence
        variable is_sw, flg, f_pend, defer : std_logic;
        variable base : std_logic_vector(2 downto 0);
        variable orig, rmask : std_logic_vector(7 downto 0);
        variable pc : Data_Bus;
        variable ins : std_logic_vector(15 downto 0);
        variable v : std_logic; variable c : std_logic;

        procedure start(i : std_logic_vector(15 downto 0); p : Data_Bus) is
            variable bb : integer;
        begin
            is_sw := '0'; if i(15 downto 12) = OP_SM then is_sw := '1'; end if;
            flg := i(8); f_pend := i(8);
            base := i(11 downto 9); orig := i(7 downto 0); rmask := i(7 downto 0);
            pc := p; defer := '0';
            if is_sw = '0' and base /= "000" then          -- LM overwriting its base register
                bb := 7 - to_integer(unsigned(base));
                if rmask(bb) = '1' then rmask(bb) := '0'; defer := '1'; end if;
            end if;
        end procedure;

        -- produce the next micro-op of the working sequence (v = '0' when none left)
        procedure next_uop(variable vo : out std_logic; variable io : out std_logic_vector(15 downto 0);
                           variable co : out std_logic) is
            variable k, off : integer;
            variable opc : std_logic_vector(3 downto 0);
            variable rd  : std_logic_vector(2 downto 0);
        begin
            if is_sw = '1' then opc := OP_SW; else opc := OP_LW; end if;
            vo := '1'; co := '0'; k := -1;
            if f_pend = '1' then
                f_pend := '0'; co := '1';
                io := opc & "000" & base & "000000";
            else
                if rmask /= "00000000" then
                    k := lowest_bit(rmask); rmask(k) := '0';
                elsif defer = '1' then
                    k := 7 - to_integer(unsigned(base)); defer := '0';
                end if;
                if k >= 0 then
                    rd  := std_logic_vector(to_unsigned(7 - k, 3));
                    off := 2 * popcount_below(orig, k);
                    if flg = '1' then off := off + 2; end if;
                    io := opc & rd & base & std_logic_vector(to_unsigned(off, 6));
                else
                    vo := '0'; io := (others => '0');
                end if;
            end if;
        end procedure;

        impure function more return boolean is
        begin return f_pend = '1' or rmask /= "00000000" or defer = '1'; end function;

        procedure keep_state is
        begin
            n_is_sw <= is_sw; n_flag <= flg; n_flag_pend <= f_pend; n_defer <= defer;
            n_base <= base; n_orig <= orig; n_rem <= rmask; n_pc <= pc;
        end procedure;
    begin
        -- Default: pass-through
        freeze_fetch <= '0'; redirect_en <= '0';
        redirect_pc  <= std_logic_vector(unsigned(fetch_pc_1) + 2);
        a <= '0'; flag_mem_op_1 <= '0'; flag_mem_op_2 <= '0';
        gen_valid_1 <= fetch_valid_1; gen_pc_1 <= fetch_pc_1; gen_instr_1 <= instr_pr1_1; gen_pred_1 <= fetch_pred_1;
        gen_valid_2 <= fetch_valid_2; gen_pc_2 <= fetch_pc_2; gen_instr_2 <= instr_pr1_2; gen_pred_2 <= fetch_pred_2;

        is_sw := l_is_sw; flg := l_flag; f_pend := l_flag_pend; defer := l_defer;
        base := l_base; orig := l_orig; rmask := l_rem; pc := l_pc;
        n_state <= state;

        if state = idle1 then
            if is_mf(fetch_valid_1, instr_pr1_1) then
                -- slot 1 is LM/SM: both slots carry micro-ops; slot 2 is refetched later
                start(instr_pr1_1, fetch_pc_1);
                redirect_en <= '1';
                next_uop(v, ins, c); gen_valid_1 <= v; gen_pc_1 <= pc; gen_instr_1 <= ins; flag_mem_op_1 <= c;
                next_uop(v, ins, c); gen_valid_2 <= v; gen_pc_2 <= pc; gen_instr_2 <= ins; flag_mem_op_2 <= c;
                gen_pred_1 <= std_logic_vector(unsigned(pc) + 2); gen_pred_2 <= std_logic_vector(unsigned(pc) + 2);
                if more then freeze_fetch <= '1'; n_state <= generate1; end if;
            elsif is_mf(fetch_valid_2, instr_pr1_2) then
                -- slot 1 is a normal instruction (passes through); slot 2 starts the sequence
                start(instr_pr1_2, fetch_pc_2);
                next_uop(v, ins, c); gen_valid_2 <= v; gen_pc_2 <= pc; gen_instr_2 <= ins; flag_mem_op_2 <= c;
                gen_pred_2 <= std_logic_vector(unsigned(pc) + 2);
                if more then freeze_fetch <= '1'; n_state <= generate1; end if;
            end if;
        else
            a <= '1';
            next_uop(v, ins, c); gen_valid_1 <= v; gen_pc_1 <= pc; gen_instr_1 <= ins; flag_mem_op_1 <= c;
            next_uop(v, ins, c); gen_valid_2 <= v; gen_pc_2 <= pc; gen_instr_2 <= ins; flag_mem_op_2 <= c;
            gen_pred_1 <= std_logic_vector(unsigned(pc) + 2); gen_pred_2 <= std_logic_vector(unsigned(pc) + 2);
            if more then freeze_fetch <= '1'; else n_state <= idle1; end if;
        end if;
        keep_state;
    end process;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' or flush_pipeline = '1' then
                state <= idle1;
                l_is_sw <= '0'; l_flag <= '0'; l_flag_pend <= '0'; l_defer <= '0';
                l_base <= (others => '0'); l_orig <= (others => '0'); l_rem <= (others => '0');
                l_pc <= (others => '0');
            elsif hold = '0' then
                state <= n_state;
                l_is_sw <= n_is_sw; l_flag <= n_flag; l_flag_pend <= n_flag_pend; l_defer <= n_defer;
                l_base <= n_base; l_orig <= n_orig; l_rem <= n_rem; l_pc <= n_pc;
            end if;
        end if;
    end process;
end Strict_Sync;
