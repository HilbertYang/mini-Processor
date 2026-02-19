`timescale 1ns/1ps
// =============================================================================
// tb_pipeline_p.v  ?  Testbench for pipeline_p.v  (ARM-32 pipeline)
//
// Follows the style of the working reference testbench (tb_pipeline_p1.v):
//   - Same task names: program_imem_word / program_dmem_word / read_dmem_word
//   - Same clock discipline: @(posedge clk); #1
//   - Same WB monitor
//   - Instruction encoding done with FUNCTIONS (not `define macros) to avoid
//     the "[SE] token is '['" error caused by bit-selects on macro arguments
//
// ARM-32 encoding (cond = 4'hE always, condition codes not evaluated):
//   NOP                  32'hE000_0000
//   MOV Rd, #imm8        op=001 opcode=1101 S=0 Rn=0
//   ADD Rd, Rn, Rm       op=000 opcode=0100  (register)
//   ADD Rd, Rn, #imm8    op=001 opcode=0100  (immediate)
//   SUB Rd, Rn, Rm       op=000 opcode=0010
//   SUB Rd, Rn, #imm8    op=001 opcode=0010
//   AND Rd, Rn, Rm       op=000 opcode=0000
//   ORR Rd, Rn, Rm       op=000 opcode=1100
//   STR Rd,[Rn,#off12]   [27:20]=8'b0101_1000  (P=1,U=1,B=0,W=0,L=0)
//   LDR Rd,[Rn,#off12]   [27:20]=8'b0101_1001  (P=1,U=1,B=0,W=0,L=1)
//   B   offset24         [31:24]=8'hEA
//     branch_target = ifid_pc + 2 + sign_extend(offset24)
//     => offset24 = target_word_addr - B_instruction_word_addr - 2
//
// Pipeline depth:
//   5 register hops from ID-read to WB-write
//   (ID/EX -> EX/MEM -> MEM_reg -> MEM/WB -> WB)
//   Consumer must enter ID >= 6 advance-cycles after producer
//   => 7 NOPs between producer and consumer (safe margin)
//
// D-mem addressing:
//   stage_MEM: bram_addr = exmem_alu_result[7:0]
//   ALU result for LDR/STR = Rn + imm12  (treated as direct word address)
//   => LDR/STR Rx,[R0,#N] accesses dmem word N  (R0=0 after reset)
// =============================================================================

module tb_pipeline_p;

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

  // ??? Instantiate DUT ???????????????????????????????????????????????????????
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

  // ??? Clock  (10 ns period = 100 MHz, matches reference) ????????????????????
  localparam CLK_PERIOD = 10;
  initial clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  // ??? Pass / fail counters ??????????????????????????????????????????????????
  integer pass_count;
  integer fail_count;

  // ===========================================================================
  // Instruction encoding functions
  // ===========================================================================
  // Using Verilog functions instead of `define macros.
  // Macros with bit-select on arguments like (Rd)[3:0] are illegal in Verilog
  // and produce the "token is '['" synthesis/simulation error.
  // Functions receive properly-typed ports so bit-widths are handled correctly.

  localparam NOP = 32'hE000_0000;  // AND R0,R0,R0 ? result discarded

  // MOV Rd, #imm8
  function [31:0] f_mov;
    input [3:0] Rd;
    input [7:0] imm8;
    begin
      // cond=E  I=1  opcode=1101(MOV)  S=0  Rn=0000  Rd  rot=0000  imm8
      f_mov = {4'hE, 3'b001, 4'b1101, 1'b0, 4'h0, Rd, 4'h0, imm8};
    end
  endfunction

  // ADD Rd, Rn, Rm  (register)
  function [31:0] f_add_r;
    input [3:0] Rd, Rn, Rm;
    begin
      // cond=E  I=0  opcode=0100(ADD)  S=0  Rn  Rd  shift=00000000  Rm
      f_add_r = {4'hE, 3'b000, 4'b0100, 1'b0, Rn, Rd, 8'h00, Rm};
    end
  endfunction

  // SUB Rd, Rn, Rm  (register)
  function [31:0] f_sub_r;
    input [3:0] Rd, Rn, Rm;
    begin
      f_sub_r = {4'hE, 3'b000, 4'b0010, 1'b0, Rn, Rd, 8'h00, Rm};
    end
  endfunction

  // AND Rd, Rn, Rm
  function [31:0] f_and_r;
    input [3:0] Rd, Rn, Rm;
    begin
      f_and_r = {4'hE, 3'b000, 4'b0000, 1'b0, Rn, Rd, 8'h00, Rm};
    end
  endfunction

  // ORR Rd, Rn, Rm
  function [31:0] f_orr_r;
    input [3:0] Rd, Rn, Rm;
    begin
      f_orr_r = {4'hE, 3'b000, 4'b1100, 1'b0, Rn, Rd, 8'h00, Rm};
    end
  endfunction

  // ADD Rd, Rn, #imm8  (immediate)
  function [31:0] f_add_i;
    input [3:0] Rd, Rn;
    input [7:0] imm8;
    begin
      f_add_i = {4'hE, 3'b001, 4'b0100, 1'b0, Rn, Rd, 4'h0, imm8};
    end
  endfunction

  // SUB Rd, Rn, #imm8  (immediate)
  function [31:0] f_sub_i;
    input [3:0] Rd, Rn;
    input [7:0] imm8;
    begin
      f_sub_i = {4'hE, 3'b001, 4'b0010, 1'b0, Rn, Rd, 4'h0, imm8};
    end
  endfunction

  // STR Rd, [Rn, #off12]
  function [31:0] f_str;
    input [3:0]  Rd, Rn;
    input [11:0] off12;
    begin
      // [27:20] = 8'b0101_1000  (op=01 P=1 U=1 B=0 W=0 L=0)
      f_str = {4'hE, 8'b0101_1000, Rn, Rd, off12};
    end
  endfunction

  // LDR Rd, [Rn, #off12]
  function [31:0] f_ldr;
    input [3:0]  Rd, Rn;
    input [11:0] off12;
    begin
      // [27:20] = 8'b0101_1001  (op=01 P=1 U=1 B=0 W=0 L=1)
      f_ldr = {4'hE, 8'b0101_1001, Rn, Rd, off12};
    end
  endfunction

  // B  offset24
  // offset24 = desired_target_word_addr - B_instruction_word_addr - 2
  function [31:0] f_b;
    input [23:0] off24;
    begin
      f_b = {4'hE, 4'b1010, off24};
    end
  endfunction

  // ===========================================================================
  // Tasks  (same names and @posedge clk; #1 discipline as reference)
  // ===========================================================================

  // Write one 32-bit word into I-mem via programming port
  task program_imem_word;
    input [8:0]  addr;
    input [31:0] data;
    begin
      run  = 1'b0;
      step = 1'b0;

      imem_prog_addr  = addr;
      imem_prog_wdata = data;
      imem_prog_we    = 1'b1;

      @(posedge clk);
      #1;
      imem_prog_we = 1'b0;
    end
  endtask

  // Write one 64-bit word into D-mem Port B
  task program_dmem_word;
    input [7:0]  addr;
    input [63:0] data;
    begin
      run  = 1'b0;
      step = 1'b0;

      dmem_prog_addr  = addr;
      dmem_prog_wdata = data;
      dmem_prog_en    = 1'b1;
      dmem_prog_we    = 1'b1;

      @(posedge clk);
      #1;
      dmem_prog_we = 1'b0;
      dmem_prog_en = 1'b0;
    end
  endtask

  // Read one 64-bit word from D-mem Port B
  task read_dmem_word;
    input  [7:0]  addr;
    output [63:0] data;
    begin
      run  = 1'b0;
      step = 1'b0;

      dmem_prog_addr  = addr;
      dmem_prog_en    = 1'b1;
      dmem_prog_we    = 1'b0;
      dmem_prog_wdata = 64'h0;

      @(posedge clk);
      #1;
      data = dmem_prog_rdata;

      dmem_prog_en = 1'b0;

      @(posedge clk);   // gap cycle ? matches reference
      #1;
    end
  endtask

  // Pulse PC reset  (matches reference)
  task pulse_pc_reset;
    begin
      pc_reset_pulse = 1'b1;
      @(posedge clk);
      #1;
      pc_reset_pulse = 1'b0;
      @(posedge clk);
      #1;
    end
  endtask

  // ===========================================================================
  // WB monitor  (identical to reference testbench)
  // ===========================================================================
  always @(posedge clk) begin
    if (!reset) begin
      if (dut.wb_wen) begin
        $display("[%0t] WB: wen=1  waddr=R%0d  wdata=0x%016h  (pc=%0d  ifid_instr=0x%08h)",
                 $time, dut.wb_waddr, dut.wb_wdata, pc_dbg, if_instr_dbg);
      end
    end
  end

  // ===========================================================================
  // Result checking helpers
  // ===========================================================================

  // Read register via hierarchical path and compare
  task check_reg;
    input [3:0]   reg_num;
    input [63:0]  expected;
    input [127:0] label;
    reg   [63:0]  actual;
    begin
      actual = dut.u_rf.regFile[reg_num];
      if (actual === expected) begin
        $display("  PASS  [%0s]  R%0d = 0x%016h", label, reg_num, actual);
        pass_count = pass_count + 1;
      end else begin
        $display("  FAIL  [%0s]  R%0d  got=0x%016h  expected=0x%016h",
                 label, reg_num, actual, expected);
        fail_count = fail_count + 1;
      end
    end
  endtask

  // Read D-mem via prog port and compare
  task check_dmem;
    input [7:0]   addr;
    input [63:0]  expected;
    input [127:0] label;
    reg   [63:0]  actual;
    begin
      read_dmem_word(addr, actual);
      if (actual === expected) begin
        $display("  PASS  [%0s]  dmem[%0d] = 0x%016h", label, addr, actual);
        pass_count = pass_count + 1;
      end else begin
        $display("  FAIL  [%0s]  dmem[%0d]  got=0x%016h  expected=0x%016h",
                 label, addr, actual, expected);
        fail_count = fail_count + 1;
      end
    end
  endtask

  // ===========================================================================
  // MAIN TEST
  // ===========================================================================
  reg [63:0] rd0, rd1;

  initial begin
    // ?? Default state  (same order as reference) ?????????????????????????????
    pass_count     = 0;
    fail_count     = 0;
    reset          = 1'b1;
    run            = 1'b0;
    step           = 1'b0;
    pc_reset_pulse = 1'b0;

    imem_prog_we    = 1'b0;
    imem_prog_addr  = 9'd0;
    imem_prog_wdata = 32'h0;

    dmem_prog_en    = 1'b0;
    dmem_prog_we    = 1'b0;
    dmem_prog_addr  = 8'd0;
    dmem_prog_wdata = 64'h0;

    $dumpfile("tb_pipeline_p.vcd");
    $dumpvars(0, tb_pipeline_p);

    // Hold reset 3 cycles then release  (matches reference)
    repeat (3) @(posedge clk);
    #1;
    reset = 1'b0;
    @(posedge clk);
    #1;

    // =========================================================================
    // SECTION 0 ? D-mem prog port write / readback sanity check
    // Same pattern as reference: write known values, read back, assert correct.
    // =========================================================================
    $display("== Section 0: D-mem prog-port write/readback ==");

    program_dmem_word(8'd0, 64'd1000);
    program_dmem_word(8'd1, 64'd2000);

    read_dmem_word(8'd0, rd0);
    read_dmem_word(8'd1, rd1);
    $display("[%0t] D-mem[0]=%0d  D-mem[1]=%0d", $time, rd0, rd1);

    if (rd0 !== 64'd1000) begin
      $display("ERROR: D-mem[0] expected 1000, got %0d ? aborting", rd0);
      $stop;
    end
    if (rd1 !== 64'd2000) begin
      $display("ERROR: D-mem[1] expected 2000, got %0d ? aborting", rd1);
      $stop;
    end
    $display("D-mem prog port OK.");

    // =========================================================================
    // SECTION 1 ? Arithmetic and Logic
    //
    // Word layout  (7 NOPs between every dependent pair, 15 at the end to drain):
    //
    //   0   MOV R1, #10
    //   1-7  NOP x7
    //   8   MOV R2, #20
    //   9-15  NOP x7
    //  16   ADD R3, R1, R2       R3 = 10+20 = 30  (0x1E)
    //  17-23  NOP x7
    //  24   SUB R4, R2, R1       R4 = 20-10 = 10  (0x0A)
    //  25-31  NOP x7
    //  32   AND R5, R1, R2       R5 = 0x0A & 0x14 = 0x00
    //  33-39  NOP x7
    //  40   ORR R6, R1, R2       R6 = 0x0A | 0x14 = 0x1E
    //  41-47  NOP x7
    //  48   ADD R7, R1, #5       R7 = 10+5 = 15   (0x0F)
    //  49-55  NOP x7
    //  56   SUB R8, R2, #3       R8 = 20-3 = 17   (0x11)
    //  57-71  NOP x15  (flush)
    // =========================================================================
    $display("");
    $display("== Section 1: Arithmetic and Logic ==");
	//$stop;
    program_imem_word(9'd0,  f_mov(4'd1, 8'd10));
    program_imem_word(9'd1,  NOP);
    program_imem_word(9'd2,  NOP);
    program_imem_word(9'd3,  NOP);
    program_imem_word(9'd4,  NOP);
    program_imem_word(9'd5,  NOP);
    program_imem_word(9'd6,  NOP);
    program_imem_word(9'd7,  NOP);

    program_imem_word(9'd8,  f_mov(4'd2, 8'd20));
    program_imem_word(9'd9,  NOP);
    program_imem_word(9'd10, NOP);
    program_imem_word(9'd11, NOP);
    program_imem_word(9'd12, NOP);
    program_imem_word(9'd13, NOP);
    program_imem_word(9'd14, NOP);
    program_imem_word(9'd15, NOP);

    program_imem_word(9'd16, f_add_r(4'd3, 4'd1, 4'd2));
    program_imem_word(9'd17, NOP);
    program_imem_word(9'd18, NOP);
    program_imem_word(9'd19, NOP);
    program_imem_word(9'd20, NOP);
    program_imem_word(9'd21, NOP);
    program_imem_word(9'd22, NOP);
    program_imem_word(9'd23, NOP);

    program_imem_word(9'd24, f_sub_r(4'd4, 4'd2, 4'd1));
    program_imem_word(9'd25, NOP);
    program_imem_word(9'd26, NOP);
    program_imem_word(9'd27, NOP);
    program_imem_word(9'd28, NOP);
    program_imem_word(9'd29, NOP);
    program_imem_word(9'd30, NOP);
    program_imem_word(9'd31, NOP);

    program_imem_word(9'd32, f_and_r(4'd5, 4'd1, 4'd2));
    program_imem_word(9'd33, NOP);
    program_imem_word(9'd34, NOP);
    program_imem_word(9'd35, NOP);
    program_imem_word(9'd36, NOP);
    program_imem_word(9'd37, NOP);
    program_imem_word(9'd38, NOP);
    program_imem_word(9'd39, NOP);

    program_imem_word(9'd40, f_orr_r(4'd6, 4'd1, 4'd2));
    program_imem_word(9'd41, NOP);
    program_imem_word(9'd42, NOP);
    program_imem_word(9'd43, NOP);
    program_imem_word(9'd44, NOP);
    program_imem_word(9'd45, NOP);
    program_imem_word(9'd46, NOP);
    program_imem_word(9'd47, NOP);

    program_imem_word(9'd48, f_add_i(4'd7, 4'd1, 8'd5));
    program_imem_word(9'd49, NOP);
    program_imem_word(9'd50, NOP);
    program_imem_word(9'd51, NOP);
    program_imem_word(9'd52, NOP);
    program_imem_word(9'd53, NOP);
    program_imem_word(9'd54, NOP);
    program_imem_word(9'd55, NOP);

    program_imem_word(9'd56, f_sub_i(4'd8, 4'd2, 8'd3));
    program_imem_word(9'd57, NOP);
    program_imem_word(9'd58, NOP);
    program_imem_word(9'd59, NOP);
    program_imem_word(9'd60, NOP);
    program_imem_word(9'd61, NOP);
    program_imem_word(9'd62, NOP);
    program_imem_word(9'd63, NOP);
    program_imem_word(9'd64, NOP);
    program_imem_word(9'd65, NOP);
    program_imem_word(9'd66, NOP);
    program_imem_word(9'd67, NOP);
    program_imem_word(9'd68, NOP);
    program_imem_word(9'd69, NOP);
    program_imem_word(9'd70, NOP);
    program_imem_word(9'd71, NOP);

    $display("== Pulse PC reset ==");
    pulse_pc_reset();

    $display("== Run CPU (Section 1) ==");
    run = 1'b1;
    repeat (90) @(posedge clk);
    #1;
    run = 1'b0;

    $display("");
    $display("== Check results: Section 1 ==");
    check_reg(4'd1, 64'h000000000000000A, "MOV R1,#10");
    check_reg(4'd2, 64'h0000000000000014, "MOV R2,#20");
    check_reg(4'd3, 64'h000000000000001E, "ADD R3=R1+R2");      // 30=0x1E
    check_reg(4'd4, 64'h000000000000000A, "SUB R4=R2-R1");      // 10=0x0A
    check_reg(4'd5, 64'h0000000000000000, "AND R5=R1&R2");      // 0x00
    check_reg(4'd6, 64'h000000000000001E, "ORR R6=R1|R2");      // 0x1E
    check_reg(4'd7, 64'h000000000000000F, "ADD_IMM R7=R1+5");   // 15=0x0F
    check_reg(4'd8, 64'h0000000000000011, "SUB_IMM R8=R2-3");   // 17=0x11

    // =========================================================================
    // SECTION 2 ? Store and Load  (STR / LDR roundtrip)
    //
    // Reference pattern: pre-load D-mem sentinel, run STR, verify D-mem changed,
    // then run LDR, verify register.  Same structure as reference test.
    //
    // Word layout:
    //   0   MOV R1, #99           value to store
    //   1-7  NOP x7
    //   8   STR R1, [R0, #3]      dmem[0+3] = 99   (R0=0 after reset)
    //   9-15  NOP x7
    //  16   LDR R2, [R0, #3]      R2 = dmem[3] = 99
    //  17-31  NOP x15  (drain)
    // =========================================================================
    $display("");
    $display("== Section 2: STR / LDR roundtrip ==");

    // Pre-load dmem[3] with sentinel so a wrong address is obvious
    program_dmem_word(8'd3, 64'hDEAD_DEAD_DEAD_DEAD);
    read_dmem_word(8'd3, rd0);
    $display("[%0t] D-mem[3] sentinel before STR = 0x%016h", $time, rd0);
    if (rd0 !== 64'hDEADDEADDEADDEAD) begin
      $display("ERROR: D-mem[3] sentinel write failed"); $stop;
    end

    program_imem_word(9'd0,  f_mov(4'd1, 8'd99));
    program_imem_word(9'd1,  NOP);
    program_imem_word(9'd2,  NOP);
    program_imem_word(9'd3,  NOP);
    program_imem_word(9'd4,  NOP);
    program_imem_word(9'd5,  NOP);
    program_imem_word(9'd6,  NOP);
    program_imem_word(9'd7,  NOP);
    program_imem_word(9'd8,  f_str(4'd1, 4'd0, 12'd3));
    program_imem_word(9'd9,  NOP);
    program_imem_word(9'd10, NOP);
    program_imem_word(9'd11, NOP);
    program_imem_word(9'd12, NOP);
    program_imem_word(9'd13, NOP);
    program_imem_word(9'd14, NOP);
    program_imem_word(9'd15, NOP);
    program_imem_word(9'd16, f_ldr(4'd2, 4'd0, 12'd3));
    program_imem_word(9'd17, NOP);
    program_imem_word(9'd18, NOP);
    program_imem_word(9'd19, NOP);
    program_imem_word(9'd20, NOP);
    program_imem_word(9'd21, NOP);
    program_imem_word(9'd22, NOP);
    program_imem_word(9'd23, NOP);
    program_imem_word(9'd24, NOP);
    program_imem_word(9'd25, NOP);
    program_imem_word(9'd26, NOP);
    program_imem_word(9'd27, NOP);
    program_imem_word(9'd28, NOP);
    program_imem_word(9'd29, NOP);
    program_imem_word(9'd30, NOP);
    program_imem_word(9'd31, NOP);

    $display("== Pulse PC reset ==");
    pulse_pc_reset();

    $display("== Run CPU (Section 2) ==");
    run = 1'b1;
    repeat (50) @(posedge clk);
    #1;
    run = 1'b0;

    $display("");
    $display("== Check results: Section 2 ==");
    // Verify D-mem was overwritten by STR
    read_dmem_word(8'd3, rd0);
    $display("[%0t] D-mem[3] after STR = 0x%016h  (expect 0x0000000000000063)", $time, rd0);
    if (rd0 !== 64'd99) begin
      $display("  FAIL  [STR dmem[3]=99]  got=0x%016h  expected=0x%016h",
               rd0, 64'd99);
      fail_count = fail_count + 1;
    end else begin
      $display("  PASS  [STR dmem[3]=99]  dmem[3] = 0x%016h", rd0);
      pass_count = pass_count + 1;
    end
    // Verify register was loaded by LDR
    check_reg(4'd2, 64'd99, "LDR R2=dmem[3]");   // 99=0x63

    // =========================================================================
    // SECTION 3 ? Branch  (B forward: skip two poison ADDs, land on MOV)
    //
    // Word layout:
    //   0   MOV R1, #0            canary, must stay 0 if branch works
    //   1-7  NOP x7
    //   8   B +1                  jump to word 11
    //                             offset = 11 - 8 - 2 = 1
    //   9   ADD R1, R1, #1        POISON ? skipped
    //  10   ADD R1, R1, #1        POISON ? skipped
    //  11   MOV R2, #0xFF         branch lands here -> R2 = 255
    //  12-26  NOP x15  (drain)
    //
    //  branch_target = ifid_pc + 2 + offset24 = 8 + 2 + 1 = 11  OK
    // =========================================================================
    $display("");
    $display("== Section 3: Branch (B forward, skip poison) ==");

    program_imem_word(9'd0,  f_mov(4'd1, 8'd0));
    program_imem_word(9'd1,  NOP);
    program_imem_word(9'd2,  NOP);
    program_imem_word(9'd3,  NOP);
    program_imem_word(9'd4,  NOP);
    program_imem_word(9'd5,  NOP);
    program_imem_word(9'd6,  NOP);
    program_imem_word(9'd7,  NOP);
    program_imem_word(9'd8,  f_b(24'd1));                    // B -> word 11
    program_imem_word(9'd9,  f_add_i(4'd1, 4'd1, 8'd1));    // POISON
    program_imem_word(9'd10, f_add_i(4'd1, 4'd1, 8'd1));    // POISON
    program_imem_word(9'd11, f_mov(4'd2, 8'hFF));            // landing
    program_imem_word(9'd12, NOP);
    program_imem_word(9'd13, NOP);
    program_imem_word(9'd14, NOP);
    program_imem_word(9'd15, NOP);
    program_imem_word(9'd16, NOP);
    program_imem_word(9'd17, NOP);
    program_imem_word(9'd18, NOP);
    program_imem_word(9'd19, NOP);
    program_imem_word(9'd20, NOP);
    program_imem_word(9'd21, NOP);
    program_imem_word(9'd22, NOP);
    program_imem_word(9'd23, NOP);
    program_imem_word(9'd24, NOP);
    program_imem_word(9'd25, NOP);
    program_imem_word(9'd26, NOP);

    $display("== Pulse PC reset ==");
    pulse_pc_reset();

    $display("== Run CPU (Section 3) ==");
    run = 1'b1;
    repeat (40) @(posedge clk);
    #1;
    run = 1'b0;

    $display("");
    $display("== Check results: Section 3 ==");
    check_reg(4'd1, 64'h0000000000000000, "Branch: R1 stays 0 (poison skipped)");
    check_reg(4'd2, 64'h00000000000000FF, "Branch: R2=0xFF (landing executed)");

    // =========================================================================
    // SECTION 4 ? Step mode and pc_reset_pulse
    //
    // With run=0 and step=0 the pipeline is frozen; PC must not advance.
    // A rising edge of step advances the pipeline by exactly one word.
    // pc_reset_pulse drives PC back to 0 at any time.
    // =========================================================================
    $display("");
    $display("== Section 4: Step mode and pc_reset_pulse ==");

    // Write a trivial instruction so imem word 0 is not garbage
    program_imem_word(9'd0, f_mov(4'd3, 8'd7));

    pulse_pc_reset();   // ensure we start at PC=0

    // Check PC is frozen at 0
    repeat (5) @(posedge clk); #1;
    if (pc_dbg === 9'd0) begin
      $display("  PASS  [Step-halt]  PC=0 while run=0, step=0");
      pass_count = pass_count + 1;
    end else begin
      $display("  FAIL  [Step-halt]  PC should be 0, got %0d", pc_dbg);
      fail_count = fail_count + 1;
    end

    // First step pulse -> PC advances to 1
    step = 1'b1; @(posedge clk); #1;
    step = 1'b0; @(posedge clk); #1;
    if (pc_dbg === 9'd1) begin
      $display("  PASS  [Step-1]  PC=1 after first step pulse");
      pass_count = pass_count + 1;
    end else begin
      $display("  FAIL  [Step-1]  PC should be 1, got %0d", pc_dbg);
      fail_count = fail_count + 1;
    end

    // Second step pulse -> PC advances to 2
    step = 1'b1; @(posedge clk); #1;
    step = 1'b0; @(posedge clk); #1;
    if (pc_dbg === 9'd2) begin
      $display("  PASS  [Step-2]  PC=2 after second step pulse");
      pass_count = pass_count + 1;
    end else begin
      $display("  FAIL  [Step-2]  PC should be 2, got %0d", pc_dbg);
      fail_count = fail_count + 1;
    end

    // Stall: 5 more cycles with step=0 run=0 -> PC must not change
    repeat (5) @(posedge clk); #1;
    if (pc_dbg === 9'd2) begin
      $display("  PASS  [Step-stall]  PC stays 2 while halted");
      pass_count = pass_count + 1;
    end else begin
      $display("  FAIL  [Step-stall]  PC should still be 2, got %0d", pc_dbg);
      fail_count = fail_count + 1;
    end

    // Run freely to move PC well past 2, then test pc_reset_pulse
    run = 1'b1;
    repeat (10) @(posedge clk); #1;
    run = 1'b0;

    $display("== Pulse PC reset ==");
    pulse_pc_reset();

    if (pc_dbg === 9'd0) begin
      $display("  PASS  [pc_reset_pulse]  PC=0 after pulse");
      pass_count = pass_count + 1;
    end else begin
      $display("  FAIL  [pc_reset_pulse]  PC should be 0, got %0d", pc_dbg);
      fail_count = fail_count + 1;
    end

    // =========================================================================
    // FINAL SUMMARY
    // =========================================================================
    $display("");
    $display("============================================================");
    $display("  RESULTS:  %0d passed,  %0d failed", pass_count, fail_count);
    if (fail_count == 0)
      $display("  ALL TESTS PASSED");
    else
      $display("  *** FAILURES DETECTED ? inspect tb_pipeline_p.vcd ***");
    $display("============================================================");
    $display("");

    $finish;
  end

  // ??? Timeout watchdog ??????????????????????????????????????????????????????
  initial begin
    #500_000;
    $display("TIMEOUT ? simulation exceeded 500 us");
    $finish;
  end

endmodule
