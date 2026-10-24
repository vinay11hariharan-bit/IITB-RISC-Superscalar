-- =====================================================================
-- Load/Store Queue (unified, program-ordered circular FIFO)
--
--  * Dual dispatch (both fetch slots), so paired LM/SM micro-ops are kept.
--  * Per-entry address generation (EA = base + SE(imm)), one cycle after
--    the base operand is available.
--  * Loads issue out of order once every older store has a known address.
--    The youngest older store to the same word forwards its data
--    (store-to-load forwarding); a matching store whose data is not ready
--    yet makes the load wait.  If no store in the LSQ matches, the committed
--    stores waiting in the Store Buffer are checked next, then DMEM is read.
--  * Stores never touch memory here.  When address and data are known the
--    store reports "done" to the ROB over the CDB (dest tag 0000).  When the
--    ROB commits it, the entry is handed to the Store Buffer in the same
--    clock edge, and only the Store Buffer writes DMEM.
--  * A pipeline flush empties the queue.  Committed stores have already left
--    for the Store Buffer, so no architectural store is lost.
--
-- Load timing: AGU (cycle 1) -> select + DMEM read / forward (cycle 2)
--              -> result on CDB (cycle 3).
-- =====================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;

entity LSQ is
    generic ( LSQ_DEPTH : integer := 8 );
    Port (
        clk, rst, flush : in  std_logic;

        -- Dispatch (slot 1 is older than slot 2)
        disp_en_1   : in  std_logic; bundle_1 : in Instr_Bundle; rob_tag_1 : in Rob_Tag; dest_tag_1 : in Reg_Tag;
        q_base_1    : in  Reg_Tag; v_base_val_1 : in std_logic; v_base_1 : in Data_Bus;
        q_data_1    : in  Reg_Tag; v_data_val_1 : in std_logic; v_data_1 : in Data_Bus; data_is_ccr_1 : in std_logic;

        disp_en_2   : in  std_logic; bundle_2 : in Instr_Bundle; rob_tag_2 : in Rob_Tag; dest_tag_2 : in Reg_Tag;
        q_base_2    : in  Reg_Tag; v_base_val_2 : in std_logic; v_base_2 : in Data_Bus;
        q_data_2    : in  Reg_Tag; v_data_val_2 : in std_logic; v_data_2 : in Data_Bus; data_is_ccr_2 : in std_logic;

        lsq_full    : out std_logic;   -- fewer than two free entries

        -- CDB snooping
        cdb_valid_1 : in  std_logic; cdb_tag_1 : in Reg_Tag; cdb_val_1 : in Data_Bus; cdb_flags_1 : in std_logic_vector(1 downto 0);
        cdb_valid_2 : in  std_logic; cdb_tag_2 : in Reg_Tag; cdb_val_2 : in Data_Bus; cdb_flags_2 : in std_logic_vector(1 downto 0);

        -- Commit (from ROB)
        commit_en_1 : in  std_logic; commit_store_1 : in std_logic; commit_rob_1 : in Rob_Tag;
        commit_en_2 : in  std_logic; commit_store_2 : in std_logic; commit_rob_2 : in Rob_Tag;

        -- Committed stores -> Store Buffer
        sb_push_1   : out std_logic; sb_addr_1 : out Data_Bus; sb_data_1 : out Data_Bus;
        sb_push_2   : out std_logic; sb_addr_2 : out Data_Bus; sb_data_2 : out Data_Bus;

        -- Store Buffer forwarding lookup
        sb_snoop_addr : out Data_Bus;
        sb_snoop_hit  : in  std_logic;
        sb_snoop_data : in  Data_Bus;

        -- DMEM read port (synchronous: data valid the cycle after rd_en)
        mem_rd_en   : out std_logic;
        mem_rd_addr : out Data_Bus;
        mem_rd_data : in  Data_Bus;

        -- Writeback to CDB arbiter
        lsq_hold        : in  std_logic;
        lsq_wb_valid    : out std_logic;
        lsq_wb_val      : out Data_Bus;
        lsq_wb_dest_tag : out Reg_Tag;
        lsq_wb_rob_tag  : out Rob_Tag;
        lsq_wb_flags    : out std_logic_vector(1 downto 0);
        lsq_wb_mask     : out std_logic_vector(1 downto 0)
    );
end LSQ;

architecture Behavioral of LSQ is
    type LSQ_Entry is record
        Is_Store    : std_logic;
        Is_CCR      : std_logic;   -- LMF/SMF flag micro-op
        ROB_Tag     : Rob_Tag;
        Dest_Tag    : Reg_Tag;
        Imm         : std_logic_vector(8 downto 0);
        Q_Base      : Reg_Tag; Base_Valid : std_logic; Base : Data_Bus;
        Q_Data      : Reg_Tag; Data_Valid : std_logic; Data : Data_Bus; Data_CCR : std_logic;
        Addr_Ready  : std_logic; Addr : Data_Bus;
        Done        : std_logic;   -- load issued / store reported to ROB
        Finished    : std_logic;   -- entry can be popped (load issued / store sent to Store Buffer)
    end record;
    type LSQ_Array is array (0 to LSQ_DEPTH-1) of LSQ_Entry;

    signal q     : LSQ_Array;
    signal head, tail : integer range 0 to LSQ_DEPTH-1 := 0;
    signal count : integer range 0 to LSQ_DEPTH := 0;

    -- writeback stage register
    signal wb_valid, wb_from_mem, wb_ccr : std_logic := '0';
    signal wb_dest : Reg_Tag;
    signal wb_rob  : Rob_Tag;
    signal wb_fwd  : Data_Bus;

    -- combinational selection
    signal sel_valid, sel_store, sel_fwd : std_logic;
    signal sel_idx : integer range 0 to LSQ_DEPTH-1;
    signal sel_fwd_val, sel_addr : Data_Bus;
    signal stage_hold, go_mem : std_logic;

    -- combinational commit lookup
    signal cm_hit_1, cm_hit_2 : std_logic;
    signal cm_idx_1, cm_idx_2 : integer range 0 to LSQ_DEPTH-1;

begin

    lsq_full <= '1' when count > LSQ_DEPTH-2 else '0';

    -- -----------------------------------------------------------------
    -- Select the oldest entry that can execute this cycle
    -- -----------------------------------------------------------------
    process(q, head, count)
        variable idx, jdx : integer range 0 to LSQ_DEPTH-1;
        variable blocked, match, match_rdy : boolean;
        variable match_val : Data_Bus;
    begin
        sel_valid <= '0'; sel_store <= '0'; sel_fwd <= '0'; sel_idx <= 0;
        sel_fwd_val <= (others => '0'); sel_addr <= (others => '0');
        scan: for k in 0 to LSQ_DEPTH-1 loop
            if k < count then
                idx := (head + k) mod LSQ_DEPTH;
                if q(idx).Done = '0' and q(idx).Addr_Ready = '1' then
                    if q(idx).Is_Store = '1' then
                        if q(idx).Data_Valid = '1' then
                            sel_valid <= '1'; sel_store <= '1'; sel_idx <= idx; sel_addr <= q(idx).Addr;
                            exit scan;
                        end if;
                    else
                        -- memory disambiguation against all older, uncommitted stores
                        blocked := false; match := false; match_rdy := false; match_val := (others => '0');
                        for j in 0 to LSQ_DEPTH-1 loop
                            if j < k then
                                jdx := (head + j) mod LSQ_DEPTH;
                                if q(jdx).Is_Store = '1' and q(jdx).Finished = '0' then
                                    if q(jdx).Addr_Ready = '0' then
                                        blocked := true;            -- unknown address: assume conflict
                                    elsif same_word(q(jdx).Addr, q(idx).Addr) then
                                        match := true;              -- youngest match wins (later j overrides)
                                        match_rdy := q(jdx).Data_Valid = '1';
                                        match_val := q(jdx).Data;
                                    end if;
                                end if;
                            end if;
                        end loop;
                        if not blocked and (not match or match_rdy) then
                            sel_valid <= '1'; sel_store <= '0'; sel_idx <= idx; sel_addr <= q(idx).Addr;
                            if match then sel_fwd <= '1'; sel_fwd_val <= match_val; end if;
                            exit scan;
                        end if;
                    end if;
                end if;
            end if;
        end loop;
    end process;

    stage_hold <= lsq_hold and wb_valid;   -- CDB busy: keep the current result, issue nothing
    go_mem     <= '1' when sel_valid = '1' and sel_store = '0' and sel_fwd = '0' and sb_snoop_hit = '0'
                           and stage_hold = '0' else '0';

    sb_snoop_addr <= sel_addr;
    mem_rd_en     <= go_mem;
    mem_rd_addr   <= sel_addr;

    -- -----------------------------------------------------------------
    -- Commit lookup: find the store being committed on each ROB port
    -- -----------------------------------------------------------------
    process(q, head, count, commit_en_1, commit_store_1, commit_rob_1, commit_en_2, commit_store_2, commit_rob_2)
        variable idx : integer range 0 to LSQ_DEPTH-1;
    begin
        cm_hit_1 <= '0'; cm_idx_1 <= 0; cm_hit_2 <= '0'; cm_idx_2 <= 0;
        for k in 0 to LSQ_DEPTH-1 loop
            if k < count then
                idx := (head + k) mod LSQ_DEPTH;
                if q(idx).Is_Store = '1' and q(idx).Finished = '0' then
                    if commit_en_1 = '1' and commit_store_1 = '1' and q(idx).ROB_Tag = commit_rob_1 then
                        cm_hit_1 <= '1'; cm_idx_1 <= idx;
                    end if;
                    if commit_en_2 = '1' and commit_store_2 = '1' and q(idx).ROB_Tag = commit_rob_2 then
                        cm_hit_2 <= '1'; cm_idx_2 <= idx;
                    end if;
                end if;
            end if;
        end loop;
    end process;

    sb_push_1 <= cm_hit_1; sb_addr_1 <= q(cm_idx_1).Addr; sb_data_1 <= q(cm_idx_1).Data;
    sb_push_2 <= cm_hit_2; sb_addr_2 <= q(cm_idx_2).Addr; sb_data_2 <= q(cm_idx_2).Data;

    -- -----------------------------------------------------------------
    -- Writeback outputs
    -- -----------------------------------------------------------------
    process(wb_valid, wb_from_mem, wb_fwd, mem_rd_data, wb_dest, wb_rob, wb_ccr)
        variable v : Data_Bus;
    begin
        if wb_from_mem = '1' then v := mem_rd_data; else v := wb_fwd; end if;
        lsq_wb_valid    <= wb_valid;
        lsq_wb_val      <= v;
        lsq_wb_dest_tag <= wb_dest;
        lsq_wb_rob_tag  <= wb_rob;
        if wb_ccr = '1' then lsq_wb_flags <= v(1 downto 0); lsq_wb_mask <= "11";  -- LMF flag load -> C,Z
        else                 lsq_wb_flags <= "00";          lsq_wb_mask <= "00"; end if;
    end process;

    -- -----------------------------------------------------------------
    -- State update
    -- -----------------------------------------------------------------
    process(clk)
        variable nq : LSQ_Array;
        variable nh, nt : integer range 0 to LSQ_DEPTH-1;
        variable nc : integer range 0 to LSQ_DEPTH;
        variable e  : LSQ_Entry;

        procedure enqueue(b : Instr_Bundle; rt : Rob_Tag; dt : Reg_Tag;
                          qb : Reg_Tag; vbv : std_logic; vb : Data_Bus;
                          qd : Reg_Tag; vdv : std_logic; vd : Data_Bus; dccr : std_logic) is
        begin
            e.Is_Store := '0'; if b.Opcode = OP_SW then e.Is_Store := '1'; end if;
            e.Is_CCR   := b.Is_CCR_Mem;
            e.ROB_Tag  := rt; e.Dest_Tag := dt; e.Imm := b.Imm;
            e.Q_Base := qb; e.Base_Valid := vbv; e.Base := vb;
            if e.Is_Store = '1' then
                e.Q_Data := qd; e.Data_Valid := vdv; e.Data := vd; e.Data_CCR := dccr;
            else
                e.Q_Data := (others => '0'); e.Data_Valid := '1'; e.Data := (others => '0'); e.Data_CCR := '0';
            end if;
            e.Addr_Ready := '0'; e.Addr := (others => '0');
            e.Done := '0'; e.Finished := '0';
            nq(nt) := e; nt := (nt + 1) mod LSQ_DEPTH; nc := nc + 1;
        end procedure;
    begin
        if rising_edge(clk) then
            if rst = '1' or flush = '1' then
                head <= 0; tail <= 0; count <= 0;
                wb_valid <= '0'; wb_from_mem <= '0'; wb_ccr <= '0';
            else
                nq := q; nh := head; nt := tail; nc := count;

                for i in 0 to LSQ_DEPTH-1 loop
                    -- 1. Address generation (uses the base value held since last cycle)
                    if q(i).Base_Valid = '1' and q(i).Addr_Ready = '0' then
                        nq(i).Addr := std_logic_vector(unsigned(q(i).Base) + unsigned(resize(signed(q(i).Imm), DATA_WIDTH)));
                        nq(i).Addr_Ready := '1';
                    end if;
                    -- 2. CDB wakeup
                    if q(i).Base_Valid = '0' then
                        if    cdb_valid_1 = '1' and q(i).Q_Base = cdb_tag_1 then nq(i).Base_Valid := '1'; nq(i).Base := cdb_val_1;
                        elsif cdb_valid_2 = '1' and q(i).Q_Base = cdb_tag_2 then nq(i).Base_Valid := '1'; nq(i).Base := cdb_val_2; end if;
                    end if;
                    if q(i).Data_Valid = '0' then
                        if cdb_valid_1 = '1' and q(i).Q_Data = cdb_tag_1 then
                            nq(i).Data_Valid := '1';
                            if q(i).Data_CCR = '1' then nq(i).Data := (others => '0'); nq(i).Data(1 downto 0) := cdb_flags_1;
                            else nq(i).Data := cdb_val_1; end if;
                        elsif cdb_valid_2 = '1' and q(i).Q_Data = cdb_tag_2 then
                            nq(i).Data_Valid := '1';
                            if q(i).Data_CCR = '1' then nq(i).Data := (others => '0'); nq(i).Data(1 downto 0) := cdb_flags_2;
                            else nq(i).Data := cdb_val_2; end if;
                        end if;
                    end if;
                end loop;

                -- 3. Issue the selected entry into the writeback stage
                if stage_hold = '0' then
                    wb_valid <= sel_valid;
                    if sel_valid = '1' then
                        wb_rob <= q(sel_idx).ROB_Tag;
                        nq(sel_idx).Done := '1';
                        if sel_store = '1' then
                            wb_dest <= "0000"; wb_from_mem <= '0'; wb_fwd <= (others => '0'); wb_ccr <= '0';
                        else
                            nq(sel_idx).Finished := '1';
                            wb_dest <= q(sel_idx).Dest_Tag; wb_ccr <= q(sel_idx).Is_CCR;
                            if sel_fwd = '1' then       wb_from_mem <= '0'; wb_fwd <= sel_fwd_val;
                            elsif sb_snoop_hit = '1' then wb_from_mem <= '0'; wb_fwd <= sb_snoop_data;
                            else                         wb_from_mem <= '1'; end if;
                        end if;
                    end if;
                end if;

                -- 4. Committed stores leave for the Store Buffer
                if cm_hit_1 = '1' then nq(cm_idx_1).Finished := '1'; end if;
                if cm_hit_2 = '1' then nq(cm_idx_2).Finished := '1'; end if;

                -- 5. Retire finished entries from the head (up to two per cycle)
                for k in 0 to 1 loop
                    if nc > 0 and nq(nh).Finished = '1' then
                        nh := (nh + 1) mod LSQ_DEPTH; nc := nc - 1;
                    end if;
                end loop;

                -- 6. Dispatch new entries at the tail
                if disp_en_1 = '1' and bundle_1.Is_Mem = '1' and nc < LSQ_DEPTH then
                    enqueue(bundle_1, rob_tag_1, dest_tag_1, q_base_1, v_base_val_1, v_base_1, q_data_1, v_data_val_1, v_data_1, data_is_ccr_1);
                end if;
                if disp_en_2 = '1' and bundle_2.Is_Mem = '1' and nc < LSQ_DEPTH then
                    enqueue(bundle_2, rob_tag_2, dest_tag_2, q_base_2, v_base_val_2, v_base_2, q_data_2, v_data_val_2, v_data_2, data_is_ccr_2);
                end if;

                q <= nq; head <= nh; tail <= nt; count <= nc;
            end if;
        end if;
    end process;
end Behavioral;
