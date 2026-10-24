; Basic loads and stores.
; Expected: R3 = 0x55 (store-to-load forwarding), R4 = M[0x22] (preloaded),
; M[0x20] = 0x55, M[0x24] = 0x77, R6 = 0x77 (read back after the store drained or forwarded)
        LLI R1, 0x20        ; base address
        LLI R2, 0x55
        SW  R2, R1, 0       ; M[0x20] <- 0x55
        LW  R3, R1, 0       ; must see 0x55, not the old memory value
        LW  R4, R1, 2       ; M[0x22] from the preloaded data
        LLI R5, 0x77
        SW  R5, R1, 4       ; M[0x24] <- 0x77
        LW  R6, R1, 4
        ADA R7, R3, R6      ; use loaded values: 0x55 + 0x77 = 0xCC
        HALT
