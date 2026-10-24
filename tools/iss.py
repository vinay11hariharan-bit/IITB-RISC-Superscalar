#!/usr/bin/env python3
"""Instruction-set reference model for the IITB-RISC variant in this repository.

Executes a program one instruction at a time (no pipeline) and returns the
final architectural state. tools/run_tests.py compares the RTL against it.
Semantics match the RTL encodings documented in tools/asm.py:

  * R0 reads as the PC of the executing instruction; writes to R0 are dropped.
  * Memory: 1024 16-bit words, byte addresses, word index = addr[10:1].
  * ADD family / ADI write C and Z, NAND family writes Z, nothing else writes flags
    (except LMF, which loads C,Z from M[RA] bits 1,0).
  * Predicated forms (ADC/ADZ/NDC/...) leave the destination and flags unchanged
    when the condition is false.
"""

MASK16 = 0xFFFF
MEM_WORDS = 1024


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def s16(v):
    return sext(v, 16)


def run(prog, dmem=None, max_steps=100000):
    imem = list(prog) + [0] * (MEM_WORDS - len(prog))
    mem = list(dmem or []) + [0] * (MEM_WORDS - len(dmem or []))
    R = [0] * 8
    C = Z = 0
    pc = 0
    steps = 0

    def rd(i):
        return pc if i == 0 else R[i]

    def wr(i, v):
        if i != 0:
            R[i] = v & MASK16

    def widx(addr):
        return (addr >> 1) & (MEM_WORDS - 1)

    while steps < max_steps:
        w = imem[(pc >> 1) & (MEM_WORDS - 1)]
        if w == 0xC000:               # HALT (JAL R0, 0)
            return {'regs': R[:], 'C': C, 'Z': Z, 'mem': mem, 'steps': steps}
        steps += 1
        op = w >> 12
        ra, rb, rc = (w >> 9) & 7, (w >> 6) & 7, (w >> 3) & 7
        npc = (pc + 2) & MASK16
        if op in (0b0000, 0b0010):    # ADD / NAND families: dest=ra, src=rb, rc
            comp, cz = (w >> 2) & 1, w & 3
            a, b = rd(rb), rd(rc)
            if comp:
                b = ~b & MASK16
            ok = not ((cz == 0b10 and not C) or (cz == 0b01 and not Z))
            if ok:
                if op == 0b0000:
                    r = a + b + (C if cz == 0b11 else 0)
                    C = (r >> 16) & 1
                    Z = int((r & MASK16) == 0)
                    wr(ra, r)
                else:
                    r = ~(a & b) & MASK16
                    Z = int(r == 0)
                    wr(ra, r)
        elif op == 0b0001:            # ADI dest=ra, src=rb
            r = rd(rb) + (sext(w, 6) & MASK16)
            C = (r >> 16) & 1
            Z = int((r & MASK16) == 0)
            wr(ra, r)
        elif op == 0b0011:            # LLI
            wr(ra, w & 0x1FF)
        elif op == 0b0100:            # LW ra <- M[rb + imm]
            wr(ra, mem[widx(rd(rb) + sext(w, 6))])
        elif op == 0b0101:            # SW M[rb + imm] <- ra
            mem[widx(rd(rb) + sext(w, 6))] = rd(ra)
        elif op in (0b0110, 0b0111):  # LM / SM (+ flag variants)
            base = rd(ra)
            flag, mask = (w >> 8) & 1, w & 0xFF
            off = 0
            if flag:
                if op == 0b0110:
                    v = mem[widx(base)]
                    C, Z = (v >> 1) & 1, v & 1
                else:
                    mem[widx(base)] = (C << 1) | Z
                off = 2
            loads = []
            for k in range(8):        # bit k <-> R(7-k), lowest bit first
                if mask >> k & 1:
                    r = 7 - k
                    if op == 0b0110:
                        loads.append((r, mem[widx(base + off)]))
                    else:
                        mem[widx(base + off)] = rd(r)
                    off += 2
            for r, v in loads:        # all addresses use the original base
                wr(r, v)
        elif op in (0b1000, 0b1001, 0b1010):
            a, b = rd(ra), rd(rb)
            take = (a == b) if op == 0b1000 else (s16(a) < s16(b)) if op == 0b1001 else (s16(a) <= s16(b))
            if take:
                npc = (pc + 2 * sext(w, 6)) & MASK16
        elif op == 0b1100:            # JAL
            wr(ra, pc + 2)
            npc = (pc + 2 * sext(w, 9)) & MASK16
        elif op == 0b1101:            # JLR
            t = rd(rb)
            wr(ra, pc + 2)
            npc = t
        elif op == 0b1111:            # JRI
            npc = (rd(ra) + 2 * sext(w, 9)) & MASK16
        else:
            raise ValueError(f'unsupported opcode {op:04b} at pc {pc:04X}')
        pc = npc
    raise RuntimeError('program did not reach HALT')
