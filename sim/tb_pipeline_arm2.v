`timescale 1ns/1ps
// =============================================================================
// tb_pipeline_p_ext.v  –  Testbench for extended pipeline_p.v
//
// Tests all new instructions:
//   T1  SLL  Rd,Rn,Rm    shift left  by Rm[5:0]
//   T2  SRL  Rd,Rn,Rm    shift right by Rm[5:0]
//   T3  SLT  Rd,Rn,Rm    set less than (signed)
//   T4  BEQ  Rn,Rm,off   branch if equal    (taken and not-taken)
//   T5  BNE  Rn,Rm,off   branch if not-equal (taken and not-taken)
//   T6  J    target       absolute jump
//   T7  JR   Rm           jump register (= BX Rm)
//
// Plus regression for original instructions still working:
//   T0  MOV / ADD / SUB / AND / ORR / LDR / STR / B
//
// Encoding functions (all Verilog functions – no `define macros to avoid
// the "[SE] token is '['" error from bit-selects on macro arguments):
//
//   SLL  {4'hE, 3'b000, 4'b0110, 1'b0, Rn, Rd, 8'h00, Rm}
//   SRL  {4'hE, 3'b000, 4'b0111, 1'b0, Rn, Rd, 8'h00, Rm}
//   SLT  {4'hE, 3'b000, 4'b1011, 1'b0, Rn, Rd, 8'h00, Rm}
//   J    {6'b111010, 17'b0, target9[8:0]}
//   JR   {4'hE, 24'h12FFF1, Rm[3:0]}
//   BEQ  {4'hE, 4'b1000, Rn, Rm, 16'(off16)}
//   BNE  {4'hE, 4'b1001, Rn, Rm, 16'(off16)}
//     off16 = target_word_addr - BEQ/BNE_word_addr - 2
//
// Pipeline depth:  IF→IF/ID→ID→ID/EX→EX→EX/MEM→MEM→MEM/WB→WB
//   5 register hops from ID-read to WB-write.
//   Consumer must enter ID ≥ 6 advance-cycles after producer.
//   => 7 NOPs between dependent instructions (safe margin).
//   Branches need 2 flush bubbles; land instruction at word B+3 or later
//   to avoid the bubble instructions being useful (programmer responsibility).
// =============================================================================

module tb_pipeline_p_ext;

  // ─── DUT ports ─────────────────────────────────────────────────────────────
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

  // ─── Counters ──────────────────────────────────────────────────────────────
  integer pass_count;
  integer fail_count;

  // ─── DUT instantiation ─────────────────────────────────────────────────────
  pipeline dut (
    .clk            (clk),
    .reset          (reset),
    .run            (run),
    .step           (step),
    .pc_reset_pulse (pc_reset_pulse),
    .imem_prog_we   (imem_prog_we),
    .imem_prog_addr (imem_prog_addr),
    .imem_prog_wdata(imem_prog_wdata),
    .dmem_prog_en   (dmem_prog_en),
    .dmem_prog_we   (dmem_prog_we),
    .dmem_prog_addr (dmem_prog_addr),
    .dmem_prog_wdata(dmem_prog_wdata),
    .dmem_prog_rdata(dmem_prog_rdata),
    .pc_dbg         (pc_dbg),
    .if_instr_dbg   (if_instr_dbg)
  );

  // Hierarchical register file path
  `define RF dut.u_rf.regFile

  // ─── Clock (10 ns period) ──────────────────────────────────────────────────
  localparam CLK_PERIOD = 10;
  initial clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  // ===========================================================================
  // Instruction encoding functions
  // ===========================================================================
  localparam NOP = 32'hE000_0000;   // AND R0,R0,R0

  // MOV Rd, #imm8
  function [31:0] f_mov;
    input [3:0] Rd; input [7:0] imm8;
    f_mov = {4'hE, 3'b001, 4'b1101, 1'b0, 4'h0, Rd, 4'h0, imm8};
  endfunction

  // ADD Rd, Rn, Rm  (register)
  function [31:0] f_add_r;
    input [3:0] Rd, Rn, Rm;
    f_add_r = {4'hE, 3'b000, 4'b0100, 1'b0, Rn, Rd, 8'h00, Rm};
  endfunction

  // SUB Rd, Rn, Rm  (register)
  function [31:0] f_sub_r;
    input [3:0] Rd, Rn, Rm;
    f_sub_r = {4'hE, 3'b000, 4'b0010, 1'b0, Rn, Rd, 8'h00, Rm};
  endfunction

  // ADD Rd, Rn, #imm8  (immediate)
  function [31:0] f_add_i;
    input [3:0] Rd, Rn; input [7:0] imm8;
    f_add_i = {4'hE, 3'b001, 4'b0100, 1'b0, Rn, Rd, 4'h0, imm8};
  endfunction

  // SLL Rd, Rn, Rm   (shift left by Rm[5:0])
  function [31:0] f_sll;
    input [3:0] Rd, Rn, Rm;
    // op=00 I=0 opcode=0110
    f_sll = {4'hE, 3'b000, 4'b0110, 1'b0, Rn, Rd, 8'h00, Rm};
  endfunction

  // SRL Rd, Rn, Rm   (shift right by Rm[5:0])
  function [31:0] f_srl;
    input [3:0] Rd, Rn, Rm;
    // op=00 I=0 opcode=0111
    f_srl = {4'hE, 3'b000, 4'b0111, 1'b0, Rn, Rd, 8'h00, Rm};
  endfunction

  // SLT Rd, Rn, Rm   (Rd = (Rn < Rm) ? 1 : 0, signed)
  function [31:0] f_slt;
    input [3:0] Rd, Rn, Rm;
    // op=00 I=0 opcode=1011
    f_slt = {4'hE, 3'b000, 4'b1011, 1'b0, Rn, Rd, 8'h00, Rm};
  endfunction

  // BEQ Rn, Rm, off16   (branch if Rn == Rm)
  // off16 = target_word_addr - BEQ_word_addr - 2
  function [31:0] f_beq;
    input [3:0]  Rn, Rm;
    input [15:0] off16;
    f_beq = {4'hE, 4'b1000, Rn, Rm, off16};
  endfunction

  // BNE Rn, Rm, off16   (branch if Rn != Rm)
  function [31:0] f_bne;
    input [3:0]  Rn, Rm;
    input [15:0] off16;
    f_bne = {4'hE, 4'b1001, Rn, Rm, off16};
  endfunction

  // B off24  (unconditional branch)
  // off24 = target_word_addr - B_word_addr - 2
  function [31:0] f_b;
    input [23:0] off24;
    f_b = {4'hE, 4'b1010, off24};
  endfunction

  // J target9   (absolute jump to 9-bit word address)
  function [31:0] f_j;
    input [8:0] target;
    // inst[31:26]=6'b111010, inst[25:9]=0, inst[8:0]=target
    f_j = {6'b111010, 17'b0, target};
  endfunction

  // JR Rm   (= BX Rm, jump to address in register)
  function [31:0] f_jr;
    input [3:0] Rm;
    f_jr = {4'hE, 24'h12FFF1, Rm};
  endfunction

  // STR Rd, [Rn, #off12]
  function [31:0] f_str;
    input [3:0]  Rd, Rn; input [11:0] off12;
    f_str = {4'hE, 8'b0101_1000, Rn, Rd, off12};
  endfunction

  // LDR Rd, [Rn, #off12]
  function [31:0] f_ldr;
    input [3:0]  Rd, Rn; input [11:0] off12;
    f_ldr = {4'hE, 8'b0101_1001, Rn, Rd, off12};
  endfunction

  // ===========================================================================
  // Tasks  (same @posedge clk; #1 discipline as reference testbench)
  // ===========================================================================

  task program_imem_word;
    input [8:0]  addr;
    input [31:0] data;
    begin
      run = 1'b0; step = 1'b0;
      imem_prog_addr  = addr;
      imem_prog_wdata = data;
      imem_prog_we    = 1'b1;
      @(posedge clk); #1;
      imem_prog_we = 1'b0;
    end
  endtask

  task program_dmem_word;
    input [7:0]  addr;
    input [63:0] data;
    begin
      run = 1'b0; step = 1'b0;
      dmem_prog_addr  = addr;
      dmem_prog_wdata = data;
      dmem_prog_en    = 1'b1;
      dmem_prog_we    = 1'b1;
      @(posedge clk); #1;
      dmem_prog_we = 1'b0;
      dmem_prog_en = 1'b0;
    end
  endtask

  task read_dmem_word;
    input  [7:0]  addr;
    output [63:0] data;
    begin
      run = 1'b0; step = 1'b0;
      dmem_prog_addr  = addr;
      dmem_prog_en    = 1'b1;
      dmem_prog_we    = 1'b0;
      dmem_prog_wdata = 64'h0;
      @(posedge clk); #1;
      data = dmem_prog_rdata;
      dmem_prog_en = 1'b0;
      @(posedge clk); #1;
    end
  endtask

  task pulse_pc_reset;
    begin
      pc_reset_pulse = 1'b1;
      @(posedge clk); #1;
      pc_reset_pulse = 1'b0;
      @(posedge clk); #1;
    end
  endtask

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
      repeat (4) @(posedge clk); #1;
      reset = 1'b0;
      @(posedge clk); #1;
    end
  endtask

  // ─── Run N cycles ──────────────────────────────────────────────────────────
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
  // WB monitor
  // ===========================================================================
  always @(posedge clk) begin
    if (!reset && dut.wb_wen)
      $display("[%0t] WB  R%0d <- 0x%016h  (pc=%0d)", $time,
               dut.wb_waddr, dut.wb_wdata, pc_dbg);
  end

  // ===========================================================================
  // Check helpers
  // ===========================================================================
  task check_reg;
    input [3:0]   rn;
    input [63:0]  expected;
    input [127:0] label;
    reg   [63:0]  actual;
    begin
      actual = `RF[rn];
      if (actual === expected) begin
        $display("  PASS  %-28s  R%0d = 0x%016h", label, rn, actual);
        pass_count = pass_count + 1;
      end else begin
        $display("  FAIL  %-28s  R%0d  got=0x%016h  exp=0x%016h",
                 label, rn, actual, expected);
        fail_count = fail_count + 1;
      end
    end
  endtask

  // ===========================================================================
  // Helper: write a NOP-padded program, reset PC, and run it
  // (addr_next = address of next free word after user filled words)
  // We add 15 drain NOPs then run addr_next+20 cycles.
  // ===========================================================================
  integer addr;  // shared word address counter

  task drain_and_run;
    input integer extra_cycles;
    integer i;
    begin
      // 15 drain NOPs to flush last real instruction through all 5 stages
      for (i = 0; i < 15; i = i + 1) begin
        program_imem_word(addr[8:0], NOP);
        addr = addr + 1;
      end
      pulse_pc_reset();
      run_cycles(addr + extra_cycles);
    end
  endtask

  // ===========================================================================
  // MAIN TEST
  // ===========================================================================
  reg [63:0] rd0;

  initial begin
    pass_count     = 0;
    fail_count     = 0;
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

    $dumpfile("tb_pipeline_p_ext.vcd");
    $dumpvars(0, tb_pipeline_p_ext);

    $display("======================================================");
    $display("  Extended Pipeline Testbench (SLL/SRL/SLT/BEQ/BNE/J/JR)");
    $display("======================================================");

    repeat (3) @(posedge clk); #1;
    reset = 1'b0;
    @(posedge clk); #1;

    // =========================================================================
    // TEST 0 – Regression: MOV / ADD / SUB  (existing instructions)
    // Confirm we didn't break the original decoder.
    //
    //  word 0   MOV R1, #10
    //  word 1-7  NOP x7
    //  word 8   MOV R2, #20
    //  word 9-15 NOP x7
    //  word 16  ADD R3, R1, R2      R3 = 30  (0x1E)
    //  word 17-23 NOP x7
    //  word 24  SUB R4, R2, R1      R4 = 10  (0x0A)
    //  word 25-39 drain
    // =========================================================================
    $display("\n--- TEST 0: Regression (MOV/ADD/SUB) ---");
    do_reset;
    addr = 0;

    program_imem_word(addr, f_mov(4'd1, 8'd10));  addr=addr+1;
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end

    program_imem_word(addr, f_mov(4'd2, 8'd20));  addr=addr+1;
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end

    program_imem_word(addr, f_add_r(4'd3, 4'd1, 4'd2)); addr=addr+1;
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end

    program_imem_word(addr, f_sub_r(4'd4, 4'd2, 4'd1)); addr=addr+1;
    drain_and_run(10);

    check_reg(4'd1, 64'h000000000000000A, "MOV R1,#10");
    check_reg(4'd2, 64'h0000000000000014, "MOV R2,#20");
    check_reg(4'd3, 64'h000000000000001E, "ADD R3=R1+R2 (30)");
    check_reg(4'd4, 64'h000000000000000A, "SUB R4=R2-R1 (10)");

    // =========================================================================
    // TEST 1 – SLL  (Shift Left by variable amount)
    //
    //  word 0   MOV R1, #1          R1 = 1
    //  word 1-7  NOP x7
    //  word 8   MOV R2, #4          R2 = 4  (shift amount)
    //  word 9-15 NOP x7
    //  word 16  SLL R3, R1, R2      R3 = 1 << 4 = 16  (0x10)
    //  word 17-23 NOP x7
    //  word 24  MOV R4, #0xFF       R4 = 255
    //  word 25-31 NOP x7
    //  word 32  MOV R5, #3          R5 = 3  (shift amount)
    //  word 33-39 NOP x7
    //  word 40  SLL R6, R4, R5      R6 = 255 << 3 = 2040  (0x7F8)
    //  word 41+ drain
    // =========================================================================
    $display("\n--- TEST 1: SLL (variable shift left) ---");
    do_reset;
    addr = 0;

    program_imem_word(addr, f_mov(4'd1, 8'd1));   addr=addr+1; // R1=1
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end

    program_imem_word(addr, f_mov(4'd2, 8'd4));   addr=addr+1; // R2=4 (shift amount)
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end

    program_imem_word(addr, f_sll(4'd3, 4'd1, 4'd2)); addr=addr+1; // R3=1<<4=16
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end

    program_imem_word(addr, f_mov(4'd4, 8'hFF)); addr=addr+1;  // R4=255
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end

    program_imem_word(addr, f_mov(4'd5, 8'd3));   addr=addr+1; // R5=3
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end

    program_imem_word(addr, f_sll(4'd6, 4'd4, 4'd5)); addr=addr+1; // R6=255<<3=2040
    drain_and_run(10);

    check_reg(4'd3, 64'h0000000000000010, "SLL R3=R1<<R2 (1<<4=16)");
    check_reg(4'd6, 64'h00000000000007F8, "SLL R6=R4<<R5 (255<<3=2040)");

    // =========================================================================
    // TEST 2 – SRL  (Shift Right by variable amount)
    //
    //  word 0   MOV R1, #0x80      R1 = 128
    //  word 1-7  NOP x7
    //  word 8   MOV R2, #3         R2 = 3
    //  word 9-15 NOP x7
    //  word 16  SRL R3, R1, R2     R3 = 128 >> 3 = 16  (0x10)
    //  word 17-23 NOP x7
    //  word 24  MOV R4, #0xFF      R4 = 255
    //  word 25-31 NOP x7
    //  word 32  MOV R5, #4         R5 = 4
    //  word 33-39 NOP x7
    //  word 40  SRL R6, R4, R5     R6 = 255 >> 4 = 15  (0x0F)
    //  word 41+ drain
    // =========================================================================
    $display("\n--- TEST 2: SRL (variable shift right) ---");
    do_reset;
    addr = 0;

    program_imem_word(addr, f_mov(4'd1, 8'h80)); addr=addr+1;  // R1=128
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end

    program_imem_word(addr, f_mov(4'd2, 8'd3));  addr=addr+1;  // R2=3
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end

    program_imem_word(addr, f_srl(4'd3, 4'd1, 4'd2)); addr=addr+1; // R3=128>>3=16
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end

    program_imem_word(addr, f_mov(4'd4, 8'hFF)); addr=addr+1;  // R4=255
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end

    program_imem_word(addr, f_mov(4'd5, 8'd4));  addr=addr+1;  // R5=4
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end

    program_imem_word(addr, f_srl(4'd6, 4'd4, 4'd5)); addr=addr+1; // R6=255>>4=15
    drain_and_run(10);

    check_reg(4'd3, 64'h0000000000000010, "SRL R3=R1>>R2 (128>>3=16)");
    check_reg(4'd6, 64'h000000000000000F, "SRL R6=R4>>R5 (255>>4=15)");

    // =========================================================================
    // TEST 3 – SLT  (Set Less Than, signed)
    //
    // Case A: Rn < Rm  → Rd should be 1
    //  word 0   MOV R1, #5          R1 = 5
    //  word 1-7  NOP x7
    //  word 8   MOV R2, #10         R2 = 10
    //  word 9-15 NOP x7
    //  word 16  SLT R3, R1, R2      R3 = (5 < 10) = 1
    //  word 17-23 NOP x7
    //
    // Case B: Rn >= Rm → Rd should be 0
    //  word 24  SLT R4, R2, R1      R4 = (10 < 5) = 0
    //  word 25-31 NOP x7
    //
    // Case C: Equal → Rd should be 0
    //  word 32  SLT R5, R1, R1      R5 = (5 < 5) = 0
    //  word 33+ drain
    // =========================================================================
    $display("\n--- TEST 3: SLT (set less than, signed) ---");
    do_reset;
    addr = 0;

    program_imem_word(addr, f_mov(4'd1, 8'd5));   addr=addr+1; // R1=5
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end

    program_imem_word(addr, f_mov(4'd2, 8'd10));  addr=addr+1; // R2=10
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end

    program_imem_word(addr, f_slt(4'd3, 4'd1, 4'd2)); addr=addr+1; // R3=(5<10)=1
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end

    program_imem_word(addr, f_slt(4'd4, 4'd2, 4'd1)); addr=addr+1; // R4=(10<5)=0
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end

    program_imem_word(addr, f_slt(4'd5, 4'd1, 4'd1)); addr=addr+1; // R5=(5<5)=0
    drain_and_run(10);

    check_reg(4'd3, 64'h0000000000000001, "SLT R3=(5<10)=1");
    check_reg(4'd4, 64'h0000000000000000, "SLT R4=(10<5)=0");
    check_reg(4'd5, 64'h0000000000000000, "SLT R5=(5<5)=0");

    // =========================================================================
    // TEST 4 – BEQ  (branch if equal)
    //
    // Case A: taken  (R1 == R2)
    //  word 0   MOV R1, #7
    //  word 1-7  NOP x7
    //  word 8   MOV R2, #7           R2 = R1 = 7 → will be equal
    //  word 9-15 NOP x7
    //  word 16  BEQ R1,R2,+3         offset=3 → target=16+2+3=21
    //  word 17  ADD R3,R3,#1         POISON – should be skipped
    //  word 18  ADD R3,R3,#1         POISON (in flush bubble, skipped)
    //  word 19  ADD R3,R3,#1         POISON (in flush bubble, skipped)
    //  word 20  ADD R3,R3,#1         POISON – should be skipped
    //  word 21  MOV R4, #0xAA        LAND – R4=0xAA
    //  word 22+ NOP x7
    //  word 29  ...
    //
    // Case B: not taken  (R5 != R6)
    //  word 30  MOV R5, #3
    //  word 31-37 NOP x7
    //  word 38  MOV R6, #9
    //  word 39-45 NOP x7
    //  word 46  BEQ R5,R6,+5         not taken (3 != 9)
    //  word 47  ADD R7,R0,#0x55      EXECUTED (fall through) → R7=0x55
    //  word 48+ drain
    //
    //  R3 must be 0 (poison skipped), R4 must be 0xAA (landing executed)
    //  R7 must be 0x55 (fall-through after not-taken BEQ)
    // =========================================================================
    $display("\n--- TEST 4: BEQ (branch if equal) ---");
    do_reset;
    addr = 0;

    // ── Case A: taken ────────────────────────────────────────────────────────
    // words 0-7
    program_imem_word(addr, f_mov(4'd1, 8'd7));  addr=addr+1;  // word 0
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end // 1-7

    // words 8-15
    program_imem_word(addr, f_mov(4'd2, 8'd7));  addr=addr+1;  // word 8
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end // 9-15

    // word 16: BEQ R1,R2, offset=+3 → target=16+2+3=21
    program_imem_word(addr, f_beq(4'd1, 4'd2, 16'd3)); addr=addr+1; // word 16

    // words 17-20: poison instructions (must NOT execute)
    program_imem_word(addr, f_add_i(4'd3, 4'd3, 8'd1)); addr=addr+1; // 17 POISON
    program_imem_word(addr, f_add_i(4'd3, 4'd3, 8'd1)); addr=addr+1; // 18 POISON
    program_imem_word(addr, f_add_i(4'd3, 4'd3, 8'd1)); addr=addr+1; // 19 POISON
    program_imem_word(addr, f_add_i(4'd3, 4'd3, 8'd1)); addr=addr+1; // 20 POISON

    // word 21: branch landing (addr should be 21 here)
    if (addr !== 9'd21) $display("WARNING: BEQ landing not at word 21, got %0d", addr);
    program_imem_word(addr, f_mov(4'd4, 8'hAA)); addr=addr+1; // word 21 LAND
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end // 22-28

    // ── Case B: not taken ─────────────────────────────────────────────────────
    // word 29
    program_imem_word(addr, f_mov(4'd5, 8'd3));  addr=addr+1;  // word 29: R5=3
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end // 30-36
    program_imem_word(addr, f_mov(4'd6, 8'd9));  addr=addr+1;  // word 37: R6=9
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end // 38-44
    // word 45: BEQ R5,R6 – NOT taken (3 != 9)
    program_imem_word(addr, f_beq(4'd5, 4'd6, 16'd5)); addr=addr+1; // 45
    // word 46: fall-through, MUST execute
    program_imem_word(addr, f_add_i(4'd7, 4'd0, 8'h55)); addr=addr+1; // 46: R7=0x55
    drain_and_run(10);

    check_reg(4'd3, 64'h0000000000000000, "BEQ taken: R3=0 (poison skipped)");
    check_reg(4'd4, 64'h00000000000000AA, "BEQ taken: R4=0xAA (landing)");
    check_reg(4'd7, 64'h0000000000000055, "BEQ not-taken: R7=0x55 (fallthru)");

    // =========================================================================
    // TEST 5 – BNE  (branch if not equal)
    //
    // Case A: taken  (R1 != R2)
    //  word 0   MOV R1, #3
    //  word 1-7  NOP x7
    //  word 8   MOV R2, #9
    //  word 9-15 NOP x7
    //  word 16  BNE R1,R2,+4         target=16+2+4=22
    //  word 17-21: POISON
    //  word 22  MOV R3, #0xBB        LAND → R3=0xBB
    //  word 23-29 NOP
    //
    // Case B: not taken  (R4 == R5)
    //  word 30  MOV R4, #6
    //  word 31-37 NOP
    //  word 38  MOV R5, #6
    //  word 39-45 NOP
    //  word 46  BNE R4,R5,+5         not taken (6 == 6)
    //  word 47  ADD R6,R0,#0xCC      EXECUTED → R6=0xCC
    //  drain
    // =========================================================================
    $display("\n--- TEST 5: BNE (branch if not equal) ---");
    do_reset;
    addr = 0;

    // Case A: taken
    program_imem_word(addr, f_mov(4'd1, 8'd3));  addr=addr+1;  // word 0: R1=3
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end // 1-7
    program_imem_word(addr, f_mov(4'd2, 8'd9));  addr=addr+1;  // word 8: R2=9
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end // 9-15
    // word 16: BNE R1,R2, offset=+4 → target=16+2+4=22
    program_imem_word(addr, f_bne(4'd1, 4'd2, 16'd4)); addr=addr+1; // word 16

    // words 17-21: poison
    program_imem_word(addr, f_add_i(4'd8, 4'd8, 8'd1)); addr=addr+1; // 17 POISON
    program_imem_word(addr, f_add_i(4'd8, 4'd8, 8'd1)); addr=addr+1; // 18 POISON
    program_imem_word(addr, f_add_i(4'd8, 4'd8, 8'd1)); addr=addr+1; // 19 POISON
    program_imem_word(addr, f_add_i(4'd8, 4'd8, 8'd1)); addr=addr+1; // 20 POISON
    program_imem_word(addr, f_add_i(4'd8, 4'd8, 8'd1)); addr=addr+1; // 21 POISON

    // word 22: landing
    if (addr !== 9'd22) $display("WARNING: BNE landing not at word 22, got %0d", addr);
    program_imem_word(addr, f_mov(4'd3, 8'hBB)); addr=addr+1; // word 22 LAND
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end // 23-29

    // Case B: not taken
    program_imem_word(addr, f_mov(4'd4, 8'd6));  addr=addr+1;  // word 30: R4=6
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end // 31-37
    program_imem_word(addr, f_mov(4'd5, 8'd6));  addr=addr+1;  // word 38: R5=6
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end // 39-45
    // word 46: BNE R4,R5 – not taken (6 == 6)
    program_imem_word(addr, f_bne(4'd4, 4'd5, 16'd5)); addr=addr+1; // 46
    // word 47: fall-through
    program_imem_word(addr, f_add_i(4'd6, 4'd0, 8'hCC)); addr=addr+1; // 47: R6=0xCC
    drain_and_run(10);

    check_reg(4'd3, 64'h00000000000000BB, "BNE taken: R3=0xBB (landing)");
    check_reg(4'd8, 64'h0000000000000000, "BNE taken: R8=0 (poison skipped)");
    check_reg(4'd6, 64'h00000000000000CC, "BNE not-taken: R6=0xCC (fallthru)");

    // =========================================================================
    // TEST 6 – J  (absolute jump to 9-bit word address)
    //
    //  word 0   MOV R1, #0          canary
    //  word 1-7  NOP x7
    //  word 8   J  target=20        jump to word 20 (absolute)
    //  word 9   ADD R1,R1,#1        POISON
    //  word 10  ADD R1,R1,#1        POISON
    //  ...
    //  word 19  ADD R1,R1,#1        POISON
    //  word 20  MOV R2, #0xDD       LAND → R2=0xDD
    //  word 21+ drain
    // =========================================================================
    $display("\n--- TEST 6: J (absolute jump) ---");
    do_reset;
    addr = 0;

    program_imem_word(addr, f_mov(4'd1, 8'd0));  addr=addr+1; // word 0: canary R1=0
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end // 1-7

    // word 8: J target=20
    program_imem_word(addr, f_j(9'd20));  addr=addr+1;        // word 8

    // words 9-19: poison
    repeat(11) begin
      program_imem_word(addr, f_add_i(4'd1, 4'd1, 8'd1));
      addr=addr+1;
    end

    // word 20: landing (addr should be 20)
    if (addr !== 9'd20) $display("WARNING: J landing not at word 20, got %0d", addr);
    program_imem_word(addr, f_mov(4'd2, 8'hDD)); addr=addr+1; // word 20 LAND
    drain_and_run(10);

    check_reg(4'd1, 64'h0000000000000000, "J: R1=0 (poison skipped)");
    check_reg(4'd2, 64'h00000000000000DD, "J: R2=0xDD (landing)");

    // =========================================================================
    // TEST 7 – JR  (jump register = BX Rm)
    //
    // Load target word address 30 into R9, then JR R9.
    //
    //  word 0   MOV R9, #30         R9 = 30 (target word address)
    //  word 1-7  NOP x7
    //  word 8   JR R9               jump to word 30
    //  word 9   ADD R1,R1,#1        POISON
    //  ...
    //  word 29  ADD R1,R1,#1        POISON
    //  word 30  MOV R2, #0xEE       LAND → R2=0xEE
    //  word 31+ drain
    // =========================================================================
    $display("\n--- TEST 7: JR (jump register) ---");
    do_reset;
    addr = 0;

    program_imem_word(addr, f_mov(4'd1, 8'd0));  addr=addr+1; // word 0: R1=0 canary
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end // 1-7

    // word 8: load target address into R9
    // Trick: R9 will hold 30, but we need to load it *before* JR.
    // Use another register as a dummy – but R9's value at JR comes from
    // the register file *before* JR is decoded.
    // Simple approach: put the MOV R9,#30 at word 0 and ensure 7 NOPs before JR.
    // Re-order program:
    //   word 0:   MOV R9, #30
    //   word 1-7: NOP
    //   word 8:   JR R9
    //   words 9-29: poison
    //   word 30:  MOV R2, #0xEE

    // Already wrote word 0 as MOV R1,#0 (canary).  Restart program cleanly.
    do_reset;
    addr = 0;

    program_imem_word(addr, f_mov(4'd9, 8'd30)); addr=addr+1; // word 0: R9=30
    repeat(7) begin program_imem_word(addr, NOP); addr=addr+1; end // 1-7

    // word 8: JR R9  (jump to address in R9 = 30)
    program_imem_word(addr, f_jr(4'd9));  addr=addr+1;        // word 8

    // words 9-29: poison
    repeat(21) begin
      program_imem_word(addr, f_add_i(4'd1, 4'd1, 8'd1));
      addr=addr+1;
    end

    // word 30: landing
    if (addr !== 9'd30) $display("WARNING: JR landing not at word 30, got %0d", addr);
    program_imem_word(addr, f_mov(4'd2, 8'hEE)); addr=addr+1; // word 30 LAND
    drain_and_run(10);

    check_reg(4'd1, 64'h0000000000000000, "JR: R1=0 (poison skipped)");
    check_reg(4'd2, 64'h00000000000000EE, "JR: R2=0xEE (landing)");

    // =========================================================================
    // SUMMARY
    // =========================================================================
    $display("\n======================================================");
    $display("  Results:  %0d PASSED   %0d FAILED", pass_count, fail_count);
    $display("======================================================");
    if (fail_count == 0)
      $display("  ALL TESTS PASSED");
    else
      $display("  *** FAILURES – inspect tb_pipeline_p_ext.vcd ***");
    $display("======================================================\n");

    $finish;
  end

  // ─── Watchdog ──────────────────────────────────────────────────────────────
  initial begin
    #1_000_000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
