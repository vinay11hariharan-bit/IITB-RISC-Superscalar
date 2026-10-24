#!/usr/bin/env python3
"""Assembler for the IITB-RISC variant implemented in this repository.

Encodings follow the RTL (rtl/Decode_Unit.vhd, rtl/ALU_Exec.vhd,
rtl/Branch_Exec.vhd, rtl/MF_Sequencer.vhd):

  ADA/ADC/ADZ/AWC/ACA/ACC/ACZ/ACW  rd, ra, rb   0000 rd ra rb C CZ
  NDU/NDC/NDZ/NCU/NCC/NCZ          rd, ra, rb   0010 rd ra rb C CZ
  ADI   rd, ra, imm6                            0001 rd ra imm6
  LLI   rd, imm9                                0011 rd imm9
  LW    rd, rb, imm6     rd <- M[rb + imm]      0100 rd rb imm6
  SW    rs, rb, imm6     M[rb + imm] <- rs      0101 rs rb imm6
  LM/SM ra, {R1, R5, ...}                       0110/0111 ra 0 mask8
  LMF/SMF ra, {...}      CCR first, at M[ra]    0110/0111 ra 1 mask8
  BEQ/BLT/BLE ra, rb, label|imm6  PC += 2*imm   1000/1001/1010 ra rb imm6
  JAL   ra, label|imm9   ra <- PC+2             1100 ra imm9
  JLR   ra, rb           ra <- PC+2, PC <- rb   1101 ra rb 000000
  JRI   ra, label|imm9   PC <- ra + 2*imm       1111 ra imm9
  HALT                   JAL R0, 0 (jump to itself)
  NOP                    ADA R0, R0, R0

Register mask for LM/SM: bit k selects R(7-k) (bit 7 = R0, bit 0 = R7).
R0 reads as the PC of the instruction; writes to R0 are discarded.

Usage: asm.py prog.asm -o prog.hex
"""
import re
import sys

R_TYPE = {
    'ADA': (0b0000, 0, 0b00), 'ADC': (0b0000, 0, 0b10), 'ADZ': (0b0000, 0, 0b01), 'AWC': (0b0000, 0, 0b11),
    'ACA': (0b0000, 1, 0b00), 'ACC': (0b0000, 1, 0b10), 'ACZ': (0b0000, 1, 0b01), 'ACW': (0b0000, 1, 0b11),
    'NDU': (0b0010, 0, 0b00), 'NDC': (0b0010, 0, 0b10), 'NDZ': (0b0010, 0, 0b01),
    'NCU': (0b0010, 1, 0b00), 'NCC': (0b0010, 1, 0b10), 'NCZ': (0b0010, 1, 0b01),
}
BRANCH = {'BEQ': 0b1000, 'BLT': 0b1001, 'BLE': 0b1010}


def reg(tok):
    m = re.fullmatch(r'[Rr]([0-7])', tok.strip())
    if not m:
        raise ValueError(f'bad register {tok!r}')
    return int(m.group(1))


def num(tok):
    return int(tok.strip(), 0)


def field(v, bits, signed=True):
    lo, hi = (-(1 << (bits - 1)), (1 << (bits - 1)) - 1) if signed else (0, (1 << bits) - 1)
    if not lo <= v <= hi:
        raise ValueError(f'immediate {v} does not fit in {bits} bits')
    return v & ((1 << bits) - 1)


def assemble(text):
    lines = []
    for raw in text.splitlines():
        line = raw.split(';')[0].split('#')[0].strip()
        if line:
            lines.append((raw, line))
    # pass 1: labels
    labels, pc, items = {}, 0, []
    for raw, line in lines:
        while True:
            m = re.match(r'([A-Za-z_]\w*)\s*:\s*(.*)', line)
            if not m:
                break
            labels[m.group(1)] = pc
            line = m.group(2).strip()
        if line:
            items.append((pc, raw, line))
            pc += 2
    # pass 2: encode
    words, halt_pc = [], None

    def target(tok, pc, bits):
        tok = tok.strip()
        if tok in labels:
            off = labels[tok] - pc
            assert off % 2 == 0
            return field(off // 2, bits)
        return field(num(tok), bits)

    for pc, raw, line in items:
        mn, _, rest = line.partition(' ')
        mn = mn.upper()
        mask_m = re.search(r'\{(.*)\}', rest)
        args = [a for a in re.split(r'\s*,\s*', re.sub(r'\{.*\}', '', rest).strip()) if a]
        if mn in R_TYPE:
            op, c, cz = R_TYPE[mn]
            w = op << 12 | reg(args[0]) << 9 | reg(args[1]) << 6 | reg(args[2]) << 3 | c << 2 | cz
        elif mn == 'ADI':
            w = 0b0001 << 12 | reg(args[0]) << 9 | reg(args[1]) << 6 | field(num(args[2]), 6)
        elif mn == 'LLI':
            w = 0b0011 << 12 | reg(args[0]) << 9 | field(num(args[1]), 9, signed=False)
        elif mn in ('LW', 'SW'):
            op = 0b0100 if mn == 'LW' else 0b0101
            w = op << 12 | reg(args[0]) << 9 | reg(args[1]) << 6 | field(num(args[2]), 6)
        elif mn in ('LM', 'SM', 'LMF', 'SMF'):
            op = 0b0110 if mn.startswith('L') else 0b0111
            flag = 1 if mn.endswith('F') else 0
            mask = 0
            if mask_m and mask_m.group(1).strip():
                for r in mask_m.group(1).split(','):
                    mask |= 1 << (7 - reg(r))
            elif len(args) > 1:
                mask = num(args[1])
            w = op << 12 | reg(args[0]) << 9 | flag << 8 | mask
        elif mn in BRANCH:
            w = BRANCH[mn] << 12 | reg(args[0]) << 9 | reg(args[1]) << 6 | target(args[2], pc, 6)
        elif mn == 'JAL':
            w = 0b1100 << 12 | reg(args[0]) << 9 | target(args[1], pc, 9)
        elif mn == 'JLR':
            w = 0b1101 << 12 | reg(args[0]) << 9 | reg(args[1]) << 6
        elif mn == 'JRI':
            w = 0b1111 << 12 | reg(args[0]) << 9 | field(num(args[1]), 9)
        elif mn == 'HALT':
            w = 0b1100 << 12
            if halt_pc is None:
                halt_pc = pc
        elif mn == 'NOP':
            w = 0
        elif mn == '.WORD':
            w = num(args[0]) & 0xFFFF
        else:
            raise ValueError(f'unknown instruction: {raw.strip()}')
        words.append((w, raw.strip()))
    return words, halt_pc, labels


def write_hex(words, path):
    with open(path, 'w') as f:
        for i, (w, src) in enumerate(words):
            f.write(f'{w:04X}  -- {2 * i:04X}: {src}\n')


if __name__ == '__main__':
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('src')
    ap.add_argument('-o', '--out')
    a = ap.parse_args()
    words, halt, _ = assemble(open(a.src).read())
    out = a.out or re.sub(r'\.\w+$', '', a.src) + '.hex'
    write_hex(words, out)
    print(f'{out}: {len(words)} words, HALT at {halt if halt is not None else "none"}')
