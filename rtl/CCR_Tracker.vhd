library IEEE; use IEEE.STD_LOGIC_1164.ALL; use IEEE.NUMERIC_STD.ALL; use work.RISC_Types_Pkg.ALL;
entity CCR_Tracker is
    Port ( clk, rst, flush_pipeline : in std_logic;
        -- Dispatch Snooping
        disp_en_1 : in std_logic; op_1 : in std_logic_vector(3 downto 0); tag_1 : in Reg_Tag;
        disp_en_2 : in std_logic; op_2 : in std_logic_vector(3 downto 0); tag_2 : in Reg_Tag;
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
begin
    ccr_tag_out <= curr_tag; ccr_val <= spec_c & spec_z;
    ccr_valid <= '1' when in_flight = '0' else '0';
    process(clk) begin
        if rising_edge(clk) then
            if rst='1' then arf_c<='0'; arf_z<='0'; spec_c<='0'; spec_z<='0'; in_flight<='0'; curr_tag<="0000";
            elsif flush_pipeline='1' then spec_c<=arf_c; spec_z<=arf_z; in_flight<='0';
            else
                if cdb1_valid='1' and cdb1_tag=curr_tag then 
                    if cdb1_mask(1)='1' then spec_c<=cdb1_flags(1); end if; if cdb1_mask(0)='1' then spec_z<=cdb1_flags(0); end if; in_flight<='0';
                elsif cdb2_valid='1' and cdb2_tag=curr_tag then 
                    if cdb2_mask(1)='1' then spec_c<=cdb2_flags(1); end if; if cdb2_mask(0)='1' then spec_z<=cdb2_flags(0); end if; in_flight<='0';
                end if;
                
                if commit_en_1='1' then if cmt_mask_1(1)='1' then arf_c<=cmt_flags_1(1); end if; if cmt_mask_1(0)='1' then arf_z<=cmt_flags_1(0); end if; end if;
                if commit_en_2='1' then if cmt_mask_2(1)='1' then arf_c<=cmt_flags_2(1); end if; if cmt_mask_2(0)='1' then arf_z<=cmt_flags_2(0); end if; end if;

                if disp_en_2='1' and (op_2="0001" or op_2="0010" or op_2="0000" or op_2="0100") then curr_tag<=tag_2; in_flight<='1';
                elsif disp_en_1='1' and (op_1="0001" or op_1="0010" or op_1="0000" or op_1="0100") then curr_tag<=tag_1; in_flight<='1'; end if;
            end if;
        end if;
    end process;
end Behavioral;