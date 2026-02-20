# Data Processing Instructions (op = 00)

---

## ADD Rd, Rn, Operand2

### Operand2 is imm8
```
Operand2 is imm8:
1110 00 1(use imm) 0100(ADD) 0(S) Rn Rd rot imm8

Example: ADD Rd(rf1) Rn(rf2) #8

1110 0010 1000 0010 0001 0000 0000 1000
         ADD  rf2   rf1         imm=8
```

### Operand2 is Rm
```
Operand2 is Rm:
1110 00 0(use reg) 0100(ADD) 0(S) Rn Rd rot Rm

Example: ADD Rd(rf4) Rn(rf1) Rm(rf0)

1110 0000 1000 0001 0100 0000 0000 0000
         ADD  rf1   rf4            rf0
```

---

## SUB Rd, Rn, Operand2

### Operand2 is imm8
```
Example: SUB Rd(rf3) Rn(rf2) #5

1110 0010 0010 0010 0011 0000 0000 0101
         SUB  rf2   rf3         imm=5
```

### Operand2 is Rm
```
Example: SUB Rd(rf5) Rn(rf4) Rm(rf1)

1110 0000 0010 0100 0101 0000 0000 0001
         SUB  rf4   rf5            rf1
```

---

## AND Rd, Rn, Operand2

### Operand2 is imm8
```
Example: AND Rd(rf1) Rn(rf2) #15

1110 0010 0000 0010 0001 0000 0000 1111
         AND  rf2   rf1         imm=15
```

### Operand2 is Rm
```
Example: AND Rd(rf6) Rn(rf3) Rm(rf2)

1110 0000 0000 0011 0110 0000 0000 0010
         AND  rf3   rf6            rf2
```

---

## ORR Rd, Rn, Operand2

### Operand2 is imm8
```
Example: ORR Rd(rf2) Rn(rf1) #1

1110 0010 1100 0001 0010 0000 0000 0001
         ORR  rf1   rf2         imm=1
```

### Operand2 is Rm
```
Example: ORR Rd(rf7) Rn(rf6) Rm(rf5)

1110 0000 1100 0110 0111 0000 0000 0101
         ORR  rf6   rf7            rf5
```

---

## MOV Rd, Operand2

### Operand2 is imm8
```
Example: MOV Rd(rf1) #20

1110 0010 1101 0000 0001 0000 0001 0100
         MOV        rf1         imm=20
```

### Operand2 is Rm
```
Example: MOV Rd(rf3) Rm(rf2)

1110 0000 1101 0000 0011 0000 0000 0010
         MOV        rf3            rf2
```

---

## EOR Rd, Rn, Operand2

### Operand2 is imm8
```
Example: EOR Rd(rf4) Rn(rf3) #9

1110 0010 0001 0011 0100 0000 0000 1001
         EOR  rf3   rf4         imm=9
```

### Operand2 is Rm
```
Example: EOR Rd(rf5) Rn(rf2) Rm(rf1)

1110 0000 0001 0010 0101 0000 0000 0001
         EOR  rf2   rf5            rf1
```

---

## CMP Rn, Operand2

### Operand2 is imm8
```
Example: CMP Rn(rf2) #10

1110 0010 1010 0010 0000 0000 0000 1010
         CMP  rf2            imm=10
```

### Operand2 is Rm
```
Example: CMP Rn(rf3) Rm(rf1)

1110 0000 1010 0011 0000 0000 0000 0001
         CMP  rf3               rf1
```

---

## TST Rn, Operand2

### Operand2 is imm8
```
Example: TST Rn(rf4) #7

1110 0010 1000 0100 0000 0000 0000 0111
         TST  rf4            imm=7
```

### Operand2 is Rm
```
Example: TST Rn(rf5) Rm(rf2)

1110 0000 1000 0101 0000 0000 0000 0010
         TST  rf5               rf2
```
---
## BX Rm
```
1110 0001 0010 1111 1111 1111 0001 0000(Rm[3:0])

Example: BX Rm(rf3)
1110 0001 0010 1111 1111 1111 0001 0011
         BX               rf3
```
---

# Load / Store Instructions (op = 01)

---

## LDR Rd, [Rn, #offset]

### ADD offset
```
Example: LDR Rd(rf1), [Rn(rf2), #4]

1110 0101 1001 0010 0001 0000 0000 0100
         LDR  rf2   rf1         off=4
```

### SUB offset
```
Example: LDR Rd(rf3), [Rn(rf4), #-8]

1110 0101 0001 0100 0011 0000 0000 1000
         LDR  rf4   rf3         off=-8
```

---

## STR Rd, [Rn, #offset]

### ADD offset
```
Example: STR Rd(rf5), [Rn(rf6), #12]

1110 0101 1000 0110 0101 0000 0000 1100
         STR  rf6   rf5         off=12
```

### SUB offset
```
Example: STR Rd(rf2), [Rn(rf1), #-4]

1110 0101 0000 0001 0010 0000 0000 0100
         STR  rf1   rf2         off=-4
```

---

# Branch Instructions (op = 10)

---
## B label
```
branch_target = pc + 9'd2 + if_off24[8:0];

1110 1010(B) 0000 0000 0000 0000 0000 0000  (offset is calculated by assembler)

Example: B label(+6)
1110 1010 0000 0000 0000 0000 0000 0110
         B               off=6
```

---

## BL label
```
branch_target = pc + 9'd2 + if_off24[8:0];

1110 1011(BL) 0000 0000 0000 0000 0000 0000  (offset is calculated by assembler)

Example: BL label(+12)
1110 1011 0000 0000 0000 0000 0000 1100
         BL              off=12
```

---

## BEQ Rn, Rm, offset
```
branch_target = ifid_pc + 2 + sign_extend(off16)

Branch if Equal (Rn == Rm)
BEQ  Rn,Rm,off16   
inst[31:28]=4'hE  inst[27:24]=4'b1000
inst[23:20]=Rn  inst[19:16]=Rm  inst[15:0]=off16

Example: BEQ rf1 rf2 +5
1110 1000 0001 0010 0000 0000 0000 0101
         BEQ  rf1   rf2         off=5
```

---

## BNE Rn, Rm, offset
```
branch_target = ifid_pc + 2 + sign_extend(off16)

Branch if Not Equal (Rn != Rm)
BNE  Rn,Rm,off16
 {4'hE, 4'b1001, Rn, Rm, 16'(off16)}

Example: BNE Rn(rf3) Rm(rf4) +7
1110 1001 0011 0100 0000 0000 0000 0111
         BNE  rf3   rf4         off=7
```

---

# Special Instruction

---

## NOP
```
Example: NOP

1110 0000 0000 0000 0000 0000 0000 0000
         NOP
```

---

# Custom Instructions

---

## SLL Rd, Rn, Rm
```
Example: SLL Rd(rf2) Rn(rf1) Rm(rf0)

1110 0000 0110 0001 0010 0000 0000 0000
         SLL  rf1   rf2            rf0
```

---

## SRL Rd, Rn, Rm
```
Example: SRL Rd(rf3) Rn(rf2) Rm(rf1)

1110 0000 0111 0010 0011 0000 0000 0001
         SRL  rf2   rf3            rf1
```

---

## SLT Rd, Rn, Rm
```
Example: SLT Rd(rf4) Rn(rf3) Rm(rf2)

1110 0000 1011 0011 0100 0000 0000 0010
         SLT  rf3   rf4            rf2
```

---
