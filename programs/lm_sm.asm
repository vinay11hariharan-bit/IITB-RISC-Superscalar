; LM / SM / LMF / SMF through the MF sequencer.
        LLI R1, 0x100
        LLI R2, 0x22
        LLI R3, 0x33
        LLI R4, 0x44
        SM  R1, {R2, R3, R4}        ; M[0x100..0x104] = R4, R3, R2 (R7 side first: bit 0 = R7)
        LM  R1, {R5, R6, R7}        ; reload into R5..R7
        ADA R2, R2, R2              ; sets flags: C=0, Z=0 (0x44)
        LLI R5, 0x0
        ADA R5, R5, R5              ; Z = 1
        SMF R1, {R2}                ; M[0x100] = CCR (C=0,Z=1 -> 1), M[0x102] = R2
        ADI R6, R6, 1               ; ADI 0x33+1: C=0 Z=0
        LMF R1, {R4}                ; CCR <- M[0x100] (Z=1), R4 <- M[0x102] = 0x44
        ; LM in slot 1 (address multiple of 4) followed by an ordinary instruction:
        ; the instruction in slot 2 must not be lost.
        LLI R6, 0x120
        NOP
        LM  R6, {R2, R3}            ; slot 1
        ADI R7, R7, 3               ; slot 2: must execute after the LM micro-ops
        ; LM that overwrites its own base register: every load uses the original base
        LLI R1, 0x140
        LM  R1, {R1, R2, R3}
        HALT
