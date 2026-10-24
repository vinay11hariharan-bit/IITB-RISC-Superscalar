# Load/Store Unit

This note describes the load/store path as it is implemented now, and what was
wrong with the version submitted with the report.

```
            dispatch (2/cycle)                 commit (ROB, up to 2/cycle)
                  |                                     |
                  v                                     v
   +------------------------------+   committed   +--------------+   1 store/cycle   +--------+
   | LSQ  (8 entries, in order)   |-------------->| Store Buffer |------------------>|  DMEM  |
   |  AGU, disambiguation,        |    stores     |  (8 entries) |   write port      |        |
   |  store-to-load forwarding    |<--------------|  forwarding  |                   |        |
   +------------------------------+    lookup     +--------------+                   |        |
        |                   |                                                       |        |
        |  load read        +------------------------------------------------------>| read   |
        v                                                                           | port   |
     CDB (load value / store done)  <--------------------- load data ---------------+--------+
```

## LSQ (`rtl/LSQ.vhd`)

A circular FIFO in program order. Each entry holds the ROB tag, destination
tag, immediate, base operand, store data operand, computed address and two
status bits: **Done** (the load has issued, or the store has reported
"ready" to the ROB) and **Finished** (the entry may be removed from the head).

Every cycle:

1. **Wakeup.** Base and data operands capture CDB broadcasts. The data
   operand of the SMF flag micro-op is the CCR and captures the broadcast flags.
2. **Address generation.** One cycle after the base value is known:
   `EA = base + sign_extend(imm)`.
3. **Select.** The oldest entry that can execute this cycle:
   * a **store** whose address and data are both known: it reports done to the
     ROB over the CDB (tag 0000) so the ROB can commit it;
   * a **load** whose address is known and for which every *older* store still
     in the LSQ has a known address. If the youngest older store to the same
     word has its data, that data is forwarded. If its data is not ready yet,
     the load waits. Otherwise the Store Buffer is checked, and only then is
     DMEM read.
4. **Commit.** When the ROB commits a store, the LSQ finds it by ROB tag and
   hands address and data to the Store Buffer in the same clock edge.
5. **Retire.** Up to two Finished entries leave from the head.
6. **Dispatch.** Up to two new entries at the tail (both fetch slots).

A pipeline flush empties the LSQ. A committed store has already moved to the
Store Buffer by then, so no architectural store is lost.

Load timing: address in cycle 1, select and DMEM read (or forward) in cycle 2,
value on the CDB in cycle 3.

"Same word" compares exactly the address bits that DMEM decodes
(`DMEM_ADDR_BITS downto 1`, see `RISC_Types_Pkg`). Comparing all 16 bits
would miss aliases that wrap around the 2 KB memory.

## Store Buffer (`rtl/Store_Buffer.vhd`)

Holds committed stores and writes the oldest one to DMEM every cycle. It is
not flushed. Loads look up the youngest matching entry here, because DMEM
may not have been written yet. `sb_ready` (room for two) is an input to the
ROB: a store is only committed when the buffer can take it.

## DMEM (`rtl/DMEM.vhd`)

Two ports: a synchronous read port for the LSQ and a write port for the Store
Buffer, so loads and committed stores never compete for one port. Contents can
be preloaded from a hex file (`DMEM_INIT` generic).

## LM / SM / LMF / SMF (`rtl/MF_Sequencer.vhd`)

Expanded into LW/SW micro-ops, two per cycle, while fetch is frozen. Register
`R(7-k)` is selected by mask bit `k`. Bits are taken from bit 0 upward at
consecutive words, after the flag word for LMF/SMF. If an LM loads its own
base register, that load is moved to the end of the sequence, so every
micro-op uses the original base. The LMF flag micro-op loads C (bit 1) and
Z (bit 0) from `M[RA]`. SMF stores them there.

## What was wrong before

| Problem in the submitted RTL | Effect |
|---|---|
| Stores were written to DMEM when they reached the LSQ head, not at commit | Wrong-path stores changed memory, and stores were repeated while waiting for `mem_ack` |
| Store Buffer wired as `commit_addr => cmt_val_1, commit_data => cmt_val_1` | Commit wrote garbage (`XXXX` to `XXXX` in simulation) |
| `lsq_wb_val` was never assigned | Loads broadcast an undefined value |
| `mem_ack` was checked in the cycle `mem_req` was raised; DMEM answers a cycle later | The first load never completed: the pipeline deadlocked |
| Only slot 1 was connected to the LSQ | LW/SW in slot 2 (and every second LM/SM micro-op) was dropped |
| LSQ and DMEM shared one port, with LSQ priority and a shared `ack` | Store Buffer writes and loads interfered |
| No flush input on the LSQ | Wrong-path loads and stores stayed queued |
| No disambiguation or forwarding (report §4.4) | Every memory operation waited, in order, at the head of the queue |
| `lsq_full` tied to `'0'` | Dispatch overran the queue |
