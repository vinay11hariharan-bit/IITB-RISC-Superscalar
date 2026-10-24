-- Helpers to preload IMEM / DMEM from a text file (simulation).
-- File format: one 16-bit hex word per line, in address order (word 0 first).
-- Anything after the 4 hex digits is ignored, so "4640  -- LW R3, R1, 0" works.
-- Blank lines and lines starting with '#' or '-' are skipped.
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use std.textio.all;

package Mem_Init_Pkg is
    type Word_Array is array (natural range <>) of std_logic_vector(15 downto 0);
    impure function load_hex(fname : string; depth : natural; fallback : Word_Array) return Word_Array;
end package;

package body Mem_Init_Pkg is
    function hex_val(c : character) return integer is
    begin
        case c is
            when '0' to '9' => return character'pos(c) - character'pos('0');
            when 'a' to 'f' => return character'pos(c) - character'pos('a') + 10;
            when 'A' to 'F' => return character'pos(c) - character'pos('A') + 10;
            when others     => return -1;
        end case;
    end function;

    impure function load_hex(fname : string; depth : natural; fallback : Word_Array) return Word_Array is
        file f       : text;
        variable st  : file_open_status;
        variable l   : line;
        variable mem : Word_Array(0 to depth-1) := fallback;
        variable i, v, d : integer;
        variable c   : character;
        variable ok  : boolean;
    begin
        if fname = "" then return mem; end if;
        file_open(st, f, fname, read_mode);
        if st /= open_ok then
            report "Mem_Init_Pkg: cannot open " & fname & ", using built-in contents" severity warning;
            return mem;
        end if;
        mem := (others => (others => '0'));
        i := 0;
        while not endfile(f) and i < depth loop
            readline(f, l);
            v := 0; d := 0;
            while d < 4 loop
                read(l, c, ok);
                exit when not ok;
                if d = 0 and (c = ' ' or c = HT) then next; end if;
                exit when hex_val(c) < 0;
                v := v * 16 + hex_val(c); d := d + 1;
            end loop;
            if d = 4 then
                for b in 0 to 15 loop
                    if (v / 2**b) mod 2 = 1 then mem(i)(b) := '1'; else mem(i)(b) := '0'; end if;
                end loop;
                i := i + 1;
            end if;
        end loop;
        file_close(f);
        return mem;
    end function;
end package body;
