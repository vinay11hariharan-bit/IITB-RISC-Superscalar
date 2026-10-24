; The LMF example from the report (Section 6.6): IMEM = 3220, 6306
        LLI R1, 32
        .word 0x6306        ; LMF R1, mask 00000110 -> CCR, R6, R5 from M[32..37]
        HALT
