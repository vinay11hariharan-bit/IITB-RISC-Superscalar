#!/usr/bin/env python3
"""Random test programs that stress the load/store path.

Few distinct base addresses and small offsets make loads and stores alias
often, which exercises store-to-load forwarding, waiting on unknown store
addresses, the Store Buffer and the LM/SM micro-op sequences. Forward
branches and JAL add mispredictions and flushes in the middle of memory traffic.
Only forward control flow is generated, so every program terminates.
"""
import random

ALU3 = ['ADA', 'ADC', 'ADZ', 'AWC', 'ACA', 'ACC', 'ACZ', 'ACW', 'NDU', 'NDC', 'NDZ', 'NCU', 'NCC', 'NCZ']
POINTERS = [0x40, 0x42, 0x44, 0x48, 0x80, 0x100]


def r(rng, lo=0, hi=7):
    return f'R{rng.randint(lo, hi)}'


def body(rng, n, out, tag, hi=7):
    """n random instructions; destinations limited to R0..R<hi>."""
    label_id = 0
    pending = []          # (label, position) for forward branches
    for pos in range(n):
        for lab, at in list(pending):
            if at <= pos:
                out.append(f'{lab}:')
                pending.remove((lab, at))
        k = rng.random()
        if k < 0.22:
            out.append(f'LW {r(rng, 0, hi)}, {r(rng)}, {rng.choice([0, 0, 2, 4, -2, 6])}')
        elif k < 0.42:
            out.append(f'SW {r(rng)}, {r(rng)}, {rng.choice([0, 0, 2, 4, -2, 6])}')
        elif k < 0.50:
            out.append(f'LLI {r(rng, 1, hi)}, {rng.choice(POINTERS)}')
        elif k < 0.62:
            out.append(f'{rng.choice(ALU3)} {r(rng, 0, hi)}, {r(rng)}, {r(rng)}')
        elif k < 0.70:
            out.append(f'ADI {r(rng, 0, hi)}, {r(rng)}, {rng.randint(-32, 31)}')
        elif k < 0.80:
            mn = rng.choice(['LM', 'SM', 'LMF', 'SMF'])
            pool = range(8) if mn.startswith('S') else range(hi + 1)
            regs = sorted(rng.sample(list(pool), rng.randint(0, min(5, len(pool)))))
            out.append(f'{mn} {r(rng)}, {{{", ".join(f"R{x}" for x in regs)}}}')
        elif k < 0.92:
            label_id += 1
            lab = f'{tag}{label_id}'
            pending.append((lab, pos + rng.randint(1, 4)))
            out.append(f'{rng.choice(["BEQ", "BLT", "BLE"])} {r(rng)}, {r(rng)}, {lab}')
        elif k < 0.96:
            label_id += 1
            lab = f'{tag}{label_id}'
            pending.append((lab, pos + rng.randint(1, 3)))
            out.append(f'JAL {r(rng, 0, hi)}, {lab}')
        else:
            out.append('NOP')
    for lab, _ in pending:
        out.append(f'{lab}:')


def generate(seed, length=None):
    """Three kinds of program, chosen by seed:
       straight-line (forward branches only), a counted loop around a random
       body (backward branch, BTB training), and long programs that fill the
       ROB / LSQ and exercise back-pressure."""
    rng = random.Random(seed)
    kind = rng.choice(['plain', 'plain', 'loop', 'long'])
    out = []
    for i in range(1, 8):
        out.append(f'LLI R{i}, {rng.choice(POINTERS + [rng.randint(0, 511)])}')
    if kind == 'loop':
        # R6 = 0 and R7 = trip count are reserved; the body writes R0..R5 only
        out.append('LLI R6, 0')
        out.append(f'LLI R7, {rng.randint(2, 5)}')
        out.append('top:')
        body(rng, length or rng.randint(5, 25), out, 'B', hi=5)
        out.append('ADI R7, R7, -1')
        out.append('BLT R6, R7, top')
    else:
        body(rng, length or (rng.randint(100, 200) if kind == 'long' else rng.randint(15, 60)), out, 'L')
    out.append('HALT')
    dmem = [rng.randint(0, 0xFFFF) for _ in range(160)]
    return '\n'.join(out) + '\n', dmem


if __name__ == '__main__':
    import sys
    print(generate(int(sys.argv[1]) if len(sys.argv) > 1 else 1)[0])
