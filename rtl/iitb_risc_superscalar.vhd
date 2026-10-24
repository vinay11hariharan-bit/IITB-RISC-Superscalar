library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;

entity iitb_risc_superscalar is
    generic (
        IMEM_INIT : string := "";   -- optional program hex file (empty = built-in program in IMEM.vhd)
        DMEM_INIT : string := ""    -- optional data hex file    (empty = built-in contents in DMEM.vhd)
    );
    Port (
        clk : in std_logic;
        rst : in std_logic;

        -- ==========================================
        -- Observation / Debug Ports
        -- ==========================================
        -- Instruction Fetch Observation
        dbg_imem_pc         : out Data_Bus;
        dbg_imem_instr      : out std_logic_vector(31 downto 0);

        -- Pipeline Control Observation
        dbg_flush_pipeline  : out std_logic;
        dbg_rob_full        : out std_logic;

        -- Commit Stage Observation (Superscalar - 2 ways)
        dbg_commit_en_1     : out std_logic;
        dbg_commit_arf_1    : out Arf_Tag;
        dbg_commit_val_1    : out Data_Bus;

        dbg_commit_en_2     : out std_logic;
        dbg_commit_arf_2    : out Arf_Tag;
        dbg_commit_val_2    : out Data_Bus;

        -- Data Memory Observation (write port = committed stores leaving the Store Buffer)
        dbg_dmem_req        : out std_logic;
        dbg_dmem_rw         : out std_logic;
        dbg_dmem_addr       : out Data_Bus;
        dbg_dmem_wdata      : out Data_Bus;

        -- Load/store activity
        dbg_load_rd_en      : out std_logic;   -- LSQ reads DMEM this cycle
        dbg_load_rd_addr    : out Data_Bus;
        dbg_sb_empty        : out std_logic    -- no committed store waiting to reach DMEM
    );
end iitb_risc_superscalar;

architecture Structural of iitb_risc_superscalar is

    signal flush_pipeline, imem_valid, mf_v_1, mf_v_2, mf_flg_1, mf_flg_2, mf_a_flag, mf_stall : std_logic;
    signal mf_redirect : std_logic; signal mf_redirect_pc : Data_Bus;
    signal dec_v_1, dec_v_2, front_stall, rr_stall_out, router_stall_out : std_logic;
    signal rr_en_1, rr_en_2, rr_ok_1, rr_ok_2, d_en_1, d_en_2 : std_logic;
    signal f_v_1, f_v_2 : std_logic;
    signal recovery_pc, imem_pc, f_pc_1, f_pc_2, f_in_1, f_in_2, f_pred_1, f_pred_2 : Data_Bus;
    signal imem_instr_32 : std_logic_vector(31 downto 0);
    signal mf_pc_1, mf_pc_2, mf_pred_1, mf_pred_2 : Data_Bus;
    signal mf_in_1, mf_in_2 : std_logic_vector(15 downto 0);
    signal dec_b_1, dec_b_2, rr_b_1, rr_b_2 : Instr_Bundle;
    signal rr_dest_1, rr_dest_2, rr_q1_1, rr_q2_1, rr_q3_1, rr_q1_2, rr_q2_2, rr_q3_2 : Reg_Tag;
    signal rr_busy_q1_1, rr_busy_q2_1, rr_busy_q3_1, rr_busy_q1_2, rr_busy_q2_2, rr_busy_q3_2 : std_logic;
    signal v1_val_1, v2_val_1, v3_val_1, v1_val_2, v2_val_2, v3_val_2 : std_logic;
    signal v1_1, v2_1, v3_1, v1_2, v2_2, v3_2 : Data_Bus;
    signal rob_tag_1, rob_tag_2, alu_rob, br_rob, lsq_rob, cdb1_rob, cdb2_rob : Rob_Tag;
    signal alu_iss_rob, br_iss_rob, cmt_rob_1, cmt_rob_2 : Rob_Tag;
    signal rob_full, alu_en_1, alu_en_2, branch_en_1, branch_en_2, lsq_en_1, lsq_en_2 : std_logic;
    signal alu_rs_full, br_rs_full, lsq_full : std_logic;
    signal alu_req, alu_hold, alu_exec_stall, br_req, br_hold, lsq_req, lsq_hold : std_logic;
    signal alu_tag, br_tag, lsq_tag, cdb1_tag, cdb2_tag : Reg_Tag;
    signal alu_iss_dest, br_iss_dest : Reg_Tag;
    signal alu_iss_v, br_iss_v, cdb1_valid, cdb2_valid : std_logic;
    signal alu_val, br_val, br_act_pc, lsq_val, cdb1_val, cdb2_val, cdb1_act_pc, cdb2_act_pc : Data_Bus;
    signal alu_iss_v1, alu_iss_v2, alu_iss_v3, alu_iss_c, br_iss_pc, br_iss_v1, br_iss_v2, br_iss_ccr : Data_Bus;
    signal alu_iss_16 : std_logic_vector(15 downto 0);
    signal alu_iss_op, br_iss_op, cmt_op_1, cmt_op_2 : std_logic_vector(3 downto 0);
    signal alu_iss_imm, br_iss_imm : std_logic_vector(8 downto 0);
    signal alu_flags, alu_mask, lsq_flags, lsq_mask, cdb1_flags, cdb1_mask, cdb2_flags, cdb2_mask : std_logic_vector(1 downto 0);
    signal ccr_valid : std_logic;
    signal ccr_val_2bit, cmt_flg_1, cmt_flg_2, cmt_mask_1, cmt_mask_2 : std_logic_vector(1 downto 0);
    signal ccr_val_16bit : Data_Bus;
    signal ccr_tag_out : Reg_Tag;
    signal cmt_en_1, cmt_en_2, cmt_store_1, cmt_store_2 : std_logic;
    signal cmt_arf_1, cmt_arf_2 : Arf_Tag;
    signal cmt_rrf_1, cmt_rrf_2 : Reg_Tag;
    signal cmt_val_1, cmt_val_2 : Data_Bus;

    -- CCR operand for slot 2 (intra-bundle forwarding when slot 1 writes the flags)
    signal slot1_writes_ccr : boolean;
    signal qc_2 : Reg_Tag; signal vc_val_2 : std_logic;

    -- Memory subsystem
    signal ls_dccr_1, ls_dccr_2, ls_qd_val_1, ls_qd_val_2 : std_logic;
    signal ls_qd_1, ls_qd_2 : Reg_Tag; signal ls_vd_1, ls_vd_2 : Data_Bus;
    signal sb_push_1, sb_push_2, sb_ready, sb_empty, sb_hit, dmem_rd_en, dmem_we : std_logic;
    signal sb_addr_1, sb_data_1, sb_addr_2, sb_data_2, sb_snoop_addr, sb_snoop_data : Data_Bus;
    signal dmem_rd_addr, dmem_rd_data, dmem_wr_addr, dmem_wr_data : Data_Bus;

    -- Branch Predictor Training Signals
    signal bp_train_en, bp_train_taken : std_logic;
    signal bp_train_pc, bp_train_target : Data_Bus;

begin
    ccr_val_16bit <= "00000000000000" & ccr_val_2bit;
    rr_busy_q1_1 <= '0' when rr_q1_1 = "0000" else '1'; rr_busy_q2_1 <= '0' when rr_q2_1 = "0000" else '1'; rr_busy_q3_1 <= '0' when rr_q3_1 = "0000" else '1';
    rr_busy_q1_2 <= '0' when rr_q1_2 = "0000" else '1'; rr_busy_q2_2 <= '0' when rr_q2_2 = "0000" else '1'; rr_busy_q3_2 <= '0' when rr_q3_2 = "0000" else '1';

    -- ------------------------------------------------------------------
    -- Back-pressure: if any back-end structure is (nearly) full the renamed
    -- bundle stays in the RR stage, and decode / MF / fetch hold as well.
    -- Nothing is dispatched while a flush is in progress.
    -- ------------------------------------------------------------------
    front_stall <= rr_stall_out or router_stall_out;
    rr_ok_1 <= rr_en_1 and not flush_pipeline;
    rr_ok_2 <= rr_en_2 and not flush_pipeline;
    d_en_1  <= rr_ok_1 and not router_stall_out;
    d_en_2  <= rr_ok_2 and not router_stall_out;

    slot1_writes_ccr <= d_en_1 = '1' and writes_ccr(rr_b_1.Opcode, rr_b_1.Is_CCR_Mem);
    qc_2     <= rr_dest_1 when slot1_writes_ccr else ccr_tag_out;
    vc_val_2 <= '0'       when slot1_writes_ccr else ccr_valid;

    -- LSQ data operand: register for SW, condition codes for the SMF flag micro-op
    ls_dccr_1 <= '1' when rr_b_1.Is_CCR_Mem = '1' and rr_b_1.Opcode = OP_SW else '0';
    ls_dccr_2 <= '1' when rr_b_2.Is_CCR_Mem = '1' and rr_b_2.Opcode = OP_SW else '0';
    ls_qd_1     <= ccr_tag_out   when ls_dccr_1 = '1' else rr_q2_1;
    ls_qd_val_1 <= ccr_valid     when ls_dccr_1 = '1' else v2_val_1;
    ls_vd_1     <= ccr_val_16bit when ls_dccr_1 = '1' else v2_1;
    ls_qd_2     <= qc_2          when ls_dccr_2 = '1' else rr_q2_2;
    ls_qd_val_2 <= vc_val_2      when ls_dccr_2 = '1' else v2_val_2;
    ls_vd_2     <= ccr_val_16bit when ls_dccr_2 = '1' else v2_2;

    cmt_store_1 <= '1' when cmt_op_1 = OP_SW else '0';
    cmt_store_2 <= '1' when cmt_op_2 = OP_SW else '0';

    Inst_IMEM: entity work.IMEM generic map ( INIT_FILE => IMEM_INIT )
        port map ( clk => clk, imem_pc => imem_pc, imem_instr_32 => imem_instr_32, imem_valid => imem_valid );

    Inst_Fetch: entity work.Fetch_Unit port map (
        clk => clk, rst => rst, stall => mf_stall, hold => front_stall,
        redirect_en => mf_redirect, redirect_pc => mf_redirect_pc,
        flush_pipeline => flush_pipeline, recovery_pc => recovery_pc,
        bp_update_en => bp_train_en, bp_update_pc => bp_train_pc, bp_update_taken => bp_train_taken, bp_update_target => bp_train_target,
        imem_pc => imem_pc, imem_instr_32 => imem_instr_32, imem_valid => imem_valid,
        fetch_valid_1 => f_v_1, fetch_pc_1 => f_pc_1, fetch_instr_1 => f_in_1, fetch_pred_1 => f_pred_1,
        fetch_valid_2 => f_v_2, fetch_pc_2 => f_pc_2, fetch_instr_2 => f_in_2, fetch_pred_2 => f_pred_2
    );

    Inst_MF_Seq: entity work.MF_Sequencer port map (
        clk => clk, rst => rst, flush_pipeline => flush_pipeline, hold => front_stall,
        fetch_valid_1 => f_v_1, fetch_pc_1 => f_pc_1, instr_pr1_1 => f_in_1, fetch_pred_1 => f_pred_1,
        fetch_valid_2 => f_v_2, fetch_pc_2 => f_pc_2, instr_pr1_2 => f_in_2, fetch_pred_2 => f_pred_2,
        gen_valid_1 => mf_v_1, gen_pc_1 => mf_pc_1, gen_instr_1 => mf_in_1, gen_pred_1 => mf_pred_1,
        gen_valid_2 => mf_v_2, gen_pc_2 => mf_pc_2, gen_instr_2 => mf_in_2, gen_pred_2 => mf_pred_2,
        freeze_fetch => mf_stall, redirect_en => mf_redirect, redirect_pc => mf_redirect_pc,
        a => mf_a_flag, flag_mem_op_1 => mf_flg_1, flag_mem_op_2 => mf_flg_2 );

    Inst_Decode: entity work.Decode_Unit port map (
        clk => clk, rst => rst,
        gen_valid_1 => mf_v_1, gen_pc_1 => mf_pc_1, gen_instr_1 => mf_in_1, flag_mem_op_1 => mf_flg_1, gen_pred_1 => mf_pred_1,
        gen_valid_2 => mf_v_2, gen_pc_2 => mf_pc_2, gen_instr_2 => mf_in_2, flag_mem_op_2 => mf_flg_2, gen_pred_2 => mf_pred_2,
        a_flag_in => mf_a_flag, stall_in => front_stall, flush_pipeline => flush_pipeline, stall_out => open,
        decode_valid_1 => dec_v_1, bundle_1_out => dec_b_1, decode_valid_2 => dec_v_2, bundle_2_out => dec_b_2 );

    Inst_RR_Unit: entity work.RR_Unit port map (
        clk => clk, rst => rst, hold => router_stall_out,
        decode_valid_1 => dec_v_1, bundle_1_in => dec_b_1, decode_valid_2 => dec_v_2, bundle_2_in => dec_b_2,
        flush_pipeline => flush_pipeline,
        commit_en_1 => cmt_en_1, commit_rrf_1 => cmt_rrf_1, commit_arf_1 => cmt_arf_1,
        commit_en_2 => cmt_en_2, commit_rrf_2 => cmt_rrf_2, commit_arf_2 => cmt_arf_2,
        disp_en_1 => rr_en_1, bundle_1_out => rr_b_1, dest_tag_1 => rr_dest_1, src1_tag_1 => rr_q1_1, src2_tag_1 => rr_q2_1, src3_tag_1 => rr_q3_1,
        disp_en_2 => rr_en_2, bundle_2_out => rr_b_2, dest_tag_2 => rr_dest_2, src1_tag_2 => rr_q1_2, src2_tag_2 => rr_q2_2, src3_tag_2 => rr_q3_2,
        stall_front_end => rr_stall_out );

    Inst_Reg_File: entity work.Register_File_Array port map ( clk => clk, rst => rst, pc_1 => rr_b_1.PC, src1_arf_1 => rr_b_1.Src1_ARF, src1_rrf_1 => rr_q1_1, src1_busy_1 => rr_busy_q1_1, src2_arf_1 => rr_b_1.Src2_ARF, src2_rrf_1 => rr_q2_1, src2_busy_1 => rr_busy_q2_1, src3_arf_1 => rr_b_1.Src3_ARF, src3_rrf_1 => rr_q3_1, src3_busy_1 => rr_busy_q3_1, dest_rrf_1 => rr_dest_1, alloc_en_1 => d_en_1, pc_2 => rr_b_2.PC, src1_arf_2 => rr_b_2.Src1_ARF, src1_rrf_2 => rr_q1_2, src1_busy_2 => rr_busy_q1_2, src2_arf_2 => rr_b_2.Src2_ARF, src2_rrf_2 => rr_q2_2, src2_busy_2 => rr_busy_q2_2, src3_arf_2 => rr_b_2.Src3_ARF, src3_rrf_2 => rr_q3_2, src3_busy_2 => rr_busy_q3_2, dest_rrf_2 => rr_dest_2, alloc_en_2 => d_en_2, cdb_valid_1 => cdb1_valid, cdb_tag_1 => cdb1_tag, cdb_val_1 => cdb1_val, cdb_valid_2 => cdb2_valid, cdb_tag_2 => cdb2_tag, cdb_val_2 => cdb2_val, commit_en_1 => cmt_en_1, commit_arf_1 => cmt_arf_1, commit_val_1 => cmt_val_1, commit_en_2 => cmt_en_2, commit_arf_2 => cmt_arf_2, commit_val_2 => cmt_val_2, v1_val_1 => v1_val_1, v1_1 => v1_1, v2_val_1 => v2_val_1, v2_1 => v2_1, v3_val_1 => v3_val_1, v3_1 => v3_1, v1_val_2 => v1_val_2, v1_2 => v1_2, v2_val_2 => v2_val_2, v2_2 => v2_2, v3_val_2 => v3_val_2, v3_2 => v3_2 );

    Inst_Dispatch: entity work.Dispatch_Router port map ( rr_en_1 => rr_ok_1, rr_bundle_1 => rr_b_1, rr_dest_tag_1 => rr_dest_1, rr_q1_1 => rr_q1_1, rr_q2_1 => rr_q2_1, rr_en_2 => rr_ok_2, rr_bundle_2 => rr_b_2, rr_dest_tag_2 => rr_dest_2, rr_q1_2 => rr_q1_2, rr_q2_2 => rr_q2_2, rr_q3_ccr_1 => "0000", rr_q3_ccr_2 => "0000",
        rob_full => rob_full, alu_rs_full => alu_rs_full, branch_rs_full => br_rs_full, lsq_full => lsq_full,
        scheduler_stall => router_stall_out, alu_en_1 => alu_en_1, alu_en_2 => alu_en_2, branch_en_1 => branch_en_1, branch_en_2 => branch_en_2, lsq_en_1 => lsq_en_1, lsq_en_2 => lsq_en_2 );

    Inst_CCR_Tracker: entity work.CCR_Tracker port map ( clk => clk, rst => rst, flush_pipeline => flush_pipeline,
        disp_en_1 => d_en_1, op_1 => rr_b_1.Opcode, tag_1 => rr_dest_1, ccr_mem_1 => rr_b_1.Is_CCR_Mem,
        disp_en_2 => d_en_2, op_2 => rr_b_2.Opcode, tag_2 => rr_dest_2, ccr_mem_2 => rr_b_2.Is_CCR_Mem,
        cdb1_valid => cdb1_valid, cdb1_tag => cdb1_tag, cdb1_flags => cdb1_flags, cdb1_mask => cdb1_mask, cdb2_valid => cdb2_valid, cdb2_tag => cdb2_tag, cdb2_flags => cdb2_flags, cdb2_mask => cdb2_mask, commit_en_1 => cmt_en_1, cmt_tag_1 => cmt_rrf_1, cmt_flags_1 => cmt_flg_1, cmt_mask_1 => cmt_mask_1, commit_en_2 => cmt_en_2, cmt_tag_2 => cmt_rrf_2, cmt_flags_2 => cmt_flg_2, cmt_mask_2 => cmt_mask_2, ccr_valid => ccr_valid, ccr_val => ccr_val_2bit, ccr_tag_out => ccr_tag_out );

    Inst_ALU_RS: entity work.ALU_RS port map ( clk => clk, rst => rst, flush => flush_pipeline, rs_full => alu_rs_full, exec_stall => alu_exec_stall, disp_en_1 => alu_en_1, disp_en_2 => alu_en_2, bundle_1 => rr_b_1, bundle_2 => rr_b_2, rob_tag_1 => rob_tag_1, dest_tag_1 => rr_dest_1, rob_tag_2 => rob_tag_2, dest_tag_2 => rr_dest_2, q1_1 => rr_q1_1, q2_1 => rr_q2_1, q3_1 => rr_q3_1, qc_1 => ccr_tag_out, v1_val_1 => v1_val_1, v2_val_1 => v2_val_1, v3_val_1 => v3_val_1, vc_val_1 => ccr_valid, v1_1 => v1_1, v2_1 => v2_1, v3_1 => v3_1, vc_1 => ccr_val_16bit, q1_2 => rr_q1_2, q2_2 => rr_q2_2, q3_2 => rr_q3_2, qc_2 => qc_2, v1_val_2 => v1_val_2, v2_val_2 => v2_val_2, v3_val_2 => v3_val_2, vc_val_2 => vc_val_2, v1_2 => v1_2, v2_2 => v2_2, v3_2 => v3_2, vc_2 => ccr_val_16bit, cdb_v1 => cdb1_valid, cdb_t1 => cdb1_tag, cdb_val1 => cdb1_val, cdb_f1 => cdb1_flags, cdb_v2 => cdb2_valid, cdb_t2 => cdb2_tag, cdb_val2 => cdb2_val, cdb_f2 => cdb2_flags, issue_v => alu_iss_v, issue_op => alu_iss_op, issue_16 => alu_iss_16, issue_v1 => alu_iss_v1, issue_v2 => alu_iss_v2, issue_v3 => alu_iss_v3, issue_c => alu_iss_c, issue_imm => alu_iss_imm, issue_dest => alu_iss_dest, issue_rob => alu_iss_rob );
    Inst_ALU_Exec: entity work.ALU_Exec port map ( clk => clk, rst => rst, flush => flush_pipeline, issue_valid => alu_iss_v, issue_opcode => alu_iss_op, issue_16 => alu_iss_16, issue_v1 => alu_iss_v1, issue_v2 => alu_iss_v2, issue_v3 => alu_iss_v3, issue_c => alu_iss_c, issue_imm => alu_iss_imm, issue_dest_tag => alu_iss_dest, issue_rob_tag => alu_iss_rob, hold => alu_hold, exec_stall => alu_exec_stall, alu_req => alu_req, alu_tag => alu_tag, alu_val => alu_val, alu_rob => alu_rob, alu_flags => alu_flags, alu_mask => alu_mask );

    Inst_Branch_RS: entity work.Branch_RS port map ( clk => clk, rst => rst, flush => flush_pipeline, rs_full => br_rs_full,
        disp_en => branch_en_1, bundle => rr_b_1, disp_rob_tag => rob_tag_1, dest_tag => rr_dest_1,
        q1 => rr_q1_1, v1_val => v1_val_1, v1 => v1_1, q2 => rr_q2_1, v2_val => v2_val_1, v2 => v2_1,
        disp_en_b => branch_en_2, bundle_b => rr_b_2, disp_rob_tag_b => rob_tag_2, dest_tag_b => rr_dest_2,
        q1_b => rr_q1_2, v1_val_b => v1_val_2, v1_b => v1_2, q2_b => rr_q2_2, v2_val_b => v2_val_2, v2_b => v2_2,
        q3_ccr => "0000", v3_val => '1', v3_ccr => x"0000", cdb_valid_1 => cdb1_valid, cdb_tag_1 => cdb1_tag, cdb_val_1 => cdb1_val, cdb_valid_2 => cdb2_valid, cdb_tag_2 => cdb2_tag, cdb_val_2 => cdb2_val, ccr_cdb_valid => '0', ccr_cdb_tag => "0000", ccr_cdb_val => x"0000", issue_valid => br_iss_v, issue_opcode => br_iss_op, issue_pc => br_iss_pc, issue_v1 => br_iss_v1, issue_v2 => br_iss_v2, issue_ccr => br_iss_ccr, issue_imm => br_iss_imm, issue_dest_tag => br_iss_dest, issue_rob_tag => br_iss_rob );
    Inst_Branch_Exec: entity work.Branch_Exec port map ( clk => clk, rst => rst, flush => flush_pipeline, issue_valid => br_iss_v, issue_opcode => br_iss_op, issue_pc => br_iss_pc, issue_v1 => br_iss_v1, issue_v2 => br_iss_v2, issue_ccr => br_iss_ccr, issue_imm => br_iss_imm, issue_dest_tag => br_iss_dest, issue_rob_tag => br_iss_rob, cdb_valid => br_req, cdb_tag => br_tag, cdb_val => br_val, cdb_rob_tag => br_rob, cdb_actual_pc => br_act_pc );

    -- ------------------------------------------------------------------
    -- Load/Store unit: LSQ -> (commit) -> Store Buffer -> DMEM
    -- ------------------------------------------------------------------
    Inst_LSQ: entity work.LSQ port map (
        clk => clk, rst => rst, flush => flush_pipeline,
        disp_en_1 => lsq_en_1, bundle_1 => rr_b_1, rob_tag_1 => rob_tag_1, dest_tag_1 => rr_dest_1,
        q_base_1 => rr_q1_1, v_base_val_1 => v1_val_1, v_base_1 => v1_1,
        q_data_1 => ls_qd_1, v_data_val_1 => ls_qd_val_1, v_data_1 => ls_vd_1, data_is_ccr_1 => ls_dccr_1,
        disp_en_2 => lsq_en_2, bundle_2 => rr_b_2, rob_tag_2 => rob_tag_2, dest_tag_2 => rr_dest_2,
        q_base_2 => rr_q1_2, v_base_val_2 => v1_val_2, v_base_2 => v1_2,
        q_data_2 => ls_qd_2, v_data_val_2 => ls_qd_val_2, v_data_2 => ls_vd_2, data_is_ccr_2 => ls_dccr_2,
        lsq_full => lsq_full,
        cdb_valid_1 => cdb1_valid, cdb_tag_1 => cdb1_tag, cdb_val_1 => cdb1_val, cdb_flags_1 => cdb1_flags,
        cdb_valid_2 => cdb2_valid, cdb_tag_2 => cdb2_tag, cdb_val_2 => cdb2_val, cdb_flags_2 => cdb2_flags,
        commit_en_1 => cmt_en_1, commit_store_1 => cmt_store_1, commit_rob_1 => cmt_rob_1,
        commit_en_2 => cmt_en_2, commit_store_2 => cmt_store_2, commit_rob_2 => cmt_rob_2,
        sb_push_1 => sb_push_1, sb_addr_1 => sb_addr_1, sb_data_1 => sb_data_1,
        sb_push_2 => sb_push_2, sb_addr_2 => sb_addr_2, sb_data_2 => sb_data_2,
        sb_snoop_addr => sb_snoop_addr, sb_snoop_hit => sb_hit, sb_snoop_data => sb_snoop_data,
        mem_rd_en => dmem_rd_en, mem_rd_addr => dmem_rd_addr, mem_rd_data => dmem_rd_data,
        lsq_hold => lsq_hold, lsq_wb_valid => lsq_req, lsq_wb_val => lsq_val, lsq_wb_dest_tag => lsq_tag,
        lsq_wb_rob_tag => lsq_rob, lsq_wb_flags => lsq_flags, lsq_wb_mask => lsq_mask );

    Inst_Store_Buffer: entity work.Store_Buffer port map (
        clk => clk, rst => rst,
        push_1 => sb_push_1, addr_1 => sb_addr_1, data_1 => sb_data_1,
        push_2 => sb_push_2, addr_2 => sb_addr_2, data_2 => sb_data_2,
        sb_ready => sb_ready, sb_empty => sb_empty,
        snoop_addr => sb_snoop_addr, snoop_hit => sb_hit, snoop_data => sb_snoop_data,
        dmem_we => dmem_we, dmem_addr => dmem_wr_addr, dmem_wdata => dmem_wr_data );

    Inst_DMEM: entity work.DMEM generic map ( INIT_FILE => DMEM_INIT )
        port map ( clk => clk, rd_en => dmem_rd_en, rd_addr => dmem_rd_addr, rd_data => dmem_rd_data,
                   we => dmem_we, wr_addr => dmem_wr_addr, wr_data => dmem_wr_data );

    Inst_CDB_Arbiter: entity work.CDB_Arbiter port map ( branch_req => br_req, branch_tag => br_tag, branch_val => br_val, branch_rob => br_rob, branch_act_pc => br_act_pc, lsq_req => lsq_req, lsq_tag => lsq_tag, lsq_val => lsq_val, lsq_rob => lsq_rob, lsq_flags => lsq_flags, lsq_mask => lsq_mask, alu_req => alu_req, alu_tag => alu_tag, alu_val => alu_val, alu_rob => alu_rob, alu_flags => alu_flags, alu_mask => alu_mask, branch_hold => br_hold, lsq_hold => lsq_hold, alu_hold => alu_hold, cdb1_valid => cdb1_valid, cdb1_tag => cdb1_tag, cdb1_val => cdb1_val, cdb1_rob => cdb1_rob, cdb1_act_pc => cdb1_act_pc, cdb1_flags => cdb1_flags, cdb1_mask => cdb1_mask, cdb2_valid => cdb2_valid, cdb2_tag => cdb2_tag, cdb2_val => cdb2_val, cdb2_rob => cdb2_rob, cdb2_act_pc => cdb2_act_pc, cdb2_flags => cdb2_flags, cdb2_mask => cdb2_mask );

    Inst_ROB: entity work.ROB port map (
        clk => clk, rst => rst, next_alloc_1 => rob_tag_1, next_alloc_2 => rob_tag_2, rob_full => rob_full,
        disp_en_1 => d_en_1, bundle_1 => rr_b_1, dest_tag_1 => rr_dest_1, is_micro_op_1 => rr_b_1.Is_Micro_Op,
        disp_en_2 => d_en_2, bundle_2 => rr_b_2, dest_tag_2 => rr_dest_2, is_micro_op_2 => rr_b_2.Is_Micro_Op,
        cdb1_valid => cdb1_valid, cdb1_rob_tag => cdb1_rob, cdb1_val => cdb1_val, cdb1_act_pc => cdb1_act_pc, cdb1_flags => cdb1_flags, cdb1_mask => cdb1_mask,
        cdb2_valid => cdb2_valid, cdb2_rob_tag => cdb2_rob, cdb2_val => cdb2_val, cdb2_act_pc => cdb2_act_pc, cdb2_flags => cdb2_flags, cdb2_mask => cdb2_mask,
        commit_en_1 => cmt_en_1, commit_opcode_1 => cmt_op_1, commit_rob_tag_1 => cmt_rob_1, commit_arf_1 => cmt_arf_1, commit_rrf_1 => cmt_rrf_1, commit_val_1 => cmt_val_1, commit_flags_1 => cmt_flg_1, commit_mask_1 => cmt_mask_1,
        commit_en_2 => cmt_en_2, commit_opcode_2 => cmt_op_2, commit_rob_tag_2 => cmt_rob_2, commit_arf_2 => cmt_arf_2, commit_rrf_2 => cmt_rrf_2, commit_val_2 => cmt_val_2, commit_flags_2 => cmt_flg_2, commit_mask_2 => cmt_mask_2,
        sb_ready => sb_ready,
        flush_pipeline => flush_pipeline, recovery_pc => recovery_pc,
        bp_train_en => bp_train_en, bp_train_pc => bp_train_pc, bp_train_target => bp_train_target, bp_train_taken => bp_train_taken
    );

    -- ==========================================
    -- Observation / Debug Signal Routing
    -- ==========================================
    dbg_imem_pc        <= imem_pc;
    dbg_imem_instr     <= imem_instr_32;
    dbg_flush_pipeline <= flush_pipeline;
    dbg_rob_full       <= rob_full;

    dbg_commit_en_1    <= cmt_en_1;
    dbg_commit_arf_1   <= cmt_arf_1;
    dbg_commit_val_1   <= cmt_val_1;

    dbg_commit_en_2    <= cmt_en_2;
    dbg_commit_arf_2   <= cmt_arf_2;
    dbg_commit_val_2   <= cmt_val_2;

    dbg_dmem_req       <= dmem_we;
    dbg_dmem_rw        <= '1';
    dbg_dmem_addr      <= dmem_wr_addr;
    dbg_dmem_wdata     <= dmem_wr_data;

    dbg_load_rd_en     <= dmem_rd_en;
    dbg_load_rd_addr   <= dmem_rd_addr;
    dbg_sb_empty       <= sb_empty;

end Structural;
