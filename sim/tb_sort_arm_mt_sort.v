`timescale 1ns/1ps
// =============================================================================
// tb_sort.v  ?  Bubble-sort testbench for pipeline_p.v  (NO NOPs version)
//
// The program contains ZERO hazard-guard NOPs and ZERO branch-delay NOPs.
// All 28 instructions map 1-to-1 from the original assembly, with only
// two structural adaptations vs the ARM source:
//
//   1. R7 = 0 instead of R7 = 2  (pipeline uses word addresses, not byte)
//   2. MOV R3,R2 encoded as ADD R3,R2,#0 (no reg-to-reg MOV in this ISA)
//
// Full instruction listing (28 words):
// ?????????????????????????????????????????????????????????????????????????????
//  w 0  main:     MOV  R1,#0          R1 = base address (DMEM word 0)
//  w 1            MOV  R0,#0          R0 = zero constant
//  w 2            MOV  R7,#0          R7 = shift amount 0 (word addressing)
//  w 3            MOV  R2,#0          i = 0
//  w 4  i_loop:   MOV  R10,#10        limit = 10
//  w 5            SLT  R11,R2,R10     R11 = (i < 10) ? 1 : 0
//  w 6            BEQ  R11,R0,done    off=+17 ? w25   if i>=10 goto done
//  w 7            ADD  R3,R2,#0       j = i
//  w 8            ADD  R3,R3,#1       j = i + 1
//  w 9  j_loop:   SLT  R11,R3,R10    R11 = (j < 10) ? 1 : 0
//  w10            BEQ  R11,R0,i_next  off=+11 ? w23   if j>=10 goto i_next
//  w11            SLL  R8,R2,R7       R8 = i << 0 = i  (word addr of array[i])
//  w12            ADD  R8,R1,R8       R8 = base + i
//  w13            SLL  R9,R3,R7       R9 = j << 0 = j  (word addr of array[j])
//  w14            ADD  R9,R1,R9       R9 = base + j
//  w15            LDR  R5,[R8,#0]     R5 = array[i]
//  w16            LDR  R6,[R9,#0]     R6 = array[j]
//  w17            SLT  R4,R6,R5       R4 = (array[j] < array[i]) ? 1 : 0
//  w18            BEQ  R4,R0,no_swap  off=+1  ? w21   if no swap needed skip
//  w19            STR  R5,[R9,#0]     array[j] = old array[i]
//  w20            STR  R6,[R8,#0]     array[i] = old array[j]
//  w21  no_swap:  ADD  R3,R3,#1       j++
//  w22            B    j_loop         off=-15 (24'hFFFFF1) ? w9
//  w23  i_next:   ADD  R2,R2,#1       i++
//  w24            B    i_loop         off=-22 (24'hFFFFEA) ? w4
//  w25  done:     NOP
//  w26            B    halt           off=-1  (24'hFFFFFF) ? w27
//  w27  halt:     NOP
//
// Branch offset formula: off = target_word - branch_word - 2
//
// INPUT  array: [323, 123, -455, 2, 98, 125, 10, 65, -56, 0]
// SORTED array: [-455, -56, 0, 2, 10, 65, 98, 123, 125, 323]
// =============================================================================

module tb_sort_1nop;

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

  integer pass_count;
  integer fail_count;

  // ??? DUT instantiation ?????????????????????????????????????????????????????
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

  // ??? Clock: 10 ns period ???????????????????????????????????????????????????
  localparam CLK_PERIOD = 10;
  initial clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  // ===========================================================================
  // Instruction encoding functions
  // ===========================================================================
  localparam NOP = 32'hE000_0000;   // AND R0,R0,R0

  function [31:0] f_mov;            // MOV Rd, #imm8
    input [3:0] Rd; input [7:0] imm8;
    f_mov = {4'hE, 3'b001, 4'b1101, 1'b0, 4'h0, Rd, 4'h0, imm8};
  endfunction

  function [31:0] f_add_r;          // ADD Rd, Rn, Rm
    input [3:0] Rd, Rn, Rm;
    f_add_r = {4'hE, 3'b000, 4'b0100, 1'b0, Rn, Rd, 8'h00, Rm};
  endfunction

  function [31:0] f_add_i;          // ADD Rd, Rn, #imm8
    input [3:0] Rd, Rn; input [7:0] imm8;
    f_add_i = {4'hE, 3'b001, 4'b0100, 1'b0, Rn, Rd, 4'h0, imm8};
  endfunction

  function [31:0] f_sll;            // SLL Rd, Rn, Rm  (Rd = Rn << Rm[5:0])
    input [3:0] Rd, Rn, Rm;
    f_sll = {4'hE, 3'b000, 4'b0110, 1'b0, Rn, Rd, 8'h00, Rm};
  endfunction

  function [31:0] f_slt;            // SLT Rd, Rn, Rm  (Rd = (Rn < Rm) ? 1 : 0)
    input [3:0] Rd, Rn, Rm;
    f_slt = {4'hE, 3'b000, 4'b1011, 1'b0, Rn, Rd, 8'h00, Rm};
  endfunction

  function [31:0] f_beq;            // BEQ Rn, Rm, off16
    input [3:0] Rn, Rm; input [15:0] off16;
    f_beq = {4'hE, 4'b1000, Rn, Rm, off16};
  endfunction

  function [31:0] f_b;              // B off24
    input [23:0] off24;
    f_b = {4'hE, 4'b1010, off24};
  endfunction

  function [31:0] f_ldr;            // LDR Rd, [Rn, #off12]
    input [3:0] Rd, Rn; input [11:0] off12;
    f_ldr = {4'hE, 8'b0101_1001, Rn, Rd, off12};
  endfunction

  function [31:0] f_str;            // STR Rd, [Rn, #off12]
    input [3:0] Rd, Rn; input [11:0] off12;
    f_str = {4'hE, 8'b0101_1000, Rn, Rd, off12};
  endfunction

  // ===========================================================================
  // Tasks  (identical discipline to tb_pipeline_p_ext.v)
  // ===========================================================================
    integer file_handle_imem;
  integer file_handle_dmem;
  initial begin
  file_handle_imem = $fopen("imem_mt_1nop.txt", "w");
  file_handle_dmem = $fopen("dmem_mt_1nop.txt", "w");
  end
  task program_imem_word;
    input [8:0]  waddr;
    input [31:0] data;
    begin
	 	   $fwrite(file_handle_imem, "%h;%h\n", waddr, data);

      run = 1'b0; step = 1'b0;
      imem_prog_addr  = waddr;
      imem_prog_wdata = data;
      imem_prog_we    = 1'b1;
      @(posedge clk); #1;
      imem_prog_we = 1'b0;
    end
  endtask

  task program_dmem_word;
    input [7:0]  waddr;
    input [63:0] data;
    begin
	 	   $fwrite(file_handle_dmem, "%h;%h\n", waddr, data);
      run = 1'b0; step = 1'b0;
      dmem_prog_addr  = waddr;
      dmem_prog_wdata = data;
      dmem_prog_en    = 1'b1;
      dmem_prog_we    = 1'b1;
      @(posedge clk); #1;
      dmem_prog_we = 1'b0;
      dmem_prog_en = 1'b0;
    end
  endtask

  task read_dmem_word;
    input  [7:0]  waddr;
    output [63:0] data;
    begin
      run = 1'b0; step = 1'b0;
      dmem_prog_addr  = waddr;
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
      run = 1'b0; step = 1'b0; pc_reset_pulse = 1'b0;
      imem_prog_we   = 1'b0; imem_prog_addr  = 9'h0; imem_prog_wdata = 32'h0;
      dmem_prog_en   = 1'b0; dmem_prog_we    = 1'b0;
      dmem_prog_addr = 8'h0; dmem_prog_wdata = 64'h0;
      repeat(4) @(posedge clk); #1;
      reset = 1'b0;
      @(posedge clk); #1;
    end
  endtask

  task run_cycles;
    input integer n;
    begin
      run = 1'b1;
      repeat(n) @(posedge clk);
      #1;
      run = 1'b0;
    end
  endtask

  // ??? check_dmem ????????????????????????????????????????????????????????????
  task check_dmem;
    input [7:0]   waddr;
    input [63:0]  expected;
    input [127:0] label;
    reg   [63:0]  actual;
    begin
      read_dmem_word(waddr, actual);
      if (actual === expected) begin
        $display("  PASS  %-26s  DMEM[%0d] = 0x%016h  (%0d)",
                 label, waddr, actual, $signed(actual));
        pass_count = pass_count + 1;
      end else begin
        $display("  FAIL  %-26s  DMEM[%0d]  got=0x%016h(%0d)  exp=0x%016h(%0d)",
                 label, waddr, actual, $signed(actual),
                 expected, $signed(expected));
        fail_count = fail_count + 1;
      end
    end
  endtask

  // ??? WB monitor ????????????????????????????????????????????????????????????
  always @(posedge clk) begin
    if (!reset && dut.wb_wen)
      $display("[%0t] WB  R%0d <- 0x%016h  (pc=%0d)",
               $time, dut.wb_waddr, dut.wb_wdata, pc_dbg);
  end

  // ===========================================================================
  // MAIN
  // ===========================================================================
  initial begin
    pass_count = 0; fail_count = 0;
    reset = 1'b1; run = 1'b0; step = 1'b0; pc_reset_pulse = 1'b0;
    imem_prog_we   = 1'b0; imem_prog_addr  = 9'h0; imem_prog_wdata = 32'h0;
    dmem_prog_en   = 1'b0; dmem_prog_we    = 1'b0;
    dmem_prog_addr = 8'h0; dmem_prog_wdata = 64'h0;

    $dumpfile("tb_sort_1nop.vcd");
    $dumpvars(0, tb_sort_1nop);

    $display("======================================================");
    $display("  Bubble Sort Testbench  (NO NOPs  ?  pipeline_p.v)");
    $display("======================================================");

    repeat(3) @(posedge clk); #1;
    reset = 1'b0;
    @(posedge clk); #1;

    // =========================================================================
    // Step 1 ? Initialise DMEM with the unsorted array (word addresses 0..9)
    //
    //   Index:   0    1     2   3   4    5   6   7    8  9
    //   Value: 323  123  -455   2  98  125  10  65  -56  0
    // =========================================================================
    $display("\n--- Loading array into DMEM ---");
    program_dmem_word(8'd0, 64'h0000000000000143); //  323
    program_dmem_word(8'd1, 64'h000000000000007B); //  123
    program_dmem_word(8'd2, 64'hFFFFFFFFFFFFFE39); // -455
    program_dmem_word(8'd3, 64'h0000000000000002); //    2
    program_dmem_word(8'd4, 64'h0000000000000062); //   98
    program_dmem_word(8'd5, 64'h000000000000007D); //  125
    program_dmem_word(8'd6, 64'h000000000000000A); //   10
    program_dmem_word(8'd7, 64'h0000000000000041); //   65
    program_dmem_word(8'd8, 64'hFFFFFFFFFFFFFFC8); //  -56
    program_dmem_word(8'd9, 64'h0000000000000000); //    0
    $display("  Input:  [323, 123, -455, 2, 98, 125, 10, 65, -56, 0]");

    // =========================================================================
    // Step 2 ? Program the sort into IMEM (28 words, no NOPs at all)
    // =========================================================================
    $display("\n--- Programming IMEM (28 words, no NOPs) ---");
    do_reset;

    // ?? main: w0-3 ????????????????????????????????????????????????????????????
    program_imem_word(9'd0,  f_mov(4'd1,  8'd0));          // w0   MOV R1,#0   base=0
    program_imem_word(9'd1,  f_mov(4'd0,  8'd0));          // w1   MOV R0,#0   zero
    program_imem_word(9'd2,  f_mov(4'd7,  8'd0));          // w2   MOV R7,#0   shift=0
    program_imem_word(9'd3,  f_mov(4'd2,  8'd0));          // w3   MOV R2,#0   i=0

    // ?? i_loop: w4-8 ??????????????????????????????????????????????????????????
    program_imem_word(9'd4,  f_mov(4'd10, 8'd10));         // w4   MOV R10,#10
    program_imem_word(9'd5,  f_slt(4'd11,4'd2, 4'd10));   // w5   SLT R11,R2,R10
    // w6: BEQ R11,R0,done  off = done@25 - 6 - 2 = +17
    program_imem_word(9'd6,  f_beq(4'd11,4'd0,16'd17));   // w6   BEQ R11,R0,done
    program_imem_word(9'd7,  f_add_i(4'd3,4'd2,8'd0));    // w7   ADD R3,R2,#0  (j=i)
    program_imem_word(9'd8,  f_add_i(4'd3,4'd3,8'd1));    // w8   ADD R3,R3,#1  (j=i+1)

    // ?? j_loop: w9-22 ?????????????????????????????????????????????????????????
    program_imem_word(9'd9,  f_slt(4'd11,4'd3,4'd10));    // w9   SLT R11,R3,R10
    // w10: BEQ R11,R0,i_next  off = i_next@23 - 10 - 2 = +11
    program_imem_word(9'd10, f_beq(4'd11,4'd0,16'd11));   // w10  BEQ R11,R0,i_next
    program_imem_word(9'd11, f_sll(4'd8,4'd2,4'd7));      // w11  SLL R8,R2,R7
    program_imem_word(9'd12, f_add_r(4'd8,4'd1,4'd8));    // w12  ADD R8,R1,R8
    program_imem_word(9'd13, f_sll(4'd9,4'd3,4'd7));      // w13  SLL R9,R3,R7
    program_imem_word(9'd14, f_add_r(4'd9,4'd1,4'd9));    // w14  ADD R9,R1,R9
    program_imem_word(9'd15, f_ldr(4'd5,4'd8,12'd0));     // w15  LDR R5,[R8,#0]
    program_imem_word(9'd16, f_ldr(4'd6,4'd9,12'd0));     // w16  LDR R6,[R9,#0]
    program_imem_word(9'd17, f_slt(4'd4,4'd6,4'd5));      // w17  SLT R4,R6,R5
    // w18: BEQ R4,R0,no_swap  off = no_swap@21 - 18 - 2 = +1
    program_imem_word(9'd18, f_beq(4'd4,4'd0,16'd1));     // w18  BEQ R4,R0,no_swap
    program_imem_word(9'd19, f_str(4'd5,4'd9,12'd0));     // w19  STR R5,[R9,#0]
    program_imem_word(9'd20, f_str(4'd6,4'd8,12'd0));     // w20  STR R6,[R8,#0]

    // ?? no_swap: w21-22 ???????????????????????????????????????????????????????
    program_imem_word(9'd21, f_add_i(4'd3,4'd3,8'd1));    // w21  ADD R3,R3,#1  (j++)
    // w22: B j_loop  off = j_loop@9 - 22 - 2 = -15  (24'hFFFFF1)
    program_imem_word(9'd22, f_b(24'hFFFFF1));             // w22  B j_loop

    // ?? i_next: w23-24 ????????????????????????????????????????????????????????
    program_imem_word(9'd23, f_add_i(4'd2,4'd2,8'd1));    // w23  ADD R2,R2,#1  (i++)
    // w24: B i_loop  off = i_loop@4 - 24 - 2 = -22  (24'hFFFFEA)
    program_imem_word(9'd24, f_b(24'hFFFFEA));             // w24  B i_loop

    // ?? done / halt: w25-27 ???????????????????????????????????????????????????
    program_imem_word(9'd25, NOP);                         // w25  done: NOP
    // w26: B halt  off = halt@27 - 26 - 2 = -1  (24'hFFFFFF)
    program_imem_word(9'd26, f_b(24'hFFFFFF));             // w26  B halt
    program_imem_word(9'd27, NOP);                         // w27  halt: NOP

    $display("  IMEM programmed: 28 instructions");

    // =========================================================================
    // Step 3 ? Run the sort
    //
    // Without NOPs the program body is only 28 words but executes ~45×14 ? 630
    // instruction-cycles for the inner loop comparisons, plus pipeline drain
    // (5 stages) and branch penalties (2 cycles each × ~110 branches ? 220).
    // 3000 cycles gives a comfortable margin.
    // =========================================================================
    $display("\n--- Running bubble sort ---");
    pulse_pc_reset();
    run_cycles(10000);
    $display("  Run complete.");

    // =========================================================================
    // Step 4 ? Verify sorted array in DMEM
    //
    // Expected ascending order:
    //   [-455, -56, 0, 2, 10, 65, 98, 123, 125, 323]
    // =========================================================================
    $display("\n--- Verifying sorted array ---");
    check_dmem(8'd0, 64'hFFFFFFFFFFFFFE39, "DMEM[0] = -455");
    check_dmem(8'd1, 64'hFFFFFFFFFFFFFFC8, "DMEM[1] = -56");
    check_dmem(8'd2, 64'h0000000000000000, "DMEM[2] =  0");
    check_dmem(8'd3, 64'h0000000000000002, "DMEM[3] =  2");
    check_dmem(8'd4, 64'h000000000000000A, "DMEM[4] =  10");
    check_dmem(8'd5, 64'h0000000000000041, "DMEM[5] =  65");
    check_dmem(8'd6, 64'h0000000000000062, "DMEM[6] =  98");
    check_dmem(8'd7, 64'h000000000000007B, "DMEM[7] =  123");
    check_dmem(8'd8, 64'h000000000000007D, "DMEM[8] =  125");
    check_dmem(8'd9, 64'h0000000000000143, "DMEM[9] =  323");

    // =========================================================================
    // Summary
    // =========================================================================
    $display("\n======================================================");
    $display("  Results: %0d PASSED   %0d FAILED", pass_count, fail_count);
    $display("======================================================");
    if (fail_count == 0)
      $display("  ALL TESTS PASSED ? array sorted correctly");
    else
      $display("  *** FAILURES ? see tb_sort.vcd ***");
    $display("======================================================\n");
	  $fclose(file_handle_dmem);
	  $fclose(file_handle_imem);
    $finish;
  end

  // ??? Watchdog ??????????????????????????????????????????????????????????????
  initial begin
    #5_000_000;
    $display("TIMEOUT ? simulation exceeded 5 ms");
    $finish;
  end

endmodule
