library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;

entity iitb_risc_superscalar is
    Port ( 
        clk : in std_logic; 
        rst : in std_logic;
        
        -- ==========================================
        -- NEW: Observation / Debug Ports
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
        
        -- Data Memory / External IO Observation
        dbg_dmem_req        : out std_logic;
        dbg_dmem_rw         : out std_logic;
        dbg_dmem_addr       : out Data_Bus;
        dbg_dmem_wdata      : out Data_Bus
    );
end iitb_risc_superscalar;

architecture Structural of iitb_risc_superscalar is

    signal flush_pipeline, imem_valid, mf_v_1, mf_v_2, mf_flg_1, mf_flg_2, mf_a_flag, mf_stall : std_logic;
    signal dec_v_1, dec_v_2, decode_stall_in, rr_stall_out, router_stall_out : std_logic;
    signal rr_en_1, rr_en_2 : std_logic;
    signal f_v_1, f_v_2 : std_logic;
    signal recovery_pc, imem_pc, f_pc_1, f_pc_2, f_in_1, f_in_2 : Data_Bus;
    signal imem_instr_32 : std_logic_vector(31 downto 0);
    signal mf_pc_1, mf_pc_2 : Data_Bus;
    signal mf_in_1, mf_in_2 : std_logic_vector(15 downto 0);
    signal dec_b_1, dec_b_2, rr_b_1, rr_b_2, br_bundle : Instr_Bundle;
    signal rr_dest_1, rr_dest_2, rr_q1_1, rr_q2_1, rr_q3_1, rr_q1_2, rr_q2_2, rr_q3_2 : Reg_Tag;
    signal rr_busy_q1_1, rr_busy_q2_1, rr_busy_q3_1, rr_busy_q1_2, rr_busy_q2_2, rr_busy_q3_2 : std_logic;
    signal v1_val_1, v2_val_1, v3_val_1, v1_val_2, v2_val_2, v3_val_2 : std_logic;
    signal v1_1, v2_1, v3_1, v1_2, v2_2, v3_2 : Data_Bus;
    signal rob_tag_1, rob_tag_2, br_rob_tag, alu_rob, br_rob, lsq_rob, cdb1_rob, cdb2_rob : Rob_Tag;
    signal alu_iss_rob, br_iss_rob : Rob_Tag;
    signal rob_full, alu_en_1, alu_en_2, branch_en_1, branch_en_2, lsq_en_1, lsq_en_2 : std_logic;
    signal br_disp_en, alu_req, alu_hold, alu_exec_stall, br_req, br_hold, lsq_req, lsq_hold : std_logic;
    signal br_dest_tag, br_q1, br_q2, alu_tag, br_tag, lsq_tag, cdb1_tag, cdb2_tag : Reg_Tag;
    signal alu_iss_dest, br_iss_dest : Reg_Tag;
    signal br_v1_val, br_v2_val, alu_iss_v, br_iss_v, cdb1_valid, cdb2_valid : std_logic;
    signal br_v1, br_v2, alu_val, br_val, br_act_pc, lsq_val, cdb1_val, cdb2_val, cdb1_act_pc, cdb2_act_pc : Data_Bus;
    signal alu_iss_v1, alu_iss_v2, alu_iss_v3, alu_iss_c, br_iss_pc, br_iss_v1, br_iss_v2, br_iss_ccr : Data_Bus;
    signal alu_iss_16 : std_logic_vector(15 downto 0);
    signal alu_iss_op, br_iss_op, cmt_op_1, cmt_op_2 : std_logic_vector(3 downto 0);
    signal alu_iss_imm, br_iss_imm : std_logic_vector(8 downto 0);
    signal alu_flags, alu_mask, cdb1_flags, cdb1_mask, cdb2_flags, cdb2_mask : std_logic_vector(1 downto 0);
    signal ccr_valid : std_logic;
    signal ccr_val_2bit, cmt_flg_1, cmt_flg_2, cmt_mask_1, cmt_mask_2 : std_logic_vector(1 downto 0);
    signal ccr_val_16bit : Data_Bus;
    signal ccr_tag_out : Reg_Tag;
    signal cmt_en_1, cmt_en_2, commit_is_store_1 : std_logic;
    signal cmt_arf_1, cmt_arf_2 : Arf_Tag;
    signal cmt_rrf_1, cmt_rrf_2 : Reg_Tag;
    signal cmt_val_1, cmt_val_2 : Data_Bus;
    signal lsq_mem_req, lsq_mem_rw, sb_mem_req, sb_mem_rw, dmem_req, dmem_rw, dmem_ack, snoop_hit : std_logic;
    signal lsq_mem_addr, lsq_mem_wdata, sb_mem_addr, sb_mem_wdata, dmem_addr, dmem_wdata, dmem_rdata, snoop_data : Data_Bus;
    
    -- NEW: Dedicated Branch Predictor Training Signals
    signal bp_train_en, bp_train_taken : std_logic;
    signal bp_train_pc, bp_train_target : Data_Bus;

begin
    ccr_val_16bit <= "00000000000000" & ccr_val_2bit;
    decode_stall_in <= rr_stall_out or router_stall_out;
    rr_busy_q1_1 <= '0' when rr_q1_1 = "0000" else '1'; rr_busy_q2_1 <= '0' when rr_q2_1 = "0000" else '1'; rr_busy_q3_1 <= '0' when rr_q3_1 = "0000" else '1';
    rr_busy_q1_2 <= '0' when rr_q1_2 = "0000" else '1'; rr_busy_q2_2 <= '0' when rr_q2_2 = "0000" else '1'; rr_busy_q3_2 <= '0' when rr_q3_2 = "0000" else '1';
    
    br_disp_en  <= branch_en_1 or branch_en_2;
    br_bundle   <= rr_b_1 when branch_en_1 = '1' else rr_b_2;
    br_dest_tag <= rr_dest_1 when branch_en_1 = '1' else rr_dest_2;
    br_rob_tag  <= rob_tag_1 when branch_en_1 = '1' else rob_tag_2;
    br_q1       <= rr_q1_1 when branch_en_1 = '1' else rr_q1_2;
    br_q2       <= rr_q2_1 when branch_en_1 = '1' else rr_q2_2;
    br_v1       <= v1_1 when branch_en_1 = '1' else v1_2; br_v2 <= v2_1 when branch_en_1 = '1' else v2_2;
    br_v1_val   <= v1_val_1 when branch_en_1 = '1' else v1_val_2; br_v2_val <= v2_val_1 when branch_en_1 = '1' else v2_val_2;

    dmem_req   <= lsq_mem_req or sb_mem_req; dmem_rw <= lsq_mem_rw when lsq_mem_req = '1' else sb_mem_rw;
    dmem_addr  <= lsq_mem_addr when lsq_mem_req = '1' else sb_mem_addr; dmem_wdata <= lsq_mem_wdata when lsq_mem_req = '1' else sb_mem_wdata;
    commit_is_store_1 <= '1' when cmt_op_1 = "0101" else '0';

    Inst_IMEM: entity work.IMEM port map ( clk => clk, imem_pc => imem_pc, imem_instr_32 => imem_instr_32, imem_valid => imem_valid );
    
    Inst_Fetch: entity work.Fetch_Unit port map ( 
        clk => clk, rst => rst, stall => mf_stall, flush_pipeline => flush_pipeline, recovery_pc => recovery_pc, 
        bp_update_en => bp_train_en, bp_update_pc => bp_train_pc, bp_update_taken => bp_train_taken, bp_update_target => bp_train_target, 
        imem_pc => imem_pc, imem_instr_32 => imem_instr_32, imem_valid => imem_valid, 
        fetch_valid_1 => f_v_1, fetch_pc_1 => f_pc_1, fetch_instr_1 => f_in_1, 
        fetch_valid_2 => f_v_2, fetch_pc_2 => f_pc_2, fetch_instr_2 => f_in_2 
    );
    
    Inst_MF_Seq: entity work.MF_Sequencer port map ( clk => clk, rst => rst, fetch_valid_1 => f_v_1, fetch_pc_1 => f_pc_1, instr_pr1_1 => f_in_1, fetch_valid_2 => f_v_2, fetch_pc_2 => f_pc_2, instr_pr1_2 => f_in_2, gen_valid_1 => mf_v_1, gen_pc_1 => mf_pc_1, gen_instr_1 => mf_in_1, gen_valid_2 => mf_v_2, gen_pc_2 => mf_pc_2, gen_instr_2 => mf_in_2, freeze_fetch => mf_stall, a => mf_a_flag, flag_mem_op_1 => mf_flg_1, flag_mem_op_2 => mf_flg_2 );
    Inst_Decode: entity work.Decode_Unit port map ( clk => clk, rst => rst, gen_valid_1 => mf_v_1, gen_pc_1 => mf_pc_1, gen_instr_1 => mf_in_1, flag_mem_op_1 => mf_flg_1, gen_valid_2 => mf_v_2, gen_pc_2 => mf_pc_2, gen_instr_2 => mf_in_2, flag_mem_op_2 => mf_flg_2, a_flag_in => mf_a_flag, stall_in => decode_stall_in, flush_pipeline => flush_pipeline, stall_out => open, decode_valid_1 => dec_v_1, bundle_1_out => dec_b_1, decode_valid_2 => dec_v_2, bundle_2_out => dec_b_2 );
    Inst_RR_Unit: entity work.RR_Unit port map ( clk => clk, rst => rst, decode_valid_1 => dec_v_1, bundle_1_in => dec_b_1, decode_valid_2 => dec_v_2, bundle_2_in => dec_b_2, flush_pipeline => flush_pipeline, commit_en_1 => cmt_en_1, commit_rrf_1 => cmt_rrf_1, commit_en_2 => cmt_en_2, commit_rrf_2 => cmt_rrf_2, disp_en_1 => rr_en_1, bundle_1_out => rr_b_1, dest_tag_1 => rr_dest_1, src1_tag_1 => rr_q1_1, src2_tag_1 => rr_q2_1, src3_tag_1 => rr_q3_1, disp_en_2 => rr_en_2, bundle_2_out => rr_b_2, dest_tag_2 => rr_dest_2, src1_tag_2 => rr_q1_2, src2_tag_2 => rr_q2_2, src3_tag_2 => rr_q3_2, stall_front_end => rr_stall_out );
    Inst_Reg_File: entity work.Register_File_Array port map ( clk => clk, rst => rst, pc_1 => rr_b_1.PC, src1_arf_1 => rr_b_1.Src1_ARF, src1_rrf_1 => rr_q1_1, src1_busy_1 => rr_busy_q1_1, src2_arf_1 => rr_b_1.Src2_ARF, src2_rrf_1 => rr_q2_1, src2_busy_1 => rr_busy_q2_1, src3_arf_1 => rr_b_1.Src3_ARF, src3_rrf_1 => rr_q3_1, src3_busy_1 => rr_busy_q3_1, dest_rrf_1 => rr_dest_1, alloc_en_1 => rr_en_1, pc_2 => rr_b_2.PC, src1_arf_2 => rr_b_2.Src1_ARF, src1_rrf_2 => rr_q1_2, src1_busy_2 => rr_busy_q1_2, src2_arf_2 => rr_b_2.Src2_ARF, src2_rrf_2 => rr_q2_2, src2_busy_2 => rr_busy_q2_2, src3_arf_2 => rr_b_2.Src3_ARF, src3_rrf_2 => rr_q3_2, src3_busy_2 => rr_busy_q3_2, dest_rrf_2 => rr_dest_2, alloc_en_2 => rr_en_2, cdb_valid_1 => cdb1_valid, cdb_tag_1 => cdb1_tag, cdb_val_1 => cdb1_val, cdb_valid_2 => cdb2_valid, cdb_tag_2 => cdb2_tag, cdb_val_2 => cdb2_val, commit_en_1 => cmt_en_1, commit_arf_1 => cmt_arf_1, commit_val_1 => cmt_val_1, commit_en_2 => cmt_en_2, commit_arf_2 => cmt_arf_2, commit_val_2 => cmt_val_2, v1_val_1 => v1_val_1, v1_1 => v1_1, v2_val_1 => v2_val_1, v2_1 => v2_1, v3_val_1 => v3_val_1, v3_1 => v3_1, v1_val_2 => v1_val_2, v1_2 => v1_2, v2_val_2 => v2_val_2, v2_2 => v2_2, v3_val_2 => v3_val_2, v3_2 => v3_2 );
    Inst_Dispatch: entity work.Dispatch_Router port map ( rr_en_1 => rr_en_1, rr_bundle_1 => rr_b_1, rr_dest_tag_1 => rr_dest_1, rr_q1_1 => rr_q1_1, rr_q2_1 => rr_q2_1, rr_en_2 => rr_en_2, rr_bundle_2 => rr_b_2, rr_dest_tag_2 => rr_dest_2, rr_q1_2 => rr_q1_2, rr_q2_2 => rr_q2_2, rr_q3_ccr_1 => "0000", rr_q3_ccr_2 => "0000", rob_full => rob_full, alu_rs_full => '0', branch_rs_full => '0', lsq_full => '0', scheduler_stall => router_stall_out, alu_en_1 => alu_en_1, alu_en_2 => alu_en_2, branch_en_1 => branch_en_1, branch_en_2 => branch_en_2, lsq_en_1 => lsq_en_1, lsq_en_2 => lsq_en_2 );
    Inst_CCR_Tracker: entity work.CCR_Tracker port map ( clk => clk, rst => rst, flush_pipeline => flush_pipeline, disp_en_1 => rr_en_1, op_1 => rr_b_1.Opcode, tag_1 => rr_dest_1, disp_en_2 => rr_en_2, op_2 => rr_b_2.Opcode, tag_2 => rr_dest_2, cdb1_valid => cdb1_valid, cdb1_tag => cdb1_tag, cdb1_flags => cdb1_flags, cdb1_mask => cdb1_mask, cdb2_valid => cdb2_valid, cdb2_tag => cdb2_tag, cdb2_flags => cdb2_flags, cdb2_mask => cdb2_mask, commit_en_1 => cmt_en_1, cmt_tag_1 => cmt_rrf_1, cmt_flags_1 => cmt_flg_1, cmt_mask_1 => cmt_mask_1, commit_en_2 => cmt_en_2, cmt_tag_2 => cmt_rrf_2, cmt_flags_2 => cmt_flg_2, cmt_mask_2 => cmt_mask_2, ccr_valid => ccr_valid, ccr_val => ccr_val_2bit, ccr_tag_out => ccr_tag_out );
    Inst_ALU_RS: entity work.ALU_RS port map ( clk => clk, rst => rst, exec_stall => alu_exec_stall, disp_en_1 => alu_en_1, disp_en_2 => alu_en_2, bundle_1 => rr_b_1, bundle_2 => rr_b_2, rob_tag_1 => rob_tag_1, dest_tag_1 => rr_dest_1, rob_tag_2 => rob_tag_2, dest_tag_2 => rr_dest_2, q1_1 => rr_q1_1, q2_1 => rr_q2_1, q3_1 => rr_q3_1, qc_1 => ccr_tag_out, v1_val_1 => v1_val_1, v2_val_1 => v2_val_1, v3_val_1 => v3_val_1, vc_val_1 => ccr_valid, v1_1 => v1_1, v2_1 => v2_1, v3_1 => v3_1, vc_1 => ccr_val_16bit, q1_2 => rr_q1_2, q2_2 => rr_q2_2, q3_2 => rr_q3_2, qc_2 => ccr_tag_out, v1_val_2 => v1_val_2, v2_val_2 => v2_val_2, v3_val_2 => v3_val_2, vc_val_2 => ccr_valid, v1_2 => v1_2, v2_2 => v2_2, v3_2 => v3_2, vc_2 => ccr_val_16bit, cdb_v1 => cdb1_valid, cdb_t1 => cdb1_tag, cdb_val1 => cdb1_val, cdb_f1 => cdb1_flags, cdb_v2 => cdb2_valid, cdb_t2 => cdb2_tag, cdb_val2 => cdb2_val, cdb_f2 => cdb2_flags, issue_v => alu_iss_v, issue_op => alu_iss_op, issue_16 => alu_iss_16, issue_v1 => alu_iss_v1, issue_v2 => alu_iss_v2, issue_v3 => alu_iss_v3, issue_c => alu_iss_c, issue_imm => alu_iss_imm, issue_dest => alu_iss_dest, issue_rob => alu_iss_rob );
    Inst_ALU_Exec: entity work.ALU_Exec port map ( clk => clk, rst => rst, issue_valid => alu_iss_v, issue_opcode => alu_iss_op, issue_16 => alu_iss_16, issue_v1 => alu_iss_v1, issue_v2 => alu_iss_v2, issue_v3 => alu_iss_v3, issue_c => alu_iss_c, issue_imm => alu_iss_imm, issue_dest_tag => alu_iss_dest, issue_rob_tag => alu_iss_rob, hold => alu_hold, exec_stall => alu_exec_stall, alu_req => alu_req, alu_tag => alu_tag, alu_val => alu_val, alu_rob => alu_rob, alu_flags => alu_flags, alu_mask => alu_mask );
    Inst_Branch_RS: entity work.Branch_RS port map ( clk => clk, rst => rst, disp_en => br_disp_en, bundle => br_bundle, disp_rob_tag => br_rob_tag, dest_tag => br_dest_tag, q1 => br_q1, v1_val => br_v1_val, v1 => br_v1, q2 => br_q2, v2_val => br_v2_val, v2 => br_v2, q3_ccr => "0000", v3_val => '1', v3_ccr => x"0000", cdb_valid_1 => cdb1_valid, cdb_tag_1 => cdb1_tag, cdb_val_1 => cdb1_val, cdb_valid_2 => cdb2_valid, cdb_tag_2 => cdb2_tag, cdb_val_2 => cdb2_val, ccr_cdb_valid => '0', ccr_cdb_tag => "0000", ccr_cdb_val => x"0000", issue_valid => br_iss_v, issue_opcode => br_iss_op, issue_pc => br_iss_pc, issue_v1 => br_iss_v1, issue_v2 => br_iss_v2, issue_ccr => br_iss_ccr, issue_imm => br_iss_imm, issue_dest_tag => br_iss_dest, issue_rob_tag => br_iss_rob );
    Inst_Branch_Exec: entity work.Branch_Exec port map ( clk => clk, rst => rst, issue_valid => br_iss_v, issue_opcode => br_iss_op, issue_pc => br_iss_pc, issue_v1 => br_iss_v1, issue_v2 => br_iss_v2, issue_ccr => br_iss_ccr, issue_imm => br_iss_imm, issue_dest_tag => br_iss_dest, issue_rob_tag => br_iss_rob, cdb_valid => br_req, cdb_tag => br_tag, cdb_val => br_val, cdb_rob_tag => br_rob, cdb_actual_pc => br_act_pc );
    Inst_LSQ: entity work.LSQ port map ( clk => clk, rst => rst, disp_en => lsq_en_1, bundle => rr_b_1, disp_rob_tag => rob_tag_1, dest_tag => rr_dest_1, q_base => rr_q1_1, v_base_val => v1_val_1, v_base => v1_1, q_data => rr_q2_1, v_data_val => v2_val_1, v_data => v2_1, cdb_valid_1 => cdb1_valid, cdb_tag_1 => cdb1_tag, cdb_val_1 => cdb1_val, cdb_valid_2 => cdb2_valid, cdb_tag_2 => cdb2_tag, cdb_val_2 => cdb2_val, mem_req => lsq_mem_req, mem_rw => lsq_mem_rw, mem_addr => lsq_mem_addr, mem_wdata => lsq_mem_wdata, mem_ack => dmem_ack, lsq_wb_valid => lsq_req, lsq_wb_val => lsq_val, lsq_wb_dest_tag => lsq_tag, lsq_wb_rob_tag => lsq_rob );
    Inst_Store_Buffer: entity work.Store_Buffer port map ( clk => clk, rst => rst, commit_valid => cmt_en_1, commit_is_store => commit_is_store_1, commit_addr => cmt_val_1, commit_data => cmt_val_1, snoop_addr => lsq_mem_addr, snoop_hit => snoop_hit, snoop_data => snoop_data, dmem_req => sb_mem_req, dmem_rw => sb_mem_rw, dmem_addr => sb_mem_addr, dmem_wdata => sb_mem_wdata, dmem_ack => dmem_ack );
    Inst_DMEM: entity work.DMEM port map ( clk => clk, mem_req => dmem_req, mem_rw => dmem_rw, mem_addr => dmem_addr, mem_wdata => dmem_wdata, mem_rdata => dmem_rdata, mem_ack => dmem_ack );
    Inst_CDB_Arbiter: entity work.CDB_Arbiter port map ( branch_req => br_req, branch_tag => br_tag, branch_val => br_val, branch_rob => br_rob, branch_act_pc => br_act_pc, lsq_req => lsq_req, lsq_tag => lsq_tag, lsq_val => lsq_val, lsq_rob => lsq_rob, alu_req => alu_req, alu_tag => alu_tag, alu_val => alu_val, alu_rob => alu_rob, alu_flags => alu_flags, alu_mask => alu_mask, branch_hold => br_hold, lsq_hold => lsq_hold, alu_hold => alu_hold, cdb1_valid => cdb1_valid, cdb1_tag => cdb1_tag, cdb1_val => cdb1_val, cdb1_rob => cdb1_rob, cdb1_act_pc => cdb1_act_pc, cdb1_flags => cdb1_flags, cdb1_mask => cdb1_mask, cdb2_valid => cdb2_valid, cdb2_tag => cdb2_tag, cdb2_val => cdb2_val, cdb2_rob => cdb2_rob, cdb2_act_pc => cdb2_act_pc, cdb2_flags => cdb2_flags, cdb2_mask => cdb2_mask );
    
    Inst_ROB: entity work.ROB port map (
        clk => clk, rst => rst, next_alloc_1 => rob_tag_1, next_alloc_2 => rob_tag_2, rob_full => rob_full,
        disp_en_1 => rr_en_1, bundle_1 => rr_b_1, dest_tag_1 => rr_dest_1, is_micro_op_1 => rr_b_1.Is_Micro_Op,
        disp_en_2 => rr_en_2, bundle_2 => rr_b_2, dest_tag_2 => rr_dest_2, is_micro_op_2 => rr_b_2.Is_Micro_Op,
        cdb1_valid => cdb1_valid, cdb1_rob_tag => cdb1_rob, cdb1_val => cdb1_val, cdb1_act_pc => cdb1_act_pc, cdb1_flags => cdb1_flags, cdb1_mask => cdb1_mask,
        cdb2_valid => cdb2_valid, cdb2_rob_tag => cdb2_rob, cdb2_val => cdb2_val, cdb2_act_pc => cdb2_act_pc, cdb2_flags => cdb2_flags, cdb2_mask => cdb2_mask,
        commit_en_1 => cmt_en_1, commit_opcode_1 => cmt_op_1, commit_rob_tag_1 => open, commit_arf_1 => cmt_arf_1, commit_rrf_1 => cmt_rrf_1, commit_val_1 => cmt_val_1, commit_flags_1 => cmt_flg_1, commit_mask_1 => cmt_mask_1,
        commit_en_2 => cmt_en_2, commit_opcode_2 => cmt_op_2, commit_rob_tag_2 => open, commit_arf_2 => cmt_arf_2, commit_rrf_2 => cmt_rrf_2, commit_val_2 => cmt_val_2, commit_flags_2 => cmt_flg_2, commit_mask_2 => cmt_mask_2,
        flush_pipeline => flush_pipeline, recovery_pc => recovery_pc,
        bp_train_en => bp_train_en, bp_train_pc => bp_train_pc, bp_train_target => bp_train_target, bp_train_taken => bp_train_taken
    );

    -- ==========================================
    -- NEW: Observation / Debug Signal Routing
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
    
    dbg_dmem_req       <= dmem_req;
    dbg_dmem_rw        <= dmem_rw;
    dbg_dmem_addr      <= dmem_addr;
    dbg_dmem_wdata     <= dmem_wdata;

end Structural;