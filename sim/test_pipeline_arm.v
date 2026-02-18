`timescale 1ns/1ps
// =============================================================================
// tb_pipeline_p.v  —  Self-checking testbench for pipeline_p (pipeline module)
//
// Strategy
// --------
// The Xilinx BRAMs (I_M_32bit_512depth, D_M_64bit_256) cannot be pre-loaded
// with $readmemh.  All memory writes go through the programming ports that the
// DUT already exposes:
//   imem_prog_we / imem_prog_addr / imem_prog_wdata  → write instructions
//   dmem_prog_en / dmem_prog_we / dmem_prog_addr     → seed / read data memory
//
// Pipeline depth
// --------------
// The pipeline has 5 register stages between the register-file read (ID) and
// the register-file write (WB):  ID/EX → EX/MEM → MEM(reg) → MEM/WB → WB.
// With no forwarding, a consumer instruction must enter ID at least 6 cycles
// after its producer enters ID.  Since each instruction advances one word per
// cycle, 7 NOP words between producer and consumer guarantee safety with margin.
//
// Instruction encoding (ARM-32 subset, cond=1110 always)
// -------------------------------------------------------
//  NOP              : 32'hE000_0000   (AND R0,R0,R0 – result discarded)
//
//  MOV Rd, #imm8    : {4'hE, 3'b001, 4'b1101, 1'b0, 4'h0, Rd[3:0], 4'h0, imm8[7:0]}
//    op=00, I=1, opcode=1101(MOV), S=0, Rn=R0, Rd, rot=0000, imm8
//
//  ADD Rd,Rn,Rm     : {4'hE, 3'b000, 4'b0100, 1'b0, Rn, Rd, 8'h00, Rm}
//  SUB Rd,Rn,Rm     : {4'hE, 3'b000, 4'b0010, 1'b0, Rn, Rd, 8'h00, Rm}
//  AND Rd,Rn,Rm     : {4'hE, 3'b000, 4'b0000, 1'b0, Rn, Rd, 8'h00, Rm}
//  ORR Rd,Rn,Rm     : {4'hE, 3'b000, 4'b1100, 1'b0, Rn, Rd, 8'h00, Rm}
//  EOR Rd,Rn,Rm     : {4'hE, 3'b000, 4'b0001, 1'b0, Rn, Rd, 8'h00, Rm}
//
//  ADD Rd,Rn,#imm8  : {4'hE, 3'b001, 4'b0100, 1'b0, Rn, Rd, 4'h0, imm8}
//  SUB Rd,Rn,#imm8  : {4'hE, 3'b001, 4'b0010, 1'b0, Rn, Rd, 4'h0, imm8}
//
//  STR Rd,[Rn,#off] : {4'hE, 8'b0101_1000, Rn, Rd, 12'(off)}
//    op=01, I=0, P=1, U=1, B=0, W=0, L=0
//  LDR Rd,[Rn,#off] : {4'hE, 8'b0101_1001, Rn, Rd, 12'(off)}
//    op=01, I=0, P=1, U=1, B=0, W=0, L=1
//
//  B  offset24      : {4'hE, 4'b1010, offset24[23:0]}
//    branch_target = ifid_pc + 2 + sign_extend(offset24)
//    so: offset24 = desired_target_word_addr - ifid_pc - 2
//    ifid_pc = instruction word address (PC value when that instruction was fetched)
//
// Memory addressing
// -----------------
// stage_MEM uses  mem_bram_addr = exmem_alu_result[7:0]
// The ALU result for LDR/STR = Rn + imm12 (word address used directly).
// So to access dmem word N, set Rn = N and imm12 = 0, OR Rn = 0 and imm12 = N.
//
// Tests
// -----
//  T1  MOV immediate                R1 = 42
//  T2  ADD register                 R3 = R1 + R2  (10+20=30)
//  T3  SUB register                 R4 = R2 - R1  (20-10=10)
//  T4  AND register                 R5 = R1 & R2  (0xAA & 0x55 = 0x00)
//  T5  ORR register                 R6 = R1 | R2  (0xAA | 0x55 = 0xFF)
//  T6  EOR register                 R7 = R1 ^ R2  (0xF0 ^ 0x0F = 0xFF... XNOR gives ~XOR)
//  T7  ADD immediate                R8 = R1 + 5
//  T8  SUB immediate                R9 = R2 - 3
//  T9  STR then LDR roundtrip       store R1 → dmem[2], load back → R10
//  T10 Branch forward (skip poison) B skips an ADD, R11 must stay 0
//  T11 Step mode                    pipeline stalls when run=0,step=0;
//                                   advances exactly 1 word per step pulse
//  T12 pc_reset_pulse               PC returns to 0 on pulse
// =============================================================================

module tb_pipeline_p;

  // ===========================================================================
  // Parameters
  // ===========================================================================
  parameter CLK_HALF  = 5;          // 10 ns period → 100 MHz
  parameter NOP_CNT   = 7;          // NOPs between dependent instructions

  // ===========================================================================
  // DUT I/O
  // ===========================================================================
  reg         clk;
  reg         reset;
  reg         run;
  reg         step;
  reg         pc_reset_pulse;

  reg         imem_prog_we;
  reg  [8:0]  imem_prog_addr;
  reg  [31:0] imem_prog_wdata;

  reg         dmem_prog_en;
  reg         dmem_prog_we;
  reg  [7:0]  dmem_prog_addr;
  reg  [63:0] dmem_prog_wdata;
  wire [63:0] dmem_prog_rdata;

  wire [8:0]  pc_dbg;
  wire [31:0] if_instr_dbg;

  // ===========================================================================
  // Score counters
  // ===========================================================================
  integer pass_cnt;
  integer fail_cnt;

  // ===========================================================================
  // DUT instantiation
  // ===========================================================================
  pipeline dut (
    .clk             (clk),
    .reset           (reset),
    .run             (run),
    .step            (step),
    .pc_reset_pulse  (pc_reset_pulse),
    .imem_prog_we    (imem_prog_we),
    .imem_prog_addr  (imem_prog_addr),
    .imem_prog_wdata (imem_prog_wdata),
    .dmem_prog_en    (dmem_prog_en),
    .dmem_prog_we    (dmem_prog_we),
    .dmem_prog_addr  (dmem_prog_addr),
    .dmem_prog_wdata (dmem_prog_wdata),
    .dmem_prog_rdata (dmem_prog_rdata),
    .pc_dbg          (pc_dbg),
    .if_instr_dbg    (if_instr_dbg)
  );

  // Hierarchical path to the register file array inside DUT
  // Used to read back results after pipeline drains.
  `define RF dut.u_rf.regFile

  // ===========================================================================
  // Clock
  // ===========================================================================
  initial clk = 1'b0;
  always #CLK_HALF clk = ~clk;

  // ===========================================================================
  // Instruction encoding functions (as macros)
  // ===========================================================================
  // NOP  (AND R0,R0,R0)
  `define NOP 32'hE000_0000

  // MOV Rd, #imm8     cond=E op=001 opcode=1101 S=0 Rn=0
  `define ENC_MOV_IMM(Rd, imm8) \
      {4'hE, 3'b001, 4'b1101, 1'b0, 4'h0, (Rd)[3:0], 4'h0, (imm8)[7:0]}

  // ADD Rd, Rn, Rm    register form
  `define ENC_ADD_REG(Rd, Rn, Rm) \
      {4'hE, 3'b000, 4'b0100, 1'b0, (Rn)[3:0], (Rd)[3:0], 8'h00, (Rm)[3:0]}

  // SUB Rd, Rn, Rm
  `define ENC_SUB_REG(Rd, Rn, Rm) \
      {4'hE, 3'b000, 4'b0010, 1'b0, (Rn)[3:0], (Rd)[3:0], 8'h00, (Rm)[3:0]}

  // AND Rd, Rn, Rm
  `define ENC_AND_REG(Rd, Rn, Rm) \
      {4'hE, 3'b000, 4'b0000, 1'b0, (Rn)[3:0], (Rd)[3:0], 8'h00, (Rm)[3:0]}

  // ORR Rd, Rn, Rm
  `define ENC_ORR_REG(Rd, Rn, Rm) \
      {4'hE, 3'b000, 4'b1100, 1'b0, (Rn)[3:0], (Rd)[3:0], 8'h00, (Rm)[3:0]}

  // EOR Rd, Rn, Rm   (XOR; ALU maps to XNOR, so result = ~(Rn^Rm))
  `define ENC_EOR_REG(Rd, Rn, Rm) \
      {4'hE, 3'b000, 4'b0001, 1'b0, (Rn)[3:0], (Rd)[3:0], 8'h00, (Rm)[3:0]}

  // ADD Rd, Rn, #imm8  immediate form
  `define ENC_ADD_IMM(Rd, Rn, imm8) \
      {4'hE, 3'b001, 4'b0100, 1'b0, (Rn)[3:0], (Rd)[3:0], 4'h0, (imm8)[7:0]}

  // SUB Rd, Rn, #imm8
  `define ENC_SUB_IMM(Rd, Rn, imm8) \
      {4'hE, 3'b001, 4'b0010, 1'b0, (Rn)[3:0], (Rd)[3:0], 4'h0, (imm8)[7:0]}

  // STR Rd, [Rn, #imm12]  (op=01 P=1 U=1 B=0 W=0 L=0  → [27:20]=0101_1000)
  `define ENC_STR(Rd, Rn, imm12) \
      {4'hE, 8'b0101_1000, (Rn)[3:0], (Rd)[3:0], (imm12)[11:0]}

  // LDR Rd, [Rn, #imm12]  (op=01 P=1 U=1 B=0 W=0 L=1  → [27:20]=0101_1001)
  `define ENC_LDR(Rd, Rn, imm12) \
      {4'hE, 8'b0101_1001, (Rn)[3:0], (Rd)[3:0], (imm12)[11:0]}

  // B offset24
  // branch_target = ifid_pc + 2 + sign_extend(offset24)
  // offset24 = target_word_addr - ifid_pc - 2
  // ifid_pc is the word address of the B instruction itself
  // (one cycle after it was fetched, so ifid_pc = fetch_addr)
  `define ENC_B(offset24) \
      {4'hE, 4'b1010, (offset24)[23:0]}

  // ===========================================================================
  // Task: write one word to instruction memory (pipeline must be halted)
  // ===========================================================================
  task imem_write;
    input [8:0]  addr;
    input [31:0] data;
    begin
      @(negedge clk);
      imem_prog_we    = 1'b1;
      imem_prog_addr  = addr;
      imem_prog_wdata = data;
      @(negedge clk);       // hold for one full cycle
      imem_prog_we    = 1'b0;
    end
  endtask

  // ===========================================================================
  // Task: write one 64-bit word to data memory via prog port
  // ===========================================================================
  task dmem_write;
    input [7:0]  addr;
    input [63:0] data;
    begin
      @(negedge clk);
      dmem_prog_en    = 1'b1;
      dmem_prog_we    = 1'b1;
      dmem_prog_addr  = addr;
      dmem_prog_wdata = data;
      @(negedge clk);
      dmem_prog_we    = 1'b0;
      dmem_prog_en    = 1'b0;
    end
  endtask

  // ===========================================================================
  // Task: read data memory via prog port (synchronous BRAM – 1 cycle latency)
  // ===========================================================================
  task dmem_read;
    input  [7:0]  addr;
    output [63:0] data;
    begin
      @(negedge clk);
      dmem_prog_en   = 1'b1;
      dmem_prog_we   = 1'b0;
      dmem_prog_addr = addr;
      @(posedge clk); #1;    // wait one cycle for BRAM output
      data = dmem_prog_rdata;
      @(negedge clk);
      dmem_prog_en   = 1'b0;
    end
  endtask

  // ===========================================================================
  // Task: run the pipeline for N cycles (free-run mode)
  // ===========================================================================
  task run_cycles;
    input integer n;
    begin
      run = 1'b1;
      repeat (n) @(posedge clk);
      #1;
      run = 1'b0;
    end
  endtask

  // ===========================================================================
  // Task: issue a single step pulse
  // ===========================================================================
  task single_step;
    begin
      @(negedge clk); step = 1'b1;
      @(posedge clk); #1;
      @(negedge clk); step = 1'b0;
    end
  endtask

  // ===========================================================================
  // Task: full reset – drives all inputs to safe state then deasserts reset
  // ===========================================================================
  task do_reset;
    begin
      reset          = 1'b1;
      run            = 1'b0;
      step           = 1'b0;
      pc_reset_pulse = 1'b0;
      imem_prog_we   = 1'b0;
      imem_prog_addr = 9'h0;
      imem_prog_wdata= 32'h0;
      dmem_prog_en   = 1'b0;
      dmem_prog_we   = 1'b0;
      dmem_prog_addr = 8'h0;
      dmem_prog_wdata= 64'h0;
      repeat (4) @(posedge clk);
      @(negedge clk);
      reset = 1'b0;
      @(posedge clk); #1;
    end
  endtask

  // ===========================================================================
  // Task: check a 64-bit register value via hierarchical reference
  // ===========================================================================
  task check_reg;
    input [3:0]   reg_num;
    input [63:0]  expected;
    input [64*8-1:0] label;     // string label (up to 64 chars)
    reg   [63:0]  actual;
    begin
      actual = `RF[reg_num];
      if (actual === expected) begin
        $display("  PASS  [%0s]  R%0d = 64'h%016X", label, reg_num, actual);
        pass_cnt = pass_cnt + 1;
      end else begin
        $display("  FAIL  [%0s]  R%0d  got=64'h%016X  expected=64'h%016X",
                 label, reg_num, actual, expected);
        fail_cnt = fail_cnt + 1;
      end
    end
  endtask

  // ===========================================================================
  // Task: check a 64-bit data-memory word via prog port
  // ===========================================================================
  task check_dmem;
    input [7:0]   addr;
    input [63:0]  expected;
    input [64*8-1:0] label;
    reg   [63:0]  actual;
    begin
      dmem_read(addr, actual);
      if (actual === expected) begin
        $display("  PASS  [%0s]  dmem[%0d] = 64'h%016X", label, addr, actual);
        pass_cnt = pass_cnt + 1;
      end else begin
        $display("  FAIL  [%0s]  dmem[%0d]  got=64'h%016X  expected=64'h%016X",
                 label, addr, actual, expected);
        fail_cnt = fail_cnt + 1;
      end
    end
  endtask

  // ===========================================================================
  // Helper: write a block of NOP words into imem starting at addr
  // Uses automatic reg to avoid blocking-assignment conflicts
  // ===========================================================================
  integer nop_i;
  task write_nops;
    input [8:0]   start_addr;
    input integer count;
    begin
      for (nop_i = 0; nop_i < count; nop_i = nop_i + 1)
        imem_write(start_addr + nop_i[8:0], `NOP);
    end
  endtask

  // ===========================================================================
  // IMEM write cursor – shared across tests (reset per test by do_reset)
  // ===========================================================================
  reg [8:0] iptr;   // current imem write pointer

  task iw;   // shorthand: write instruction at iptr then advance
    input [31:0] instr;
    begin
      imem_write(iptr, instr);
      iptr = iptr + 9'd1;
    end
  endtask

  task inops; // write N NOPs at iptr
    input integer n;
    integer k;
    begin
      for (k = 0; k < n; k = k + 1) begin
        imem_write(iptr, `NOP);
        iptr = iptr + 9'd1;
      end
    end
  endtask

  // ===========================================================================
  // MAIN TEST BODY
  // ===========================================================================
  integer      drain;   // cycles to let pipeline drain after last instruction
  reg   [63:0] tmp64;

  initial begin
    pass_cnt = 0;
    fail_cnt = 0;
    drain    = 20;        // extra cycles to flush all pipeline stages

    $dumpfile("tb_pipeline_p.vcd");
    $dumpvars(0, tb_pipeline_p);

    $display("");
    $display("============================================================");
    $display("  tb_pipeline_p  –  ARM pipeline testbench");
    $display("============================================================");

    // =========================================================================
    // T1 – T9  arithmetic, logic, load/store  (single program)
    // =========================================================================
    // All tests run as one continuous program so the imem only needs one load.
    // Seven NOPs between every dependent pair (pipeline depth = 7 cycles from
    // ID read to the cycle after WB write completes).
    // After the last instruction we run enough extra cycles to let it reach WB.

    $display("\n--- Loading test program (T1..T9) ---");
    do_reset;
    iptr = 9'd0;

    // ── T1: MOV R1, #42 ──────────────────────────────────────────────────────
    // Expected: R1 = 64'h000000000000002A
    iw(`ENC_MOV_IMM(4'd1, 8'd42));   // word 0
    inops(NOP_CNT);

    // ── T2: ADD R3 = R1(42) + R2(0→loaded below) ─────────────────────────────
    // First load R2 = 20 with MOV
    iw(`ENC_MOV_IMM(4'd2, 8'd20));   // word 8
    inops(NOP_CNT);
    // R1=42 is already in the register file; ADD R3, R1, R2
    // Expected: R3 = 62  (42+20)
    iw(`ENC_ADD_REG(4'd3, 4'd1, 4'd2));   // word 16
    inops(NOP_CNT);

    // ── T3: SUB R4 = R2(20) - R1(42) ─────────────────────────────────────────
    // Unsigned 64-bit subtraction: 20 - 42 = -22 wraps → 64'hFFFF_FFFF_FFFF_FFEA
    // Expected: R4 = 64'hFFFFFFFFFFFFFFEA
    iw(`ENC_SUB_REG(4'd4, 4'd2, 4'd1));   // word 24
    inops(NOP_CNT);

    // ── T4: AND R5 = R1(42=0x2A) & R2(20=0x14) ──────────────────────────────
    // 0x2A & 0x14 = 0x00
    // Expected: R5 = 64'h0000000000000000
    iw(`ENC_AND_REG(4'd5, 4'd1, 4'd2));   // word 32
    inops(NOP_CNT);

    // ── T5: ORR R6 = R1(42=0x2A) | R2(20=0x14) ──────────────────────────────
    // 0x2A | 0x14 = 0x3E
    // Expected: R6 = 64'h000000000000003E
    iw(`ENC_ORR_REG(4'd6, 4'd1, 4'd2));   // word 40
    inops(NOP_CNT);

    // ── T6: EOR R7 = R1(0x2A) EOR R2(0x14) ──────────────────────────────────
    // ALU_XNOR computes ~(A^B).
    // A=0x2A=0010_1010, B=0x14=0001_0100
    // A^B = 0011_1110 = 0x3E, ~(A^B) = ~0x3E = 0xFFF...FFC1
    // Expected: R7 = 64'hFFFFFFFFFFFFFFC1
    iw(`ENC_EOR_REG(4'd7, 4'd1, 4'd2));   // word 48
    inops(NOP_CNT);

    // ── T7: ADD R8 = R1(42) + #5  (immediate) ────────────────────────────────
    // Expected: R8 = 64'h000000000000002F (= 47)
    iw(`ENC_ADD_IMM(4'd8, 4'd1, 8'd5));   // word 56
    inops(NOP_CNT);

    // ── T8: SUB R9 = R2(20) - #3  (immediate) ────────────────────────────────
    // Expected: R9 = 64'h0000000000000011 (= 17)
    iw(`ENC_SUB_IMM(4'd9, 4'd2, 8'd3));   // word 64
    inops(NOP_CNT);

    // ── T9: STR then LDR roundtrip ────────────────────────────────────────────
    // We use dmem word address 5.
    // STR R1, [R0, #5]   → R0=0 (never written, reset=0), imm12=5 → alu=0+5=5 → dmem[5]
    // Then NOP_CNT NOPs
    // LDR R10, [R0, #5]  → reads dmem[5] back → R10 should equal R1 = 42
    // Expected: R10 = 64'h000000000000002A
    iw(`ENC_STR(4'd1, 4'd0, 12'd5));   // word 72
    inops(NOP_CNT);
    iw(`ENC_LDR(4'd10, 4'd0, 12'd5));  // word 80
    inops(NOP_CNT);

    // Trailing NOPs to flush LDR through all pipeline stages
    inops(drain);

    $display("  Program loaded (%0d words)", iptr);

    // Run the pipeline
    $display("  Running pipeline...");
    run_cycles(iptr + drain + 5);

    // Check all results
    $display("\n--- Checking T1..T9 results ---");
    check_reg(4'd1,  64'h000000000000002A, "T1 MOV R1=#42");
    check_reg(4'd2,  64'h0000000000000014, "T2a MOV R2=#20");
    check_reg(4'd3,  64'h000000000000003E, "T2 ADD R3=R1+R2");
    check_reg(4'd4,  64'hFFFFFFFFFFFFFFEA, "T3 SUB R4=R2-R1");
    check_reg(4'd5,  64'h0000000000000000, "T4 AND R5=R1&R2");
    check_reg(4'd6,  64'h000000000000003E, "T5 ORR R6=R1|R2");
    check_reg(4'd7,  64'hFFFFFFFFFFFFFFC1, "T6 EOR R7=R1^R2");
    check_reg(4'd8,  64'h000000000000002F, "T7 ADD_IMM R8=R1+5");
    check_reg(4'd9,  64'h0000000000000011, "T8 SUB_IMM R9=R2-3");
    check_reg(4'd10, 64'h000000000000002A, "T9 LDR R10=dmem[5]");
    // Also verify dmem directly
    check_dmem(8'd5, 64'h000000000000002A, "T9 STR→dmem[5]");

    // =========================================================================
    // T10 – Branch forward  (separate program)
    // =========================================================================
    // Program layout (word addresses):
    //
    //  0  MOV R11, #0          ; R11 = 0 (canary – should stay 0 if branch works)
    //  1..7  NOPs              ; hazard guard
    //  8  B offset=+1          ; jump to word 11  (offset = 11 - 8 - 2 = +1)
    //  9  ADD R11,R11,#1       ; MUST be skipped  (poison 1)
    // 10  ADD R11,R11,#1       ; MUST be skipped  (poison 2)
    // 11  MOV R12, #0xFF       ; branch lands here → R12 = 255
    // 12..18  NOPs             ; pipeline drain
    //
    // Branch target calc:
    //   ifid_pc when B is in ID = 8 (the word address where B was fetched)
    //   branch_target = ifid_pc + 2 + offset24 = 8 + 2 + 1 = 11  ✓
    $display("\n--- T10: Branch forward ---");
    do_reset;
    iptr = 9'd0;

    iw(`ENC_MOV_IMM(4'd11, 8'd0));              // word 0   R11=0
    inops(NOP_CNT);                              // words 1-7
    iw(`ENC_B(24'd1));                           // word 8   B → word 11
    iw(`ENC_ADD_IMM(4'd11, 4'd11, 8'd1));        // word 9   POISON (skipped)
    iw(`ENC_ADD_IMM(4'd11, 4'd11, 8'd1));        // word 10  POISON (skipped)
    iw(`ENC_MOV_IMM(4'd12, 8'hFF));             // word 11  LAND → R12=255
    inops(NOP_CNT);                              // drain
    inops(drain);

    run_cycles(iptr + drain + 5);

    check_reg(4'd11, 64'h0000000000000000, "T10 branch: R11 stays 0 (skip)");
    check_reg(4'd12, 64'h00000000000000FF, "T10 branch: R12=0xFF (land)");

    // =========================================================================
    // T11 – Step mode: pipeline stalls when run=0, step=0
    //                  advances exactly 1 word per step pulse
    // =========================================================================
    $display("\n--- T11: Step mode ---");
    do_reset;

    // Load a simple instruction at word 0 (just needs to exist)
    imem_write(9'd0, `ENC_MOV_IMM(4'd13, 8'd99));

    // With run=0, step=0: PC must stay at 0
    repeat (5) @(posedge clk); #1;
    if (pc_dbg === 9'd0) begin
      $display("  PASS  [T11 stall]  PC=0 while run=0,step=0");
      pass_cnt = pass_cnt + 1;
    end else begin
      $display("  FAIL  [T11 stall]  PC should be 0, got %0d", pc_dbg);
      fail_cnt = fail_cnt + 1;
    end

    // Issue one step pulse → PC should advance to 1
    single_step;
    if (pc_dbg === 9'd1) begin
      $display("  PASS  [T11 step1]  PC=1 after one step");
      pass_cnt = pass_cnt + 1;
    end else begin
      $display("  FAIL  [T11 step1]  PC should be 1, got %0d", pc_dbg);
      fail_cnt = fail_cnt + 1;
    end

    // Issue a second step pulse → PC should advance to 2
    single_step;
    if (pc_dbg === 9'd2) begin
      $display("  PASS  [T11 step2]  PC=2 after second step");
      pass_cnt = pass_cnt + 1;
    end else begin
      $display("  FAIL  [T11 step2]  PC should be 2, got %0d", pc_dbg);
      fail_cnt = fail_cnt + 1;
    end

    // Stall again: run 5 cycles with step=0, run=0 → PC must not change
    repeat (5) @(posedge clk); #1;
    if (pc_dbg === 9'd2) begin
      $display("  PASS  [T11 stall2] PC stays 2 after stall");
      pass_cnt = pass_cnt + 1;
    end else begin
      $display("  FAIL  [T11 stall2] PC should be 2, got %0d", pc_dbg);
      fail_cnt = fail_cnt + 1;
    end

    // =========================================================================
    // T12 – pc_reset_pulse returns PC to 0
    // =========================================================================
    $display("\n--- T12: pc_reset_pulse ---");
    // PC is at 2 from T11.  Run freely for a few cycles to move it higher.
    run_cycles(10);
    // PC should now be > 2
    if (pc_dbg > 9'd2) begin
      $display("  INFO  PC advanced to %0d before reset pulse", pc_dbg);
    end

    // Assert pc_reset_pulse for one cycle
    @(negedge clk);
    pc_reset_pulse = 1'b1;
    @(posedge clk); #1;
    pc_reset_pulse = 1'b0;
    @(posedge clk); #1;   // give one more cycle to settle

    if (pc_dbg === 9'd0) begin
      $display("  PASS  [T12]  PC=0 after pc_reset_pulse");
      pass_cnt = pass_cnt + 1;
    end else begin
      $display("  FAIL  [T12]  PC should be 0, got %0d", pc_dbg);
      fail_cnt = fail_cnt + 1;
    end

    // =========================================================================
    // T_DMEM – Data-memory prog-port preload then LDR read-back
    // =========================================================================
    // Write a known pattern into dmem word 7 via the prog port, then use
    // a pipeline LDR to read it into a register.
    $display("\n--- T_DMEM: dmem preload + LDR readback ---");
    do_reset;

    // Pre-load dmem word address 7 with a known value via prog port
    dmem_write(8'd7, 64'hDEAD_BEEF_CAFE_1234);

    iptr = 9'd0;
    // LDR R14, [R0, #7]  → R0=0 (reset default), imm12=7 → alu=7 → dmem[7]
    // Expected: R14 = 64'hDEAD_BEEF_CAFE_1234
    iw(`ENC_LDR(4'd14, 4'd0, 12'd7));
    inops(NOP_CNT + drain);

    run_cycles(iptr + drain + 5);

    check_reg(4'd14, 64'hDEADBEEFCAFE1234, "T_DMEM LDR R14=dmem[7]");

    // =========================================================================
    // SUMMARY
    // =========================================================================
    $display("");
    $display("============================================================");
    $display("  RESULTS :  %0d passed,  %0d failed",  pass_cnt, fail_cnt);
    if (fail_cnt == 0)
      $display("  ALL TESTS PASSED");
    else
      $display("  *** FAILURES DETECTED – inspect waveform tb_pipeline_p.vcd ***");
    $display("============================================================");
    $display("");
    $finish;
  end

  // ===========================================================================
  // Timeout watchdog
  // ===========================================================================
  initial begin
    #2_000_000;
    $display("TIMEOUT – simulation exceeded 2 ms");
    $finish;
  end

  // ===========================================================================
  // Continuous pipeline monitor – prints every 20 cycles while running
  // ===========================================================================
  integer cyc;
  initial cyc = 0;
  always @(posedge clk) begin
    cyc = cyc + 1;
    if (run && (cyc % 20 == 0))
      $display("  [cyc %0d]  PC=%0d  IF_INSTR=0x%08X", cyc, pc_dbg, if_instr_dbg);
  end

endmodule
