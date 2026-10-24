# IITB-RISC 2-Way Superscalar Processor (VHDL)

A 2-way fetch, out-of-order, speculative implementation of the 16-bit IITB-RISC
ISA, built for EE739 (Processor Design) at IIT Bombay. Tomasulo-style
scheduling with register renaming, a reorder buffer with in-order dual commit,
a branch target buffer with 2-bit counters, and a load/store queue with
store-to-load forwarding.

The original project report is in [`docs/EE_739_Superscalar.pdf`](docs/EE_739_Superscalar.pdf).
This repository continues that work. The load/store unit has been rewritten
and the pipeline fixed so that loads and stores, including LM/SM/LMF/SMF, run
correctly end to end. The design is checked against an instruction-level
reference model on directed and randomly generated programs.

## Pipeline

```
 Fetch (2/cycle, BTB) -> MF sequencer (LM/SM -> micro-ops) -> Decode -> Rename (RAT, free list)
   -> Dispatch -> { ALU RS -> ALU,  Branch RS -> branch unit,  LSQ -> DMEM }
   -> 2 CDBs -> ROB (in-order commit, 2/cycle) -> ARF / CCR / Store Buffer -> DMEM
```

| Parameter | Value |
|---|---|
| Fetch / commit width | 2 / 2 |
| Physical registers | 15 (+ tag 0000 = "no tag") |
| ROB | 16 entries |
| ALU RS / Branch RS / LSQ / Store Buffer | 8 / 4 / 8 / 8 entries |
| Result buses | 2 CDBs |
| Branch prediction | 32-entry BTB, 2-bit saturating counters, trained at commit |
| Memory | IMEM 1K words (combinational read), DMEM 1K words, separate read and write ports |

## Repository layout

```
rtl/        synthesizable design (compile order in files.txt)
tb/         system testbench (prints final registers, flags and memory)
programs/   directed test programs (.asm) with optional DMEM contents (.dmem)
tools/      asm.py (assembler), iss.py (reference model), randprog.py, run_tests.py
docs/       report PDF and LSU.md (load/store unit design notes)
```

| File | Unit |
|---|---|
| `Fetch_Unit.vhd`, `BP_Unit.vhd`, `IMEM.vhd` | PC, BTB, instruction memory |
| `MF_Sequencer.vhd` | LM / SM / LMF / SMF expansion |
| `Decode_Unit.vhd`, `RR_unit.vhd`, `Register_File_Array.vhd` | decode, rename, ARF/RRF |
| `Dispatch_router.vhd`, `ALU_RS.vhd`, `Branch_RS.vhd`, `LSQ.vhd` | dispatch and reservation stations |
| `ALU_Exec.vhd`, `Branch_Exec.vhd`, `CDB_Arbiter.vhd`, `CCR_Tracker.vhd` | execution, result buses, flags |
| `ROB.vhd`, `Store_Buffer.vhd`, `DMEM.vhd` | commit, committed stores, data memory |
| `iitb_risc_superscalar.vhd` | top level |

## Running the tests

Requires [GHDL](https://github.com/ghdl/ghdl) (VHDL-2008) and Python 3.

```sh
python3 tools/run_tests.py                     # directed tests + 200 random programs
python3 tools/run_tests.py --random 2000       # longer random run
python3 tools/run_tests.py programs/lm_sm.asm --trace   # one program, print commits and memory traffic
make test                                      # same as the first line
```

Every program runs on the RTL and on `tools/iss.py`. The test passes when the
program reaches `HALT` and the final R1–R7, C/Z flags and the whole data memory
match.

Writing your own program:

```sh
python3 tools/asm.py my_prog.asm -o my_prog.hex
ghdl -r --std=08 --workdir=build tb_superscalar -gIMEM_INIT=my_prog.hex -gHALT_PC=<byte address of HALT> -gTRACE=true
```

ModelSim/Questa: compile the files in `files.txt` order with `-2008`, then
`tb/tb_superscalar.vhd`, and set `IMEM_INIT` / `DMEM_INIT` as generics.

Current results: all directed programs pass, and the random regression passes
(see the commit history for the number of programs run).

## Instruction encoding (as implemented)

| Instruction | Encoding | Operation |
|---|---|---|
| ADA ADC ADZ AWC / ACA ACC ACZ ACW | `0000 rd ra rb n cz` | rd = ra + (n ? ~rb : rb), plus carry for AWC/ACW; cz = 10: only if C, 01: only if Z |
| ADI | `0001 rd ra imm6` | rd = ra + SE(imm6) |
| NDU NDC NDZ / NCU NCC NCZ | `0010 rd ra rb n cz` | rd = ~(ra & (n ? ~rb : rb)); same cz conditions |
| LLI | `0011 rd imm9` | rd = ZE(imm9) |
| LW | `0100 rd rb imm6` | rd = M[rb + SE(imm6)] |
| SW | `0101 rs rb imm6` | M[rb + SE(imm6)] = rs |
| LM / SM | `0110` / `0111` `ra 0 mask8` | mask bit k selects R(7-k), consecutive words from M[ra] |
| LMF / SMF | `0110` / `0111` `ra 1 mask8` | as LM/SM, with C,Z at M[ra] first |
| BEQ BLT BLE | `1000` `1001` `1010` `ra rb imm6` | if ra (=, <, <=) rb: PC += 2*SE(imm6) |
| JAL | `1100 ra imm9` | ra = PC+2; PC += 2*SE(imm9) |
| JLR | `1101 ra rb 000000` | ra = PC+2; PC = rb |
| JRI | `1111 ra imm9` | PC = ra + 2*SE(imm9) |

`n` is the complement bit (ACx / NCx forms). R0 reads as the PC of the instruction and writes to it are discarded.
ADD/ADI write C and Z, NAND writes Z, LW/LLI write no flags. `HALT` in the
assembler is `JAL R0, 0`.

A few points differ from the report's tables. The RTL is the reference here:
ADD is `0000` and ADI is `0001` (the report lists them the other way round),
and BLE is `1010` (the report says `1011`). The destination of R-type
instructions and ADI is in bits 11:9, as in the report's examples
(`ADD R1, R2, R3` writes R1).

## Changes since the report

The load/store unit is described in [`docs/LSU.md`](docs/LSU.md). In short, the
LSQ was replaced:
- stores now write memory only after commit, through the Store Buffer;
- loads issue out of order once every older store address is known;
- store-to-load forwarding works from both the LSQ and the Store Buffer;
- both fetch slots dispatch to it, and it flushes on a misprediction;
- DMEM has separate read and write ports.

Fixes elsewhere that the memory path depended on:

| Unit | Problem | Fix |
|---|---|---|
| MF sequencer | LM/SM in slot 1 dropped the instruction in slot 2; no flush; ignored decode stalls; LM loading its own base used the new base | fetch is redirected to refetch slot 2; flush and hold inputs; base load moved to the end |
| Rename | RAT busy bit never cleared, so readers used freed physical registers; free-list stall was registered (lost a bundle) and missed the slot-2-only case | clear on commit; combinational stall; hold input |
| Register file | operand broadcast in the dispatch cycle was missed; slot 2 trusted a stale valid bit for slot 1's new tag | CDB bypass on reads; same-bundle check |
| CCR tracker | missed same-cycle broadcasts (deadlock); merged flags by mask and lost older producers; plain LW counted as a flag producer | bypass; take broadcast flags whole; producer list fixed. Flag producers with destination R0 (e.g. NOP) now get a physical tag |
| Back-pressure | ROB/RS/LSQ full did not stop rename, decode or fetch | full signals wired; front end holds |
| Flush | ALU RS, Branch RS and execution units kept wrong-path work; ROB accepted wrong-path dispatches in the flush cycle | flush inputs; dispatch gated during flush |
| ROB | branches checked against PC+2 instead of the fetch prediction (a predicted-taken branch that fell through was never corrected); a mispredicted JAL/JLR lost its link value | predicted PC carried in the bundle; the control instruction commits before the flush |
| Branch RS | one dispatch port: a second branch in the same bundle was dropped | second port |
| CDB arbiter | holding the ALU on a 3-way conflict lost the instruction the ALU RS issued that cycle | the LSQ waits instead (it can hold its result) |
| ALU | ADI zero-extended negative immediates | sign-extend before the add |

## Known limitations

- One load/store operation is selected per cycle, and store completions use a CDB slot.
- Only the instruction committed in slot 1 trains the BTB.
- No partial flush: a misprediction is resolved at commit and flushes everything younger.
- The report's TAG stack is not implemented; the full flush at commit makes it unnecessary.
- IMEM is a combinational read (the report describes a synchronous one).

## Credits

EE739 Team 01, IIT Bombay: Yashvardhan Khandegar, Sudhindra Sahoo,
Vinay Hariharan, Himanshu Sahu. Work distribution is in the report (Chapter 8).
