library IEEE; use IEEE.STD_LOGIC_1164.ALL; use IEEE.NUMERIC_STD.ALL; use work.RISC_Types_Pkg.ALL;
entity RR_Unit is
    Port ( clk, rst, decode_valid_1, decode_valid_2, flush_pipeline, commit_en_1, commit_en_2 : in std_logic;
        bundle_1_in, bundle_2_in : in Instr_Bundle; commit_rrf_1, commit_rrf_2 : in Reg_Tag;
        disp_en_1, disp_en_2, stall_front_end : out std_logic; bundle_1_out, bundle_2_out : out Instr_Bundle;
        dest_tag_1, src1_tag_1, src2_tag_1, src3_tag_1, dest_tag_2, src1_tag_2, src2_tag_2, src3_tag_2 : out Reg_Tag
    );
end RR_Unit;
architecture Behavioral of RR_Unit is
    type RAT_Entry is record Busy : std_logic; Tag : Reg_Tag; end record;
    type RAT_Array is array(0 to 7) of RAT_Entry; signal rat_table : RAT_Array;
    type Free_List_Array is array(0 to 14) of Reg_Tag; signal free_list : Free_List_Array; -- 15 Entries (0000 is NULL)
    signal fl_head, fl_tail : integer range 0 to 14; signal fl_count : integer range 0 to 15;
    function gets_dest(op: std_logic_vector(3 downto 0); ccr: std_logic; dest: Arf_Tag) return boolean is begin
        if op="0101" or op(3 downto 2)="10" or op="1111" or ccr='1' or dest="000" then return false; else return true; end if;
    end function;
begin
    process(clk)
        variable nh, nt: integer range 0 to 14; variable nc: integer range 0 to 15; variable vfl: Free_List_Array;
        variable n1, n2: boolean; variable a1, a2, q11, q21, q31, q12, q22, q32: Reg_Tag;
    begin
        if rising_edge(clk) then
            if rst='1' or flush_pipeline='1' then
                for i in 0 to 7 loop rat_table(i).Busy<='0'; end loop; for i in 0 to 14 loop free_list(i)<=std_logic_vector(to_unsigned(i+1,4)); end loop;
                fl_head<=0; fl_tail<=0; fl_count<=15; disp_en_1<='0'; disp_en_2<='0'; stall_front_end<='0';
            else
                nh:=fl_head; nt:=fl_tail; nc:=fl_count; vfl:=free_list;
                if commit_en_1='1' and commit_rrf_1/="0000" then vfl(nt):=commit_rrf_1; nt:=(nt+1) mod 15; nc:=nc+1; end if;
                if commit_en_2='1' and commit_rrf_2/="0000" then vfl(nt):=commit_rrf_2; nt:=(nt+1) mod 15; nc:=nc+1; end if;
                n1 := false; n2 := false;
                if decode_valid_1='1' and gets_dest(bundle_1_in.Opcode, bundle_1_in.Is_CCR_Mem, bundle_1_in.Dest_ARF) then n1:=true; end if;
                if decode_valid_2='1' and gets_dest(bundle_2_in.Opcode, bundle_2_in.Is_CCR_Mem, bundle_2_in.Dest_ARF) then n2:=true; end if;
                
                if (n1 and n2 and nc<2) or (n1 and nc<1) then stall_front_end<='1'; disp_en_1<='0'; disp_en_2<='0';
                else
                    stall_front_end<='0';
                    if decode_valid_1='1' then
                        disp_en_1<='1'; bundle_1_out<=bundle_1_in;
                        if bundle_1_in.Src1_ARF="000" then q11:="0000"; elsif rat_table(to_integer(unsigned(bundle_1_in.Src1_ARF))).Busy='1' then q11:=rat_table(to_integer(unsigned(bundle_1_in.Src1_ARF))).Tag; else q11:="0000"; end if;
                        if bundle_1_in.Src2_ARF="000" then q21:="0000"; elsif rat_table(to_integer(unsigned(bundle_1_in.Src2_ARF))).Busy='1' then q21:=rat_table(to_integer(unsigned(bundle_1_in.Src2_ARF))).Tag; else q21:="0000"; end if;
                        if bundle_1_in.Src3_ARF="000" then q31:="0000"; elsif rat_table(to_integer(unsigned(bundle_1_in.Src3_ARF))).Busy='1' then q31:=rat_table(to_integer(unsigned(bundle_1_in.Src3_ARF))).Tag; else q31:="0000"; end if;
                        src1_tag_1<=q11; src2_tag_1<=q21; src3_tag_1<=q31;
                        if n1 then a1:=vfl(nh); nh:=(nh+1) mod 15; nc:=nc-1; dest_tag_1<=a1; rat_table(to_integer(unsigned(bundle_1_in.Dest_ARF))).Busy<='1'; rat_table(to_integer(unsigned(bundle_1_in.Dest_ARF))).Tag<=a1; else dest_tag_1<="0000"; a1:="0000"; end if;
                    else disp_en_1<='0'; end if;
                    
                    if decode_valid_2='1' then
                        disp_en_2<='1'; bundle_2_out<=bundle_2_in;
                        if decode_valid_1='1' and n1 and bundle_2_in.Src1_ARF=bundle_1_in.Dest_ARF and bundle_1_in.Dest_ARF/="000" then q12:=a1; elsif bundle_2_in.Src1_ARF="000" then q12:="0000"; elsif rat_table(to_integer(unsigned(bundle_2_in.Src1_ARF))).Busy='1' then q12:=rat_table(to_integer(unsigned(bundle_2_in.Src1_ARF))).Tag; else q12:="0000"; end if;
                        if decode_valid_1='1' and n1 and bundle_2_in.Src2_ARF=bundle_1_in.Dest_ARF and bundle_1_in.Dest_ARF/="000" then q22:=a1; elsif bundle_2_in.Src2_ARF="000" then q22:="0000"; elsif rat_table(to_integer(unsigned(bundle_2_in.Src2_ARF))).Busy='1' then q22:=rat_table(to_integer(unsigned(bundle_2_in.Src2_ARF))).Tag; else q22:="0000"; end if;
                        if decode_valid_1='1' and n1 and bundle_2_in.Src3_ARF=bundle_1_in.Dest_ARF and bundle_1_in.Dest_ARF/="000" then q32:=a1; elsif bundle_2_in.Src3_ARF="000" then q32:="0000"; elsif rat_table(to_integer(unsigned(bundle_2_in.Src3_ARF))).Busy='1' then q32:=rat_table(to_integer(unsigned(bundle_2_in.Src3_ARF))).Tag; else q32:="0000"; end if;
                        src1_tag_2<=q12; src2_tag_2<=q22; src3_tag_2<=q32;
                        if n2 then a2:=vfl(nh); nh:=(nh+1) mod 15; nc:=nc-1; dest_tag_2<=a2; rat_table(to_integer(unsigned(bundle_2_in.Dest_ARF))).Busy<='1'; rat_table(to_integer(unsigned(bundle_2_in.Dest_ARF))).Tag<=a2; else dest_tag_2<="0000"; end if;
                    else disp_en_2<='0'; end if;
                end if;
                fl_head<=nh; fl_tail<=nt; fl_count<=nc; free_list<=vfl;
            end if;
        end if;
    end process;
end Behavioral;