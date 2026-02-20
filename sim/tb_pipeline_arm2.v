`timescale 1ns/1ps
// =============================================================================
// tb_pipeline_p_ext.v  ?  Testbench for extended pipeline_p.v
//
// Tests all new instructions:
//   T0  MOV / ADD / SUB  regression
//   T1  SLL  Rd,Rn,Rm    shift left  by Rm[5:0]
//   T2  SRL  Rd,Rn,Rm    shift right by Rm[5:0]
//   T3  SLT  Rd,Rn,Rm    set less than (signed)
//   T4  BEQ  Rn,Rm,off   branch if equal    (taken and not-taken)
//   T5  BNE  Rn,Rm,off   branch if not-equal (taken and not-taken)
//   T6  J    target       absolute jump
//   T7  JR   Rm           jump register (= BX Rm)
//   T8  BL + JR           branch-and-link full call/return
//
// Rule enforced throughout:
//   4 NOPs are inserted immediately after every J, JR, BEQ, BNE instruction.
//   This gives the pipeline time to redirect before any fall-through
//   instruction reaches ID, eliminating spurious executions.
//
// Instruction encodings:
//   NOP  32'hE000_0000
//   MOV  Rd,#imm8     {4'hE,3'b001,4'b1101,1'b0,4'h0,Rd,4'h0,imm8}
//   ADD  Rd,Rn,Rm     {4'hE,3'b000,4'b0100,1'b0,Rn,Rd,8'h00,Rm}
//   ADD  Rd,Rn,#imm8  {4'hE,3'b001,4'b0100,1'b0,Rn,Rd,4'h0,imm8}
//   SUB  Rd,Rn,Rm     {4'hE,3'b000,4'b0010,1'b0,Rn,Rd,8'h00,Rm}
//   SLL  Rd,Rn,Rm     {4'hE,3'b000,4'b0110,1'b0,Rn,Rd,8'h00,Rm}
//   SRL  Rd,Rn,Rm     {4'hE,3'b000,4'b0111,1'b0,Rn,Rd,8'h00,Rm}
//   SLT  Rd,Rn,Rm     {4'hE,3'b000,4'b1011,1'b0,Rn,Rd,8'h00,Rm}
//   BEQ  Rn,Rm,off16  {4'hE,4'b1000,Rn,Rm,off16}
//   BNE  Rn,Rm,off16  {4'hE,4'b1001,Rn,Rm,off16}
//   J    target9      {6'b111010,17'b0,target9}
//   JR   Rm           {4'hE,24'h12FFF1,Rm}
//   BL   off24        {4'hE,4'b1011,off24}
//
//   off16/off24 = target_word_addr - branch_word_addr - 2
//
// Pipeline depth: 7 NOPs between dependent instructions (safe margin).
// =============================================================================

module tb_pipeline_p_ext;

  // ??? DUT ports ?????????????????????????????????????????????????????????????
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

  // ??? Counters ??????????????????????????????????????????????????????????????
  integer pass_count;
  integer fail_count;

  // ??? DUT ???????????????????????????????????????????????????????????????????
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

  `define RF dut.u_rf.regFile

  // ??? Clock ?????????????????????????????????????????????????????????????????
  localparam CLK_PERIOD = 10;
  initial clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  // ===========================================================================
  // Encoding functions
  // ===========================================================================
  localparam NOP = 32'hE000_0000;

  function [31:0] f_mov;
    input [3:0] Rd; input [7:0] imm8;
    f_mov = {4'hE, 3'b001, 4'b1101, 1'b0, 4'h0, Rd, 4'h0, imm8};
  endfunction

  function [31:0] f_add_r;
    input [3:0] Rd, Rn, Rm;
    f_add_r = {4'hE, 3'b000, 4'b0100, 1'b0, Rn, Rd, 8'h00, Rm};
  endfunction

  function [31:0] f_add_i;
    input [3:0] Rd, Rn; input [7:0] imm8;
    f_add_i = {4'hE, 3'b001, 4'b0100, 1'b0, Rn, Rd, 4'h0, imm8};
  endfunction

  function [31:0] f_sub_r;
    input [3:0] Rd, Rn, Rm;
    f_sub_r = {4'hE, 3'b000, 4'b0010, 1'b0, Rn, Rd, 8'h00, Rm};
  endfunction

  function [31:0] f_sll;
    input [3:0] Rd, Rn, Rm;
    f_sll = {4'hE, 3'b000, 4'b0110, 1'b0, Rn, Rd, 8'h00, Rm};
  endfunction

  function [31:0] f_srl;
    input [3:0] Rd, Rn, Rm;
    f_srl = {4'hE, 3'b000, 4'b0111, 1'b0, Rn, Rd, 8'h00, Rm};
  endfunction

  function [31:0] f_slt;
    input [3:0] Rd, Rn, Rm;
    f_slt = {4'hE, 3'b000, 4'b1011, 1'b0, Rn, Rd, 8'h00, Rm};
  endfunction

  function [31:0] f_beq;          // off16 = target - beq_addr - 2
    input [3:0] Rn, Rm; input [15:0] off16;
    f_beq = {4'hE, 4'b1000, Rn, Rm, off16};
  endfunction

  function [31:0] f_bne;          // off16 = target - bne_addr - 2
    input [3:0] Rn, Rm; input [15:0] off16;
    f_bne = {4'hE, 4'b1001, Rn, Rm, off16};
  endfunction

  function [31:0] f_j;            // target9 = absolute word address
    input [8:0] target;
    //f_j = {6'b111010, 17'b0, target};
	 f_j = {6'b111011, 17'b0, target};
  endfunction

  function [31:0] f_jr;
    input [3:0] Rm;
    f_jr = {4'hE, 24'h12FFF1, Rm};
  endfunction

  function [31:0] f_bl;           // off24 = target - bl_addr - 2
    input [23:0] off24;
    f_bl = {4'hE, 4'b1011, off24};
  endfunction

  function [31:0] f_str;
    input [3:0] Rd, Rn; input [11:0] off12;
    f_str = {4'hE, 8'b0101_1000, Rn, Rd, off12};
  endfunction

  function [31:0] f_ldr;
    input [3:0] Rd, Rn; input [11:0] off12;
    f_ldr = {4'hE, 8'b0101_1001, Rn, Rd, off12};
  endfunction

  // ===========================================================================
  // Tasks
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
      reset = 1'b1;
      run = 1'b0; step = 1'b0; pc_reset_pulse = 1'b0;
      imem_prog_we = 1'b0; imem_prog_addr = 9'h0; imem_prog_wdata = 32'h0;
      dmem_prog_en = 1'b0; dmem_prog_we = 1'b0;
      dmem_prog_addr = 8'h0; dmem_prog_wdata = 64'h0;
      repeat (4) @(posedge clk); #1;
      reset = 1'b0;
      @(posedge clk); #1;
    end
  endtask

  task run_cycles;
    input integer n;
    begin
      run = 1'b1;
      repeat (n) @(posedge clk);
      #1;
      run = 1'b0;
    end
  endtask

  integer addr;

  task drain_and_run;
    input integer extra_cycles;
    integer i;
    begin
      for (i = 0; i < 15; i = i + 1) begin
        program_imem_word(addr[8:0], NOP);
        addr = addr + 1;
      end
      pulse_pc_reset();
      run_cycles(addr + extra_cycles);
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

  always @(posedge clk) begin
      $display("[%0t]   imem_dout=0x%016h, imem_addr_mux=0x%016h, dec_branch_target= 0x%016h, ifid_pc=0x%016h, if_beq_off=0x%016h, if_off24==0x%016h,ex_branch_target=0x%016h, pc=0x%016h", 
		$time, dut.imem_dout, dut.imem_addr_mux, dut.dec_branch_target, dut.ifid_pc, dut.if_beq_off, dut.if_off24, dut.ex_branch_target, dut.pc_dbg);
		$display("is_j	:	%b, is_beqbne  %b", dut.is_j, dut.is_beqbne);
  end
  // ===========================================================================
  // check_reg
  // ===========================================================================
  task check_reg;
    input [3:0]   rn;
    input [63:0]  expected;
    input [127:0] label;
    reg   [63:0]  actual;
    begin
      actual = `RF[rn];
      if (actual === expected) begin
        $display("  PASS  %-32s  R%0d = 0x%016h", label, rn, actual);
        pass_count = pass_count + 1;
      end else begin
        $display("  FAIL  %-32s  R%0d  got=0x%016h  exp=0x%016h",
                 label, rn, actual, expected);
        fail_count = fail_count + 1;
      end
    end
  endtask

  // ===========================================================================
  // MAIN
  // ===========================================================================
  initial begin
    pass_count = 0; fail_count = 0;
    reset = 1'b1; run = 1'b0; step = 1'b0; pc_reset_pulse = 1'b0;
    imem_prog_we = 1'b0; imem_prog_addr = 9'h0; imem_prog_wdata = 32'h0;
    dmem_prog_en = 1'b0; dmem_prog_we = 1'b0;
    dmem_prog_addr = 8'h0; dmem_prog_wdata = 64'h0;

    $dumpfile("tb_pipeline_p_ext.vcd");
    $dumpvars(0, tb_pipeline_p_ext);

    $display("======================================================");
    $display("  Extended Pipeline Testbench");
    $display("======================================================");

    repeat (3) @(posedge clk); #1;
    reset = 1'b0;
    @(posedge clk); #1;

    // =========================================================================
    // TEST 0 ? Regression: MOV / ADD / SUB
    //
    //  word  0    MOV R1, #10
    //  word  1-7  NOP x7
    //  word  8    MOV R2, #20
    //  word  9-15 NOP x7
    //  word 16    ADD R3, R1, R2    ? R3 = 30
    //  word 17-23 NOP x7
    //  word 24    SUB R4, R2, R1    ? R4 = 10
    //  drain
    // =========================================================================
    $display("\n--- TEST 0: Regression (MOV/ADD/SUB) ---");
    do_reset; addr = 0;

    program_imem_word(addr, f_mov(4'd1, 8'd10));       addr=addr+1; // w0
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w1-7

    program_imem_word(addr, f_mov(4'd2, 8'd20));       addr=addr+1; // w8
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w9-15

    program_imem_word(addr, f_add_r(4'd3,4'd1,4'd2)); addr=addr+1; // w16
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w17-23

    program_imem_word(addr, f_sub_r(4'd4,4'd2,4'd1)); addr=addr+1; // w24
    drain_and_run(10);

    check_reg(4'd1, 64'h000000000000000A, "MOV R1,#10");
    check_reg(4'd2, 64'h0000000000000014, "MOV R2,#20");
    check_reg(4'd3, 64'h000000000000001E, "ADD R3=R1+R2=30");
    check_reg(4'd4, 64'h000000000000000A, "SUB R4=R2-R1=10");

    // =========================================================================
    // TEST 1 ? SLL  (variable shift left)
    //
    //  word  0    MOV R1, #1
    //  word  1-7  NOP x7
    //  word  8    MOV R2, #4        shift amount
    //  word  9-15 NOP x7
    //  word 16    SLL R3, R1, R2    ? R3 = 1<<4 = 16
    //  word 17-23 NOP x7
    //  word 24    MOV R4, #0xFF
    //  word 25-31 NOP x7
    //  word 32    MOV R5, #3        shift amount
    //  word 33-39 NOP x7
    //  word 40    SLL R6, R4, R5    ? R6 = 255<<3 = 2040
    //  drain
    // =========================================================================
    $display("\n--- TEST 1: SLL (variable shift left) ---");
    do_reset; addr = 0;

    program_imem_word(addr, f_mov(4'd1, 8'd1));        addr=addr+1; // w0
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w1-7

    program_imem_word(addr, f_mov(4'd2, 8'd4));        addr=addr+1; // w8
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w9-15

    program_imem_word(addr, f_sll(4'd3,4'd1,4'd2));   addr=addr+1; // w16
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w17-23

    program_imem_word(addr, f_mov(4'd4, 8'hFF));       addr=addr+1; // w24
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w25-31

    program_imem_word(addr, f_mov(4'd5, 8'd3));        addr=addr+1; // w32
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w33-39

    program_imem_word(addr, f_sll(4'd6,4'd4,4'd5));   addr=addr+1; // w40
    drain_and_run(10);

    check_reg(4'd3, 64'h0000000000000010, "SLL R3=R1<<R2 (1<<4=16)");
    check_reg(4'd6, 64'h00000000000007F8, "SLL R6=R4<<R5 (255<<3=2040)");

    // =========================================================================
    // TEST 2 ? SRL  (variable shift right)
    //
    //  word  0    MOV R1, #0x80     = 128
    //  word  1-7  NOP x7
    //  word  8    MOV R2, #3        shift amount
    //  word  9-15 NOP x7
    //  word 16    SRL R3, R1, R2    ? R3 = 128>>3 = 16
    //  word 17-23 NOP x7
    //  word 24    MOV R4, #0xFF     = 255
    //  word 25-31 NOP x7
    //  word 32    MOV R5, #4        shift amount
    //  word 33-39 NOP x7
    //  word 40    SRL R6, R4, R5    ? R6 = 255>>4 = 15
    //  drain
    // =========================================================================
    $display("\n--- TEST 2: SRL (variable shift right) ---");
    do_reset; addr = 0;

    program_imem_word(addr, f_mov(4'd1, 8'h80));       addr=addr+1; // w0
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w1-7

    program_imem_word(addr, f_mov(4'd2, 8'd3));        addr=addr+1; // w8
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w9-15

    program_imem_word(addr, f_srl(4'd3,4'd1,4'd2));   addr=addr+1; // w16
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w17-23

    program_imem_word(addr, f_mov(4'd4, 8'hFF));       addr=addr+1; // w24
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w25-31

    program_imem_word(addr, f_mov(4'd5, 8'd4));        addr=addr+1; // w32
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w33-39

    program_imem_word(addr, f_srl(4'd6,4'd4,4'd5));   addr=addr+1; // w40
    drain_and_run(10);

    check_reg(4'd3, 64'h0000000000000010, "SRL R3=R1>>R2 (128>>3=16)");
    check_reg(4'd6, 64'h000000000000000F, "SRL R6=R4>>R5 (255>>4=15)");

    // =========================================================================
    // TEST 3 ? SLT  (set less than, signed)
    //
    //  word  0    MOV R1, #5
    //  word  1-7  NOP x7
    //  word  8    MOV R2, #10
    //  word  9-15 NOP x7
    //  word 16    SLT R3, R1, R2    ? R3 = (5<10)  = 1
    //  word 17-23 NOP x7
    //  word 24    SLT R4, R2, R1    ? R4 = (10<5)  = 0
    //  word 25-31 NOP x7
    //  word 32    SLT R5, R1, R1    ? R5 = (5<5)   = 0
    //  drain
    // =========================================================================
    $display("\n--- TEST 3: SLT (set less than, signed) ---");
    do_reset; addr = 0;

    program_imem_word(addr, f_mov(4'd1, 8'd5));        addr=addr+1; // w0
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w1-7

    program_imem_word(addr, f_mov(4'd2, 8'd10));       addr=addr+1; // w8
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w9-15

    program_imem_word(addr, f_slt(4'd3,4'd1,4'd2));   addr=addr+1; // w16
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w17-23

    program_imem_word(addr, f_slt(4'd4,4'd2,4'd1));   addr=addr+1; // w24
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w25-31

    program_imem_word(addr, f_slt(4'd5,4'd1,4'd1));   addr=addr+1; // w32
    drain_and_run(10);

    check_reg(4'd3, 64'h0000000000000001, "SLT R3=(5<10)=1");
    check_reg(4'd4, 64'h0000000000000000, "SLT R4=(10<5)=0");
    check_reg(4'd5, 64'h0000000000000000, "SLT R5=(5<5)=0");

    // =========================================================================
    // TEST 4 ? BEQ  (branch if equal)
    //
    // ?? Case A: taken (R1==R2) ???????????????????????????????????????????????
    //  word  0    MOV R1, #7
	 //  word  1    MOV R3, #0
    //  word  2-7  NOP x7
    //  word  8    MOV R2, #7
    //  word  9-15 NOP x7
    //  word 16    BEQ R1,R2, off=+5  ? target = 16+2+5 = 23
    //  word 17-20 NOP x4             ? mandatory 4 NOPs after BEQ
    //  word 21    ADD R3,R3,#1       POISON (must be skipped)
    //  word 22    ADD R3,R3,#1       POISON (must be skipped)
    //  word 23    MOV R4, #0xAA      LAND ? R4=0xAA
    //  word 24-30 NOP x7
    //
    // ?? Case B: not taken (R5!=R6) ???????????????????????????????????????????
    //  word 31    MOV R5, #3
    //  word 32-38 NOP x7
    //  word 39    MOV R6, #9
    //  word 40-46 NOP x7
    //  word 47    BEQ R5,R6, off=+6  not taken (3!=9)
    //  word 48-51 NOP x4             ? mandatory 4 NOPs after BEQ
    //  word 52    ADD R7,R0,#0x55    EXECUTED (fall-through) ? R7=0x55
    //  drain
    //
    // Expected: R3=0 (poison skipped), R4=0xAA (landing), R7=0x55 (fall-thru)
    // =========================================================================
    $display("\n--- TEST 4: BEQ (branch if equal) ---");
    do_reset; addr = 0;
		
    // Case A setup
    program_imem_word(addr, f_mov(4'd1, 8'd7));        addr=addr+1; // w0
	 program_imem_word(addr, f_mov(4'd3, 8'd0));        addr=addr+1; // w1
    // repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w1-7
	 repeat(6) begin program_imem_word(addr,NOP); addr=addr+1; end   // w1-7

    program_imem_word(addr, f_mov(4'd2, 8'd7));        addr=addr+1; // w8
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w9-15

    // w16: BEQ R1,R2  offset=+5 ? target=23
    program_imem_word(addr, f_beq(4'd1,4'd2,16'd5));  addr=addr+1; // w16

    // w17-20: 4 mandatory NOPs after BEQ
    repeat(4) begin program_imem_word(addr,NOP); addr=addr+1; end   // w17-20

    // w21-22: poison (should be skipped by branch)
    program_imem_word(addr, f_add_i(4'd3,4'd3,8'd1)); addr=addr+1; // w21 POISON
    program_imem_word(addr, f_add_i(4'd3,4'd3,8'd1)); addr=addr+1; // w22 POISON

    // w23: landing  (16+2+5=23 ?)
    if (addr !== 9'd23) $display("WARNING: BEQ-A landing not at w23, got %0d", addr);
    program_imem_word(addr, f_mov(4'd4, 8'hAA));       addr=addr+1; // w23 LAND
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w24-30

    // Case B setup
    program_imem_word(addr, f_mov(4'd5, 8'd3));        addr=addr+1; // w31
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w32-38

    program_imem_word(addr, f_mov(4'd6, 8'd9));        addr=addr+1; // w39
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w40-46

    // w47: BEQ R5,R6  not taken (3!=9)
    program_imem_word(addr, f_beq(4'd5,4'd6,16'd6));  addr=addr+1; // w47

    // w48-51: 4 mandatory NOPs after BEQ
    repeat(4) begin program_imem_word(addr,NOP); addr=addr+1; end   // w48-51
$stop;
    // w52: fall-through MUST execute
    program_imem_word(addr, f_add_i(4'd7,4'd0,8'h55)); addr=addr+1; // w52
    drain_and_run(10);
		//$stop;
    check_reg(4'd3, 64'h0000000000000000, "BEQ taken: R3=0 (poison skipped)");
    check_reg(4'd4, 64'h00000000000000AA, "BEQ taken: R4=0xAA (landing)");
    check_reg(4'd7, 64'h0000000000000055, "BEQ not-taken: R7=0x55 (fallthru)");

    // =========================================================================
    // TEST 5 ? BNE  (branch if not equal)
    //
    // ?? Case A: taken (R1!=R2) ???????????????????????????????????????????????
    //  word  0    MOV R1, #3
	 //  word  1    MOV R8, #0
    //  word  2-7  NOP x6
    //  word  8    MOV R2, #9
    //  word  9-15 NOP x7
    //  word 16    BNE R1,R2, off=+5  ? target = 16+2+5 = 23
    //  word 17-20 NOP x4             ? mandatory 4 NOPs after BNE
    //  word 21    ADD R8,R8,#1       POISON (must be skipped)
    //  word 22    ADD R8,R8,#1       POISON (must be skipped)
    //  word 23    MOV R3, #0xBB      LAND ? R3=0xBB
    //  word 24-30 NOP x7
    //
    // ?? Case B: not taken (R4==R5) ???????????????????????????????????????????
    //  word 31    MOV R4, #6
    //  word 32-38 NOP x7
    //  word 39    MOV R5, #6
    //  word 40-46 NOP x7
    //  word 47    BNE R4,R5, off=+6  not taken (6==6)
    //  word 48-51 NOP x4             ? mandatory 4 NOPs after BNE
    //  word 52    ADD R6,R0,#0xCC    EXECUTED (fall-through) ? R6=0xCC
    //  drain
    //
    // Expected: R8=0 (poison skipped), R3=0xBB (landing), R6=0xCC (fall-thru)
    // =========================================================================
    $display("\n--- TEST 5: BNE (branch if not equal) ---");
    do_reset; addr = 0;

    // Case A setup
    program_imem_word(addr, f_mov(4'd1, 8'd3));        addr=addr+1; // w0
	 program_imem_word(addr, f_mov(4'd8, 8'd0));        addr=addr+1; // w1
    repeat(6) begin program_imem_word(addr,NOP); addr=addr+1; end   // w2-7

    program_imem_word(addr, f_mov(4'd2, 8'd9));        addr=addr+1; // w8
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w9-15

    // w16: BNE R1,R2  offset=+5 ? target=23
    program_imem_word(addr, f_bne(4'd1,4'd2,16'd5));  addr=addr+1; // w16

    // w17-20: 4 mandatory NOPs after BNE
    repeat(4) begin program_imem_word(addr,NOP); addr=addr+1; end   // w17-20

    // w21-22: poison (should be skipped by branch)
    program_imem_word(addr, f_add_i(4'd8,4'd8,8'd1)); addr=addr+1; // w21 POISON
    program_imem_word(addr, f_add_i(4'd8,4'd8,8'd1)); addr=addr+1; // w22 POISON

    // w23: landing  (16+2+5=23 ?)
    if (addr !== 9'd23) $display("WARNING: BNE-A landing not at w23, got %0d", addr);
    program_imem_word(addr, f_mov(4'd3, 8'hBB));       addr=addr+1; // w23 LAND
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w24-30

    // Case B setup
    program_imem_word(addr, f_mov(4'd4, 8'd6));        addr=addr+1; // w31
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w32-38

    program_imem_word(addr, f_mov(4'd5, 8'd6));        addr=addr+1; // w39
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w40-46

    // w47: BNE R4,R5  not taken (6==6)
    program_imem_word(addr, f_bne(4'd4,4'd5,16'd6));  addr=addr+1; // w47

    // w48-51: 4 mandatory NOPs after BNE
    repeat(4) begin program_imem_word(addr,NOP); addr=addr+1; end   // w48-51

    // w52: fall-through MUST execute
    program_imem_word(addr, f_add_i(4'd6,4'd0,8'hCC)); addr=addr+1; // w52
    drain_and_run(10);

    check_reg(4'd8, 64'h0000000000000000, "BNE taken: R8=0 (poison skipped)");
    check_reg(4'd3, 64'h00000000000000BB, "BNE taken: R3=0xBB (landing)");
    check_reg(4'd6, 64'h00000000000000CC, "BNE not-taken: R6=0xCC (fallthru)");

    // =========================================================================
    // TEST 6 ? J  (absolute jump)
    //
    //  word  0    MOV R1, #0         canary (must stay 0)
    //  word  1-7  NOP x7
    //  word  8    J  target=20       absolute jump to word 20
    //  word  9-12 NOP x4             ? mandatory 4 NOPs after J
    //  word 13-19 ADD R1,R1,#1 x7   POISON (must be skipped)
    //  word 20    MOV R2, #0xDD      LAND ? R2=0xDD
    //  drain
    //
    // Expected: R1=0 (poison skipped), R2=0xDD (landing)
    // =========================================================================
    $display("\n--- TEST 6: J (absolute jump) ---");
    do_reset; addr = 0;

    program_imem_word(addr, f_mov(4'd1, 8'd0));        addr=addr+1; // w0  R1=0 canary
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w1-7

    // w8: J target=20
    program_imem_word(addr, f_j(9'd20));               addr=addr+1; // w8

    // w9-12: 4 mandatory NOPs after J
    repeat(4) begin program_imem_word(addr,NOP); addr=addr+1; end   // w9-12

    // w13-19: poison
    repeat(7) begin
      program_imem_word(addr, f_add_i(4'd1,4'd1,8'd1));
      addr=addr+1;
    end                                                              // w13-19

    // w20: landing
    if (addr !== 9'd20) $display("WARNING: J landing not at w20, got %0d", addr);
    program_imem_word(addr, f_mov(4'd2, 8'hDD));       addr=addr+1; // w20 LAND
	 $stop;
    drain_and_run(10);

    check_reg(4'd1, 64'h0000000000000000, "J: R1=0 (poison skipped)");
    check_reg(4'd2, 64'h00000000000000DD, "J: R2=0xDD (landing)");

    // =========================================================================
    // TEST 7 ? JR  (jump register)
    //
    //  word  0    MOV R9, #30        load target address into R9
    //  word  1-7  NOP x7             hazard guard (R9 must be ready)
    //  word  8    JR  R9             jump to word 30
    //  word  9-12 NOP x4             ? mandatory 4 NOPs after JR
    //  word 13-29 ADD R1,R1,#1 x17  POISON (must be skipped)
    //  word 30    MOV R2, #0xEE      LAND ? R2=0xEE
    //  drain
    //
    // Expected: R1=0 (poison skipped, R1 never initialised ? written),
    //           R2=0xEE (landing)
    // =========================================================================
    $display("\n--- TEST 7: JR (jump register) ---");
    do_reset; addr = 0;

    program_imem_word(addr, f_mov(4'd9, 8'd30));       addr=addr+1; // w0  R9=30
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w1-7

    // w8: JR R9  (jump to word 30)
    program_imem_word(addr, f_jr(4'd9));               addr=addr+1; // w8

    // w9-12: 4 mandatory NOPs after JR
    repeat(4) begin program_imem_word(addr,NOP); addr=addr+1; end   // w9-12

    // w13-29: poison (17 words)
    repeat(17) begin
      program_imem_word(addr, f_add_i(4'd1,4'd1,8'd1));
      addr=addr+1;
    end                                                              // w13-29

    // w30: landing
    if (addr !== 9'd30) $display("WARNING: JR landing not at w30, got %0d", addr);
    program_imem_word(addr, f_mov(4'd2, 8'hEE));       addr=addr+1; // w30 LAND
    drain_and_run(10);

    check_reg(4'd1, 64'h0000000000000000, "JR: R1=0 (poison skipped)");
    check_reg(4'd2, 64'h00000000000000EE, "JR: R2=0xEE (landing)");

    // =========================================================================
    // TEST 8 ? BL / JR  (branch-and-link full call/return)
    //
    // Proves: (a) BL writes correct return address into R14 = BL_word+1
    //         (b) subroutine executes correctly
    //         (c) JR R14 returns to right address
    //         (d) post-return code executes
    //
    // ?? Caller (words 0-54) ???????????????????????????????????????????????????
    //  word  0    MOV R1, #10        argument
    //  word  1-7  NOP x7
    //  word  8    MOV R2, #5         argument
    //  word  9-15 NOP x7
    //  word 16    BL  off=+43        target=16+2+43=61, R14?17
    //  word 17    MOV R5, #0xCA      ? RETURN LANDS HERE (word 17)
    //  word 18-24 NOP x7
    //  word 25    MOV R6, #0xFE      second post-return instruction
    //  word 26-60 NOP (pad to word 60, one before subroutine)
    //
    // ?? Subroutine (words 61-70) ??????????????????????????????????????????????
    //  word 61    ADD R3, R1, R2     ? R3 = 15
    //  word 62-68 NOP x7
    //  word 69    SUB R4, R1, R2     ? R4 = 5
    //  word 70-76 NOP x7             (hazard guard before JR)
    //
    //  word 77    JR  R14            return to word 17
    //  word 78-81 NOP x4             ? mandatory 4 NOPs after JR
    //
    // Expected: R14=17, R3=15, R4=5, R5=0xCA, R6=0xFE
    // =========================================================================
    $display("\n--- TEST 8: BL / JR (branch-and-link call + return) ---");
    do_reset; addr = 0;

    // Caller
    program_imem_word(addr, f_mov(4'd1, 8'd10));       addr=addr+1; // w0  R1=10
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w1-7

    program_imem_word(addr, f_mov(4'd2, 8'd5));        addr=addr+1; // w8  R2=5
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w9-15

    // w16: BL  target=61, offset=61-16-2=43
    program_imem_word(addr, f_bl(24'd43));             addr=addr+1; // w16

    // w17: return landing ? first instruction executed after JR R14
    program_imem_word(addr, f_mov(4'd5, 8'hCA));       addr=addr+1; // w17 R5=0xCA
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w18-24

    // w25: second post-return instruction
    program_imem_word(addr, f_mov(4'd6, 8'hFE));       addr=addr+1; // w25 R6=0xFE

    // pad NOPs up to word 60
    while (addr < 61) begin program_imem_word(addr,NOP); addr=addr+1; end

    // Subroutine at word 61
    if (addr !== 9'd61) $display("WARNING: subroutine not at w61, got %0d", addr);
    program_imem_word(addr, f_add_r(4'd3,4'd1,4'd2)); addr=addr+1; // w61  R3=15
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w62-68

    program_imem_word(addr, f_sub_r(4'd4,4'd1,4'd2)); addr=addr+1; // w69  R4=5
    repeat(7) begin program_imem_word(addr,NOP); addr=addr+1; end   // w70-76

    // w77: JR R14  (return to word 17)
    program_imem_word(addr, f_jr(4'd14));              addr=addr+1; // w77

    // w78-81: 4 mandatory NOPs after JR
    repeat(4) begin program_imem_word(addr,NOP); addr=addr+1; end   // w78-81

    // Run enough cycles to complete caller?subroutine?return?post-return
    pulse_pc_reset();
    run_cycles(addr + 30);

    check_reg(4'd14, 64'h0000000000000011, "BL: R14=17 (return addr)");
    check_reg(4'd3,  64'h000000000000000F, "BL: R3=15 (sub ADD)");
    check_reg(4'd4,  64'h0000000000000005, "BL: R4=5  (sub SUB)");
    check_reg(4'd5,  64'h00000000000000CA, "BL: R5=0xCA (post-return)");
    check_reg(4'd6,  64'h00000000000000FE, "BL: R6=0xFE (post-return)");

    // =========================================================================
    // SUMMARY
    // =========================================================================
    $display("\n======================================================");
    $display("  Results:  %0d PASSED   %0d FAILED", pass_count, fail_count);
    $display("======================================================");
    if (fail_count == 0)
      $display("  ALL TESTS PASSED");
    else
      $display("  *** FAILURES ? inspect tb_pipeline_p_ext.vcd ***");
    $display("======================================================\n");

    $finish;
  end

  // ??? Watchdog ??????????????????????????????????????????????????????????????
  initial begin
    #2_000_000;
    $display("TIMEOUT");
    $finish;
  end

endmodule
