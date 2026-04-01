# Custom ARM-32 ISA (EE533 Project)

## Overview
This project implements a custom 5-stage pipelined ARM-32–like processor with extensions for GPU interaction and FIFO-based streaming. The pipeline stages are:

**IF → ID → EX → MEM → WB**

⚠️ Note: There is **no forwarding or hazard detection**. Programmers must insert **NOPs** where required.

---

## Architectural Details

- **Registers**: 16 registers (R0–R15), 64-bit wide
- **Instruction Width**: 32-bit
- **Data Memory**: 256 × 64-bit
- **Instruction Memory**: 512 × 32-bit

---

## Instruction Categories

### 1. Data Processing Instructions

Format (ARM-like):
```
[31:28] cond | [27:26]=00 | I | opcode | S | Rn | Rd | operand2
```

Supported instructions:

| Instruction | Description |
|------------|------------|
| ADD Rd,Rn,Rm/#imm | Addition |
| SUB Rd,Rn,Rm/#imm | Subtraction |
| AND Rd,Rn,Rm | Bitwise AND |
| ORR Rd,Rn,Rm | Bitwise OR |
| EOR Rd,Rn,Rm | XOR |
| MOV Rd,#imm8 | Move immediate |
| SLT Rd,Rn,Rm | Set if less than (signed) |

---

### 2. Shift Instructions

| Instruction | Description |
|------------|------------|
| SLL Rd,Rn,Rm | Shift left by Rm[5:0] |
| SRL Rd,Rn,Rm | Shift right by Rm[5:0] |

---

### 3. Memory Instructions

Format:
```
LDR Rd, [Rn, #offset]
STR Rd, [Rn, #offset]
```

| Instruction | Description |
|------------|------------|
| LDR | Load from memory |
| STR | Store to memory |

---

### 4. Branch Instructions

| Instruction | Description |
|------------|------------|
| B off24 | Unconditional branch |
| BL off24 | Branch and link (stores return addr in R14) |
| BEQ Rn,Rm,off16 | Branch if equal |
| BNE Rn,Rm,off16 | Branch if not equal |
| BX Rm / JR Rm | Jump to register |
| J target9 | Absolute jump |

---

### 5. GPU Instructions

| Instruction | Description |
|------------|------------|
| GPU_RUN | Start GPU execution |
| WRP Rs,#imm3 | Write CPU register to GPU parameter register |

---

### 6. FIFO Instructions

| Instruction | Description |
|------------|------------|
| RDF Rd,#sel | Read FIFO offset into register |
| FIFOWAIT | Stall until FIFO data ready |
| FIFODONE | Signal FIFO completion |

---

### 7. Special Instructions

| Instruction | Description |
|------------|------------|
| NOP | No operation |

---

## Pipeline Behavior

- Instructions move through 5 stages
- No hazard detection
- Branch resolved in EX stage
- Stalls introduced by:
  - GPU_RUN (wait for gpu_done)
  - FIFOWAIT (wait for fifo_data_ready)

---

## Register Usage

| Register | Usage |
|---------|------|
| R0–R12 | General purpose |
| R13 | Stack pointer (optional) |
| R14 | Link register (BL return address) |
| R15 | Program counter (implicit) |

---

## Example Program

```
MOV R1, #10
MOV R2, #20
ADD R3, R1, R2
STR R3, [R0, #0]
```

---

## Notes

- Immediate values are zero-extended
- Branch offsets are relative to PC
- All operations are 64-bit internally
- Programmer must manually manage pipeline hazards

---

## Future Extensions

- Hazard detection
- Forwarding
- Cache support
- SIMD/GPU enhancements

---

## Author
EE533 Project – Custom CPU + GPU Edge Architecture

