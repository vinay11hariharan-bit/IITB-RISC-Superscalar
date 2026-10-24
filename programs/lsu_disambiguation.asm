; Memory disambiguation and store-to-load forwarding under out-of-order timing.
        LLI R1, 0x40
        LLI R2, 0x60
        LW  R3, R1, 0       ; R3 = M[0x40] = 0x0020 (preloaded) - slow producer
        LW  R4, R3, 0       ; R4 = M[0x20]: address depends on a load
        SW  R4, R2, 0       ; store DATA arrives late (depends on two loads)
        LW  R5, R2, 0       ; same address: must wait for the store data, then forward it
        LW  R6, R1, 2       ; different address: may bypass the waiting store
        SW  R6, R3, 4       ; store ADDRESS depends on a load
        LW  R7, R1, 4       ; older store address unknown -> must wait; turns out to alias M[0x44]?
        ADA R7, R7, R5
        SW  R7, R2, 2
        LW  R5, R2, 2       ; forwarded from the store just above
        ; back-to-back stores to one address: the youngest must win
        LLI R3, 0x11
        LLI R4, 0x22
        SW  R3, R2, 4
        SW  R4, R2, 4
        LW  R6, R2, 4       ; must read 0x22
        HALT
