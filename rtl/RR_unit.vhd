library IEEE; use IEEE.STD_LOGIC_1164.ALL; use IEEE.NUMERIC_STD.ALL; use work.RISC_Types_Pkg.ALL;
-- =====================================================================
-- Register Rename unit (RAT + free list of 15 physical tags, 0000 = none)
--
-- Changes over the original version:
--   * RAT busy bit is cleared when the instruction that owns the mapping
--     commits.  Before, a register stayed "busy" forever and later readers
--     kept reading a physical register that had been freed and reused.
--   * stall_front_end is combinational.  It used to be a register, so the
--     decode stage advanced one bundle past the stall and that bundle was lost.
--     The old condition also missed the case where only slot 2 needs a tag.
--   * hold: when the back end cannot accept a bundle the renamed outputs are
--     kept as they are (commits still return tags to the free list).
--   * Every flag producer gets a physical tag, including ones whose register
--     result is discarded (destination R0) and the LMF flag micro-op.  The CCR
--     tracker follows the youngest producer by tag; with tag 0000 it matched
--     unrelated broadcasts (stores, branches) and consumers got stale flags.
-- =====================================================================
entity RR_Unit is
    Port ( clk, rst, decode_valid_1, decode_valid_2, flush_pipeline, commit_en_1, commit_en_2 : in std_logic;
        hold : in std_logic;
        bundle_1_in, bundle_2_in : in Instr_Bundle; commit_rrf_1, commit_rrf_2 : in Reg_Tag;
        commit_arf_1, commit_arf_2 : in Arf_Tag;
        disp_en_1, disp_en_2, stall_front_end : out std_logic; bundle_1_out, bundle_2_out : out Instr_Bundle;
        dest_tag_1, src1_tag_1, src2_tag_1, src3_tag_1, dest_tag_2, src1_tag_2, src2_tag_2, src3_tag_2 : out Reg_Tag
    );
end RR_Unit;
architecture Behavioral of RR_Unit is
    type RAT_Entry is record Busy : std_logic; Tag : Reg_Tag; end record;
    type RAT_Array is array(0 to 7) of RAT_Entry; signal rat_table : RAT_Array;
    type Free_List_Array is array(0 to 14) of Reg_Tag; signal free_list : Free_List_Array; -- 15 Entries (0000 is NULL)
    signal fl_head, fl_tail : integer range 0 to 14; signal fl_count : integer range 0 to 15;
    signal rename_stall : std_logic;

    function gets_dest(op: std_logic_vector(3 downto 0); ccr: std_logic; dest: Arf_Tag) return boolean is begin
        -- Every flag producer gets a tag, even with destination R0 (e.g. NOP = ADA R0,R0,R0)
        -- or no register at all (LMF flag load): the CCR tracker follows producers by tag.
        if writes_ccr(op, ccr) then return true; end if;
        if op="0101" or op(3 downto 2)="10" or op="1111" or ccr='1' or dest="000" then return false; else return true; end if;
    end function;

    function lookup(r : RAT_Array; a : Arf_Tag) return Reg_Tag is begin
        if a = "000" then return "0000"; end if;
        if r(to_integer(unsigned(a))).Busy = '1' then return r(to_integer(unsigned(a))).Tag; end if;
        return "0000";
    end function;
begin
    process(decode_valid_1, decode_valid_2, bundle_1_in, bundle_2_in, fl_count)
        variable n1, n2 : boolean;
    begin
        n1 := decode_valid_1 = '1' and gets_dest(bundle_1_in.Opcode, bundle_1_in.Is_CCR_Mem, bundle_1_in.Dest_ARF);
        n2 := decode_valid_2 = '1' and gets_dest(bundle_2_in.Opcode, bundle_2_in.Is_CCR_Mem, bundle_2_in.Dest_ARF);
        if (n1 and n2 and fl_count < 2) or ((n1 or n2) and fl_count < 1) then rename_stall <= '1'; else rename_stall <= '0'; end if;
    end process;
    stall_front_end <= rename_stall;

    process(clk)
        variable nh, nt: integer range 0 to 14; variable nc: integer range 0 to 15; variable vfl: Free_List_Array;
        variable n1, n2: boolean; variable a1, a2, q11, q21, q31, q12, q22, q32: Reg_Tag;
    begin
        if rising_edge(clk) then
            if rst='1' or flush_pipeline='1' then
                for i in 0 to 7 loop rat_table(i).Busy<='0'; end loop; for i in 0 to 14 loop free_list(i)<=std_logic_vector(to_unsigned(i+1,4)); end loop;
                fl_head<=0; fl_tail<=0; fl_count<=15; disp_en_1<='0'; disp_en_2<='0';
            else
                nh:=fl_head; nt:=fl_tail; nc:=fl_count; vfl:=free_list;

                -- Commit: return the tag and, if the RAT still points at it, release the mapping
                if commit_en_1='1' and commit_rrf_1/="0000" then
                    vfl(nt):=commit_rrf_1; nt:=(nt+1) mod 15; nc:=nc+1;
                    if commit_arf_1/="000" and rat_table(to_integer(unsigned(commit_arf_1))).Tag=commit_rrf_1 then
                        rat_table(to_integer(unsigned(commit_arf_1))).Busy<='0';
                    end if;
                end if;
                if commit_en_2='1' and commit_rrf_2/="0000" then
                    vfl(nt):=commit_rrf_2; nt:=(nt+1) mod 15; nc:=nc+1;
                    if commit_arf_2/="000" and rat_table(to_integer(unsigned(commit_arf_2))).Tag=commit_rrf_2 then
                        rat_table(to_integer(unsigned(commit_arf_2))).Busy<='0';
                    end if;
                end if;

                if hold='1' then
                    null;                                    -- keep the bundle on the outputs
                elsif rename_stall='1' then
                    disp_en_1<='0'; disp_en_2<='0';          -- bubble; decode holds its bundle
                else
                    n1 := decode_valid_1='1' and gets_dest(bundle_1_in.Opcode, bundle_1_in.Is_CCR_Mem, bundle_1_in.Dest_ARF);
                    n2 := decode_valid_2='1' and gets_dest(bundle_2_in.Opcode, bundle_2_in.Is_CCR_Mem, bundle_2_in.Dest_ARF);
                    a1 := "0000";
                    if decode_valid_1='1' then
                        disp_en_1<='1'; bundle_1_out<=bundle_1_in;
                        q11 := lookup(rat_table, bundle_1_in.Src1_ARF);
                        q21 := lookup(rat_table, bundle_1_in.Src2_ARF);
                        q31 := lookup(rat_table, bundle_1_in.Src3_ARF);
                        src1_tag_1<=q11; src2_tag_1<=q21; src3_tag_1<=q31;
                        if n1 then
                            a1:=vfl(nh); nh:=(nh+1) mod 15; nc:=nc-1; dest_tag_1<=a1;
                            if bundle_1_in.Dest_ARF/="000" then
                                rat_table(to_integer(unsigned(bundle_1_in.Dest_ARF))).Busy<='1'; rat_table(to_integer(unsigned(bundle_1_in.Dest_ARF))).Tag<=a1;
                            end if;
                        else dest_tag_1<="0000"; end if;
                    else disp_en_1<='0'; end if;

                    if decode_valid_2='1' then
                        disp_en_2<='1'; bundle_2_out<=bundle_2_in;
                        -- 0-cycle intra-bundle RAW forwarding
                        if decode_valid_1='1' and n1 and bundle_1_in.Dest_ARF/="000" and bundle_2_in.Src1_ARF=bundle_1_in.Dest_ARF then q12:=a1; else q12:=lookup(rat_table, bundle_2_in.Src1_ARF); end if;
                        if decode_valid_1='1' and n1 and bundle_1_in.Dest_ARF/="000" and bundle_2_in.Src2_ARF=bundle_1_in.Dest_ARF then q22:=a1; else q22:=lookup(rat_table, bundle_2_in.Src2_ARF); end if;
                        if decode_valid_1='1' and n1 and bundle_1_in.Dest_ARF/="000" and bundle_2_in.Src3_ARF=bundle_1_in.Dest_ARF then q32:=a1; else q32:=lookup(rat_table, bundle_2_in.Src3_ARF); end if;
                        src1_tag_2<=q12; src2_tag_2<=q22; src3_tag_2<=q32;
                        if n2 then
                            a2:=vfl(nh); nh:=(nh+1) mod 15; nc:=nc-1; dest_tag_2<=a2;
                            if bundle_2_in.Dest_ARF/="000" then
                                rat_table(to_integer(unsigned(bundle_2_in.Dest_ARF))).Busy<='1'; rat_table(to_integer(unsigned(bundle_2_in.Dest_ARF))).Tag<=a2;
                            end if;
                        else dest_tag_2<="0000"; end if;
                    else disp_en_2<='0'; end if;
                end if;
                fl_head<=nh; fl_tail<=nt; fl_count<=nc; free_list<=vfl;
            end if;
        end if;
    end process;
end Behavioral;
