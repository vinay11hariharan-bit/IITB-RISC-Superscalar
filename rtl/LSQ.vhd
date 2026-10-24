library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use work.RISC_Types_Pkg.ALL;

entity LSQ is
    generic ( LSQ_DEPTH : integer := 8 );
    Port (
        clk             : in  std_logic;
        rst             : in  std_logic;
        
        disp_en         : in  std_logic; 
        bundle          : in  Instr_Bundle;
        disp_rob_tag    : in  Rob_Tag;      -- RENAMED to avoid type clash
        dest_tag        : in  Reg_Tag;
        
        q_base          : in  Reg_Tag; v_base_val : in std_logic; v_base : in Data_Bus;
        q_data          : in  Reg_Tag; v_data_val : in std_logic; v_data : in Data_Bus; 
        
        cdb_valid_1     : in  std_logic; cdb_tag_1 : in Reg_Tag; cdb_val_1 : in Data_Bus;
        cdb_valid_2     : in  std_logic; cdb_tag_2 : in Reg_Tag; cdb_val_2 : in Data_Bus;
        
        mem_req         : out std_logic;
        mem_rw          : out std_logic;
        mem_addr        : out Data_Bus;
        mem_wdata       : out Data_Bus;
        mem_ack         : in  std_logic;
        
        lsq_wb_valid    : out std_logic;
        lsq_wb_val      : out Data_Bus;
        lsq_wb_dest_tag : out Reg_Tag;
        lsq_wb_rob_tag  : out Rob_Tag
    );
end LSQ;

architecture Behavioral of LSQ is
    type LSQ_Entry is record
        Valid      : std_logic;
        Opcode     : std_logic_vector(3 downto 0);
        ROB_Tag    : Rob_Tag; Dest_Tag : Reg_Tag;
        Imm        : std_logic_vector(8 downto 0);
        Q_Base     : Reg_Tag; V_Base_Valid : std_logic; V_Base : Data_Bus;
        Q_Data     : Reg_Tag; V_Data_Valid : std_logic; V_Data : Data_Bus;
        Addr_Ready : std_logic; Address : Data_Bus;
        Issued     : std_logic;
    end record;
    
    type LSQ_Array is array (0 to LSQ_DEPTH-1) of LSQ_Entry;
    signal lsq : LSQ_Array;
    signal head, tail, count : integer := 0;
begin
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                head <= 0; tail <= 0; count <= 0; mem_req <= '0'; lsq_wb_valid <= '0';
                for i in 0 to LSQ_DEPTH-1 loop lsq(i).Valid <= '0'; end loop;
            else
                -- 1. CDB Wakeup
                for i in 0 to LSQ_DEPTH-1 loop
                    if lsq(i).Valid = '1' then
                        if lsq(i).V_Base_Valid = '0' then
                            if cdb_valid_1 = '1' and lsq(i).Q_Base = cdb_tag_1 then lsq(i).V_Base_Valid <= '1'; lsq(i).V_Base <= cdb_val_1;
                            elsif cdb_valid_2 = '1' and lsq(i).Q_Base = cdb_tag_2 then lsq(i).V_Base_Valid <= '1'; lsq(i).V_Base <= cdb_val_2; end if;
                        end if;
                        if lsq(i).V_Data_Valid = '0' then
                            if cdb_valid_1 = '1' and lsq(i).Q_Data = cdb_tag_1 then lsq(i).V_Data_Valid <= '1'; lsq(i).V_Data <= cdb_val_1;
                            elsif cdb_valid_2 = '1' and lsq(i).Q_Data = cdb_tag_2 then lsq(i).V_Data_Valid <= '1'; lsq(i).V_Data <= cdb_val_2; end if;
                        end if;
                    end if;
                end loop;

                -- 2. Address Gen
                for i in 0 to LSQ_DEPTH-1 loop
                    if lsq(i).Valid = '1' and lsq(i).V_Base_Valid = '1' and lsq(i).Addr_Ready = '0' then
                        lsq(i).Address <= std_logic_vector(signed(lsq(i).V_Base) + signed(resize(signed(lsq(i).Imm), DATA_WIDTH)));
                        lsq(i).Addr_Ready <= '1';
                    end if;
                end loop;

                -- 3. In-Order Issue to Memory
                mem_req <= '0'; lsq_wb_valid <= '0';
                if count > 0 and lsq(head).Valid = '1' and lsq(head).Issued = '0' then
                    if lsq(head).Opcode = "0100" and lsq(head).Addr_Ready = '1' then 
                        mem_req <= '1'; mem_rw <= '0'; mem_addr <= lsq(head).Address;
                        if mem_ack = '1' then
                            lsq(head).Issued <= '1'; lsq_wb_valid <= '1'; 
                            lsq_wb_dest_tag <= lsq(head).Dest_Tag; lsq_wb_rob_tag <= lsq(head).ROB_Tag;
                            lsq(head).Valid <= '0'; head <= (head + 1) mod LSQ_DEPTH; count <= count - 1;
                        end if;
                    elsif lsq(head).Opcode = "0101" and lsq(head).Addr_Ready = '1' and lsq(head).V_Data_Valid = '1' then
                        mem_req <= '1'; mem_rw <= '1'; mem_addr <= lsq(head).Address; mem_wdata <= lsq(head).V_Data;
                        if mem_ack = '1' then
                            lsq(head).Issued <= '1'; lsq_wb_valid <= '1'; 
                            lsq_wb_dest_tag <= lsq(head).Dest_Tag; lsq_wb_rob_tag <= lsq(head).ROB_Tag;
                            lsq(head).Valid <= '0'; head <= (head + 1) mod LSQ_DEPTH; count <= count - 1;
                        end if;
                    end if;
                end if;

                -- 4. Enqueue
                if disp_en = '1' and bundle.Is_Mem = '1' and count < LSQ_DEPTH then
                    lsq(tail).Valid <= '1'; lsq(tail).Issued <= '0'; lsq(tail).Opcode <= bundle.Opcode;
                    lsq(tail).ROB_Tag <= disp_rob_tag; lsq(tail).Dest_Tag <= dest_tag; lsq(tail).Imm <= bundle.Imm; -- Updated assignment
                    lsq(tail).Q_Base <= q_base; lsq(tail).V_Base_Valid <= v_base_val; lsq(tail).V_Base <= v_base;
                    lsq(tail).Q_Data <= q_data; lsq(tail).V_Data_Valid <= v_data_val; lsq(tail).V_Data <= v_data;
                    lsq(tail).Addr_Ready <= '0';
                    tail <= (tail + 1) mod LSQ_DEPTH; count <= count + 1;
                end if;
            end if;
        end if;
    end process;
end Behavioral;