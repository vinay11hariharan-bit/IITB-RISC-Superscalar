; Stores on a mispredicted path must never reach memory; older stores must.
        LLI R1, 0x80
        LLI R2, 0x0A
        LLI R3, 0x0A
        SW  R2, R1, 0       ; committed before the branch: M[0x80] = 0x0A
        BEQ R2, R3, skip    ; taken, predicted not-taken the first time -> flush
        SW  R1, R1, 2       ; wrong path: M[0x82] must stay 0
        LW  R4, R1, 0       ; wrong path load (squashed)
        LLI R5, 0x1FF       ; wrong path
skip:   LW  R6, R1, 0       ; R6 = 0x0A
        SW  R6, R1, 4       ; M[0x84] = 0x0A
        JAL R7, over        ; JAL also flushes the first time; link must still commit
        SW  R1, R1, 6       ; skipped
over:   LW  R4, R1, 4
        HALT
