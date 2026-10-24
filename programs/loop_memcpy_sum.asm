; Loops with backward branches (the BTB learns them): copy an 8-word array,
; then sum the copy.  Exercises sustained loads/stores, Store Buffer draining,
; forwarding across loop iterations and back-pressure.
        LLI R1, 0x40        ; src
        LLI R2, 0x80        ; dst
        LLI R3, 8           ; count
        LLI R7, 0
copy:   LW  R4, R1, 0
        SW  R4, R2, 0
        ADI R1, R1, 2
        ADI R2, R2, 2
        ADI R3, R3, -1
        BLT R7, R3, copy    ; while 0 < count
        LLI R2, 0x80
        LLI R3, 8
        LLI R5, 0           ; sum
sum:    LW  R4, R2, 0
        ADA R5, R5, R4
        ADI R2, R2, 2
        ADI R3, R3, -1
        BLT R7, R3, sum
        SW  R5, R2, 0       ; M[0x90] = sum
        HALT
