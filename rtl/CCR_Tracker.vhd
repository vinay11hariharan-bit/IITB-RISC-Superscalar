library IEEE; use IEEE.STD_LOGIC_1164.ALL; use IEEE.NUMERIC_STD.ALL; use work.RISC_Types_Pkg.ALL;
-- =====================================================================
-- CCR tracker: speculative C/Z flags and the tag of the youngest in-flight
-- flag producer.
--
-- Changes over the original version:
--   * Producers are ADD/ADI/NAND and the LMF flag micro-op (writes_ccr()).
--     A plain LW no longer counts as a producer: it does not write flags.
--   * The youngest producer's broadcast flags replace the speculative C,Z
--     (they used to be merged by write mask, which lost older producers).
--   * ccr_valid / ccr_val bypass a CDB broadcast of the tracked tag in the
--     same cycle.  Before, an instruction dispatched in that cycle took the tag,
--     the broadcast went past, and the consumer waited forever.
-- =====================================================================
entity CCR_Tracker is
    Port ( clk, rst, flush_pipeline : in std_logic;
        -- Dispatch Snooping
        disp_en_1 : in std_logic; op_1 : in std_logic_vector(3 downto 0); tag_1 : in Reg_Tag; ccr_mem_1 : in std_logic;
        disp_en_2 : in std_logic; op_2 : in std_logic_vector(3 downto 0); tag_2 : in Reg_Tag; ccr_mem_2 : in std_logic;
        -- CDB Snooping
        cdb1_valid: in std_logic; cdb1_tag: in Reg_Tag; cdb1_flags, cdb1_mask : in std_logic_vector(1 downto 0);
        cdb2_valid: in std_logic; cdb2_tag: in Reg_Tag; cdb2_flags, cdb2_mask : in std_logic_vector(1 downto 0);
        commit_en_1 : in std_logic; cmt_tag_1 : in Reg_Tag; cmt_flags_1, cmt_mask_1 : in std_logic_vector(1 downto 0);
        commit_en_2 : in std_logic; cmt_tag_2 : in Reg_Tag; cmt_flags_2, cmt_mask_2 : in std_logic_vector(1 downto 0);
        ccr_valid : out std_logic; ccr_val : out std_logic_vector(1 downto 0); ccr_tag_out : out Reg_Tag
    );
end CCR_Tracker;
architecture Behavioral of CCR_Tracker is
    signal arf_c, arf_z, spec_c, spec_z, in_flight : std_logic := '0';
    signal curr_tag : Reg_Tag := "0000";
    signal hit1, hit2 : std_logic;
    signal byp_c, byp_z : std_logic;   -- spec flags with this cycle's broadcast merged in
begin
    hit1 <= '1' when in_flight='1' and cdb1_valid='1' and cdb1_tag=curr_tag else '0';
    hit2 <= '1' when in_flight='1' and hit1='0' and cdb2_valid='1' and cdb2_tag=curr_tag else '0';
    -- A producer's broadcast flags are the complete C,Z after that instruction
    -- (the ALU passes through the bits it does not write), so they replace the
    -- speculative value outright.  Merging by mask would lose older producers
    -- that were skipped because a younger one was already being tracked.
    byp_c <= cdb1_flags(1) when hit1='1' else cdb2_flags(1) when hit2='1' else spec_c;
    byp_z <= cdb1_flags(0) when hit1='1' else cdb2_flags(0) when hit2='1' else spec_z;

    ccr_tag_out <= curr_tag; ccr_val <= byp_c & byp_z;
    ccr_valid <= '1' when in_flight = '0' or hit1 = '1' or hit2 = '1' else '0';

    process(clk) begin
        if rising_edge(clk) then
            if rst='1' then arf_c<='0'; arf_z<='0'; spec_c<='0'; spec_z<='0'; in_flight<='0'; curr_tag<="0000";
            elsif flush_pipeline='1' then spec_c<=arf_c; spec_z<=arf_z; in_flight<='0';
            else
                if hit1='1' or hit2='1' then spec_c<=byp_c; spec_z<=byp_z; in_flight<='0'; end if;

                if commit_en_1='1' then if cmt_mask_1(1)='1' then arf_c<=cmt_flags_1(1); end if; if cmt_mask_1(0)='1' then arf_z<=cmt_flags_1(0); end if; end if;
                if commit_en_2='1' then if cmt_mask_2(1)='1' then arf_c<=cmt_flags_2(1); end if; if cmt_mask_2(0)='1' then arf_z<=cmt_flags_2(0); end if; end if;

                if disp_en_2='1' and writes_ccr(op_2, ccr_mem_2) then curr_tag<=tag_2; in_flight<='1';
                elsif disp_en_1='1' and writes_ccr(op_1, ccr_mem_1) then curr_tag<=tag_1; in_flight<='1'; end if;
            end if;
        end if;
    end process;
end Behavioral;
