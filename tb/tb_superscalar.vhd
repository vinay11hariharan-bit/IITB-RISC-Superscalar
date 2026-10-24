-- =====================================================================
-- System testbench
--
-- Runs a program until it reaches its HALT instruction (JAL R0, 0: a jump
-- to itself), then prints the final architectural state:
--   REG <n> <hex>     R1..R7, built from the ROB commit stream
--   CCR <c> <z>       committed condition codes
--   MEM <word> <hex>  every non-zero DMEM word (after the Store Buffer drained)
--   CYCLES <n>        cycles until HALT was reached
-- tools/run_tests.py compares this against the reference model (tools/iss.py).
--
-- Generics:
--   IMEM_INIT / DMEM_INIT  hex files (see rtl/Mem_Init_Pkg.vhd)
--   HALT_PC                byte address of the HALT instruction
--   MAX_CYCLES             give up after this many cycles (deadlock check)
--   TRACE                  print every commit and DMEM write
-- =====================================================================
library IEEE; use IEEE.STD_LOGIC_1164.ALL; use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;
use work.Mem_Init_Pkg.ALL;

entity tb_superscalar is
    generic (
        IMEM_INIT  : string  := "";
        DMEM_INIT  : string  := "";
        HALT_PC    : integer := -1;
        MAX_CYCLES : integer := 5000;
        TRACE      : boolean := false
    );
end;

architecture sim of tb_superscalar is
    signal clk : std_logic := '0'; signal rst : std_logic := '1';
    signal ipc : Data_Bus; signal iins : std_logic_vector(31 downto 0);
    signal fl, rf, c1, c2, mreq, mrw, lrd, sbe : std_logic;
    signal a1, a2 : Arf_Tag; signal v1, v2, maddr, mwd, laddr : Data_Bus;
    signal done : boolean := false;

    type reg_arr is array (0 to 7) of Data_Bus;
    signal arch : reg_arr := (others => (others => '0'));
begin
    clk <= not clk after 5 ns when not done;

    dut: entity work.iitb_risc_superscalar
        generic map (IMEM_INIT => IMEM_INIT, DMEM_INIT => DMEM_INIT)
        port map (clk => clk, rst => rst,
                  dbg_imem_pc => ipc, dbg_imem_instr => iins, dbg_flush_pipeline => fl, dbg_rob_full => rf,
                  dbg_commit_en_1 => c1, dbg_commit_arf_1 => a1, dbg_commit_val_1 => v1,
                  dbg_commit_en_2 => c2, dbg_commit_arf_2 => a2, dbg_commit_val_2 => v2,
                  dbg_dmem_req => mreq, dbg_dmem_rw => mrw, dbg_dmem_addr => maddr, dbg_dmem_wdata => mwd,
                  dbg_load_rd_en => lrd, dbg_load_rd_addr => laddr, dbg_sb_empty => sbe);

    -- architectural registers = last committed value of each register
    process(clk)
        variable r : reg_arr;
    begin
        if rising_edge(clk) and rst = '0' then
            r := arch;
            if c1 = '1' and a1 /= "000" then r(to_integer(unsigned(a1))) := v1; end if;
            if c2 = '1' and a2 /= "000" then r(to_integer(unsigned(a2))) := v2; end if;
            arch <= r;
            if TRACE then
                if c1 = '1' then report "commit1 R" & integer'image(to_integer(unsigned(a1))) & " = " & to_hstring(v1); end if;
                if c2 = '1' then report "commit2 R" & integer'image(to_integer(unsigned(a2))) & " = " & to_hstring(v2); end if;
                if mreq = '1' then report "DMEM write [" & to_hstring(maddr) & "] = " & to_hstring(mwd); end if;
                if lrd = '1' then report "DMEM read  [" & to_hstring(laddr) & "]"; end if;
                if fl = '1' then report "flush"; end if;
            end if;
        end if;
    end process;

    process
        alias ram   is <<signal .tb_superscalar.dut.Inst_DMEM.ram : Word_Array(0 to 1023)>>;
        alias arf_c is <<signal .tb_superscalar.dut.Inst_CCR_Tracker.arf_c : std_logic>>;
        alias arf_z is <<signal .tb_superscalar.dut.Inst_CCR_Tracker.arf_z : std_logic>>;
        variable cyc, at_halt : integer := 0;
        variable halted : boolean := false;
        function b2c(b : std_logic) return string is begin if b = '1' then return "1"; else return "0"; end if; end;
    begin
        wait until rising_edge(clk); wait until rising_edge(clk);
        wait for 1 ns; rst <= '0';
        while cyc < MAX_CYCLES loop
            wait until rising_edge(clk);
            cyc := cyc + 1;
            -- the fetch PC only stays on HALT once the HALT jump has committed and trained the BTB
            if HALT_PC >= 0 and to_integer(unsigned(ipc)) = HALT_PC then at_halt := at_halt + 1; else at_halt := 0; end if;
            if at_halt >= 40 and sbe = '1' then halted := true; exit; end if;
        end loop;
        if halted then
            report "RESULT HALTED";
        else
            report "RESULT TIMEOUT (possible deadlock)" severity warning;
        end if;
        report "CYCLES " & integer'image(cyc - 40);
        for i in 1 to 7 loop report "REG " & integer'image(i) & " " & to_hstring(arch(i)); end loop;
        report "CCR " & b2c(arf_c) & " " & b2c(arf_z);
        for i in 0 to 1023 loop
            if ram(i) /= x"0000" then report "MEM " & integer'image(i) & " " & to_hstring(ram(i)); end if;
        end loop;
        report "END";
        done <= true;
        wait;
    end process;
end;
