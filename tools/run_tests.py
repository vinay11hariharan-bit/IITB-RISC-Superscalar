#!/usr/bin/env python3
"""Build the design with GHDL and check it against the reference model.

  python3 tools/run_tests.py                 # directed tests + 200 random programs
  python3 tools/run_tests.py --random 1000   # more random programs
  python3 tools/run_tests.py programs/lsu_basic.asm --trace
  python3 tools/run_tests.py --small         # tiny LSQ / Store Buffer (back-pressure stress)

Each program is assembled, run on the RTL (tb/tb_superscalar.vhd) and on the
ISA model (tools/iss.py). The final R1-R7, C/Z flags and the whole data memory
must match, and the run must reach HALT (no deadlock).
A data file next to a program (prog.dmem) preloads DMEM: one hex word per line.
"""
import argparse
import glob
import os
import random
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
import asm  # noqa: E402
import iss  # noqa: E402
import randprog  # noqa: E402

BUILD = os.path.join(ROOT, 'build')
GHDL = ['ghdl']
STD = ['--std=08', f'--workdir={BUILD}']


def build():
    os.makedirs(BUILD, exist_ok=True)
    files = [l.strip() for l in open(os.path.join(ROOT, 'files.txt')) if l.strip()]
    files.append('tb/tb_superscalar.vhd')
    for f in files:
        subprocess.run(GHDL + ['-a'] + STD + [os.path.join(ROOT, f)], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    subprocess.run(GHDL + ['-e'] + STD + ['tb_superscalar'], check=True, cwd=BUILD)


def read_dmem(path):
    if not path or not os.path.exists(path):
        return None
    words = []
    for line in open(path):
        m = re.match(r'\s*([0-9A-Fa-f]{4})', line)
        if m:
            words.append(int(m.group(1), 16))
    return words


def run_rtl(hex_path, dmem_path, halt_pc, trace=False, max_cycles=20000, extra=()):
    cmd = GHDL + ['-r'] + STD + ['tb_superscalar', f'-gIMEM_INIT={hex_path}', f'-gHALT_PC={halt_pc}',
                                 f'-gMAX_CYCLES={max_cycles}', '--ieee-asserts=disable']
    if dmem_path:
        cmd.append(f'-gDMEM_INIT={dmem_path}')
    if trace:
        cmd.append('-gTRACE=true')
    cmd += list(extra)
    out = subprocess.run(cmd, cwd=BUILD, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True).stdout
    st = {'regs': [0] * 8, 'mem': {}, 'halted': False, 'C': None, 'Z': None, 'cycles': None, 'log': out}
    for line in out.splitlines():
        m = re.search(r'\(report (?:note|warning)\): (.*)$', line)
        if not m:
            continue
        t = m.group(1).split()
        if t[0] == 'RESULT':
            st['halted'] = t[1] == 'HALTED'
        elif t[0] == 'REG':
            st['regs'][int(t[1])] = int(t[2], 16)
        elif t[0] == 'CCR':
            st['C'], st['Z'] = int(t[1]), int(t[2])
        elif t[0] == 'MEM':
            st['mem'][int(t[1])] = int(t[2], 16)
        elif t[0] == 'CYCLES':
            st['cycles'] = int(t[1])
    return st


def compare(rtl, ref):
    errs = []
    if not rtl['halted']:
        errs.append('did not reach HALT (deadlock or timeout)')
    for i in range(1, 8):
        if rtl['regs'][i] != ref['regs'][i]:
            errs.append(f'R{i}: rtl={rtl["regs"][i]:04X} ref={ref["regs"][i]:04X}')
    if (rtl['C'], rtl['Z']) != (ref['C'], ref['Z']):
        errs.append(f'CCR: rtl C={rtl["C"]} Z={rtl["Z"]}  ref C={ref["C"]} Z={ref["Z"]}')
    ref_mem = {i: v for i, v in enumerate(ref['mem']) if v}
    for a in sorted(set(ref_mem) | set(rtl['mem'])):
        if ref_mem.get(a, 0) != rtl['mem'].get(a, 0):
            errs.append(f'MEM[{a:#05x}] (byte {2 * a:#06x}): rtl={rtl["mem"].get(a, 0):04X} ref={ref_mem.get(a, 0):04X}')
    return errs


def run_one(name, src, dmem_words, trace=False, verbose=False, extra=()):
    words, halt_pc, _ = asm.assemble(src)
    if halt_pc is None:
        raise ValueError(f'{name}: program has no HALT')
    tmp = os.path.join(BUILD, 'tests')
    os.makedirs(tmp, exist_ok=True)
    hex_path = os.path.join(tmp, name + '.hex')
    asm.write_hex(words, hex_path)
    dmem_path = None
    if dmem_words:
        dmem_path = os.path.join(tmp, name + '.dmem')
        with open(dmem_path, 'w') as f:
            f.writelines(f'{w:04X}\n' for w in dmem_words)
    # without a data file DMEM keeps its built-in contents (rtl/DMEM.vhd: word i = i for i < 8)
    ref = iss.run([w for w, _ in words], dmem_words if dmem_words else list(range(8)))
    rtl = run_rtl(hex_path, dmem_path, halt_pc, trace, extra=extra)
    errs = compare(rtl, ref)
    if trace or (errs and verbose):
        print('\n'.join(l for l in rtl['log'].splitlines() if 'report' in l))
    return errs, rtl, ref


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('programs', nargs='*', help='.asm files (default: programs/*.asm)')
    ap.add_argument('--random', type=int, default=None, help='number of random programs (default 200, or 0 when programs are given)')
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--trace', action='store_true')
    ap.add_argument('--no-build', action='store_true')
    ap.add_argument('--small', action='store_true',
                    help='run with a 4-entry LSQ and 2-entry Store Buffer to stress back-pressure')
    a = ap.parse_args()

    if not a.no_build:
        build()
    extra = ['-gLSQ_DEPTH=4', '-gSB_DEPTH=2'] if a.small else []

    progs = a.programs or sorted(glob.glob(os.path.join(ROOT, 'programs', '*.asm')))
    failed = 0
    for p in progs:
        name = os.path.splitext(os.path.basename(p))[0]
        errs, rtl, ref = run_one(name, open(p).read(), read_dmem(os.path.splitext(p)[0] + '.dmem'),
                                 trace=a.trace, verbose=True, extra=extra)
        status = 'PASS' if not errs else 'FAIL'
        print(f'{status}  {name:24s} {ref["steps"]:4d} instr  {rtl["cycles"]} cycles')
        for e in errs:
            print('      ' + e)
        failed += bool(errs)

    if a.random is None:
        a.random = 0 if a.programs else 200
    rnd_fail = rnd_run = 0
    for i in range(a.random):
        rnd_run += 1
        seed = a.seed + i
        src, dmem = randprog.generate(seed)
        errs, rtl, ref = run_one(f'rand_{seed}', src, dmem, extra=extra)
        if errs:
            rnd_fail += 1
            print(f'FAIL  random seed {seed}: ' + '; '.join(errs[:4]))
            if rnd_fail >= 5:
                print('stopping after 5 random failures')
                break
    if a.random:
        print(f'random: {rnd_run - rnd_fail}/{rnd_run} passed (seeds {a.seed}..{a.seed + rnd_run - 1})')
    failed += rnd_fail
    print('ALL PASSED' if not failed else f'{failed} FAILED')
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
