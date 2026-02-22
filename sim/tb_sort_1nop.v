`timescale 1ns/1ps
// =============================================================================
// tb_sort.v  -  Bubble-sort testbench for pipeline_p.v
//
// NOP policy (1-NOP version):
//   - Exactly 1 NOP after every branch (BEQ, B) as a branch-delay slot
//   - Exactly 1 NOP between every producer and the next instruction that
//     reads its result as a hazard guard
//
// Program layout: 54 words  (28 real instructions + 26 NOPs)
// -----------------------------------------------------------------------------
//  w 0  main:     MOV  R1,#0          base addr = DMEM word 0
//  w 1            NOP                 hazard R1
//  w 2            MOV  R0,#0          R0 = zero constant
//  w 3            NOP                 hazard R0
//  w 4            MOV  R7,#0          R7 = shift 0  (word addr, not byte addr)
//  w 5            NOP                 hazard R7
//  w 6            MOV  R2,#0          i = 0
//  w 7            NOP                 hazard R2
//  w 8  i_loop:   MOV  R10,#10        limit = 10
//  w 9            NOP                 hazard R10
//  w10            SLT  R11,R2,R10     R11 = (i < 10) ? 1 : 0
//  w11            NOP                 hazard R11 -> BEQ
//  w12            BEQ  R11,R0,done    off=+36 -> w50   if i >= 10 goto done
//  w13            NOP                 branch delay
//  w14            ADD  R3,R2,#0       j = i
//  w15            NOP                 hazard R3 -> ADD
//  w16            ADD  R3,R3,#1       j = i+1
//  w17            NOP                 hazard R3 -> SLT j_loop
//  w18  j_loop:   SLT  R11,R3,R10    R11 = (j < 10) ? 1 : 0
//  w19            NOP                 hazard R11 -> BEQ
//  w20            BEQ  R11,R0,i_next  off=+24 -> w46   if j >= 10 goto i_next
//  w21            NOP                 branch delay
//  w22            SLL  R8,R2,R7       R8 = i  (word addr of array[i])
//  w23            NOP                 hazard R8 -> ADD
//  w24            ADD  R8,R1,R8       R8 = base + i
//  w25            NOP                 hazard R8 -> LDR
//  w26            SLL  R9,R3,R7       R9 = j  (word addr of array[j])
//  w27            NOP                 hazard R9 -> ADD
//  w28            ADD  R9,R1,R9       R9 = base + j
//  w29            NOP                 hazard R9 -> LDR
//  w30            LDR  R5,[R8,#0]     R5 = array[i]
//  w31            NOP                 hazard R5 -> SLT
//  w32            LDR  R6,[R9,#0]     R6 = array[j]
//  w33            NOP                 hazard R6 -> SLT
//  w34            SLT  R4,R6,R5       R4 = (array[j] < array[i]) ? 1 : 0
//  w35            NOP                 hazard R4 -> BEQ
//  w36            BEQ  R4,R0,no_swap  off=+4  -> w42   if no swap needed skip
//  w37            NOP                 branch delay
//  w38            STR  R5,[R9,#0]     array[j] = old array[i]
//  w39            NOP                 pipeline drain before next STR
//  w40            STR  R6,[R8,#0]     array[i] = old array[j]
//  w41            NOP                 pipeline drain after STR
//  w42  no_swap:  ADD  R3,R3,#1       j++
//  w43            NOP                 hazard R3 -> SLT at j_loop head
//  w44            B    j_loop         off=-28  24'hFFFFE4 -> w18
//  w45            NOP                 branch delay
//  w46  i_next:   ADD  R2,R2,#1       i++
//  w47            NOP                 hazard R2 -> i_loop head
//  w48            B    i_loop         off=-42  24'hFFFFD6 -> w8
//  w49            NOP                 branch delay
//  w50  done:     NOP
//  w51            B    halt           off=0    24'h000000 -> w53
//  w52            NOP                 branch delay
//  w53  halt:     NOP                 halt landing
//
// Branch offsets  (target_word - branch_word - 2):
//   BEQ @w12 -> done    @w50 : +36
//   BEQ @w20 -> i_next  @w46 : +24
//   BEQ @w36 -> no_swap @w42 : +4
//   B   @w44 -> j_loop  @w18 : -28  (24'hFFFFE4)
//   B   @w48 -> i_loop  @w8  : -42  (24'hFFFFD6)
//   B   @w51 -> halt    @w53 :  0   (24'h000000)
//
// Memory model adaptation:
//   Pipeline uses mem_bram_addr = alu_result[7:0] as a WORD address.
//   Original ARM uses i*4 for byte addressing; here R7=0 so SLL Rx,Ri,R7
//   = Ri<<0 = Ri giving word addr = index directly.
//   Array stored at DMEM word addresses 0..9.
//
// Input  array: [323, 123, -455, 2, 98, 125, 10, 65, -56, 0]
// Sorted array: [-455, -56, 0, 2, 10, 65, 98, 123, 125, 323]
// =============================================================================

module tb_sort;

  // ---------------------------------------------------------------------------
  // DUT ports
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // DUT instantiation
  // ---------------------------------------------------------------------------
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

  // ---------------------------------------------------------------------------
  // Clock: 10 ns period
  // ---------------------------------------------------------------------------
  localparam CLK_PERIOD = 10;
  initial clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  // ===========================================================================
  // Instruction encoding functions
  // ===========================================================================
  localparam NOP = 32'hE000_0000;   // AND R0,R0,R0 (writes no visible register)

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

  function [31:0] f_beq;            // BEQ Rn, Rm, off16  (off = target - beq_word - 2)
    input [3:0] Rn, Rm; input [15:0] off16;
    f_beq = {4'hE, 4'b1000, Rn, Rm, off16};
  endfunction

  function [31:0] f_b;              // B off24  (off = target - b_word - 2)
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
  // Tasks
  // ===========================================================================
    file_handle_imem = $fopen("imem_sort_mt_1nop.txt", "w");
  file_handle_dmem = $fopen("dmem_sort_mt_1nop.txt", "w");
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
        $display("  FAIL  %-26s  DMEM[%0d]  got=0x%016h (%0d)  exp=0x%016h (%0d)",
                 label, waddr, actual, $signed(actual),
                 expected, $signed(expected));
        fail_count = fail_count + 1;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // WB monitor
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (!reset && dut.wb_wen)
      $display("[%0t] WB  R%0d <- 0x%016h  (pc=%0d)",
               $time, dut.wb_waddr, dut.wb_wdata, pc_dbg);
  end

  // ===========================================================================
  // MAIN
  // ===========================================================================
  integer iw;   // IMEM word pointer

  initial begin
    pass_count = 0; fail_count = 0;
    reset = 1'b1; run = 1'b0; step = 1'b0; pc_reset_pulse = 1'b0;
    imem_prog_we   = 1'b0; imem_prog_addr  = 9'h0; imem_prog_wdata = 32'h0;
    dmem_prog_en   = 1'b0; dmem_prog_we    = 1'b0;
    dmem_prog_addr = 8'h0; dmem_prog_wdata = 64'h0;

    $dumpfile("tb_sort.vcd");
    $dumpvars(0, tb_sort);

    $display("======================================================");
    $display("  Bubble Sort Testbench  (1 NOP per hazard/branch)");
    $display("======================================================");

    repeat(3) @(posedge clk); #1;
    reset = 1'b0;
    @(posedge clk); #1;

    // =========================================================================
    // Step 1 - Load unsorted array into DMEM word addresses 0..9
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
    $display("  Input: [323, 123, -455, 2, 98, 125, 10, 65, -56, 0]");

    // =========================================================================
    // Step 2 - Program IMEM: 54 words (28 instructions + 26 NOPs)
    // =========================================================================
    $display("\n--- Programming IMEM (54 words) ---");
    do_reset;
    iw = 0;

    // -- main: w0-7 -----------------------------------------------------------
    program_imem_word(iw, f_mov(4'd1,  8'd0));         iw=iw+1; // w0  MOV R1,#0
    program_imem_word(iw, NOP);                         iw=iw+1; // w1  NOP  hazard R1
    program_imem_word(iw, f_mov(4'd0,  8'd0));         iw=iw+1; // w2  MOV R0,#0
    program_imem_word(iw, NOP);                         iw=iw+1; // w3  NOP  hazard R0
    program_imem_word(iw, f_mov(4'd7,  8'd0));         iw=iw+1; // w4  MOV R7,#0
    program_imem_word(iw, NOP);                         iw=iw+1; // w5  NOP  hazard R7
    program_imem_word(iw, f_mov(4'd2,  8'd0));         iw=iw+1; // w6  MOV R2,#0  i=0
    program_imem_word(iw, NOP);                         iw=iw+1; // w7  NOP  hazard R2

    // -- i_loop: w8-17 --------------------------------------------------------
    if (iw !== 8) $display("ERROR: i_loop expected at w8, got w%0d", iw);
    program_imem_word(iw, f_mov(4'd10, 8'd10));        iw=iw+1; // w8  MOV R10,#10
    program_imem_word(iw, NOP);                         iw=iw+1; // w9  NOP  hazard R10
    program_imem_word(iw, f_slt(4'd11,4'd2, 4'd10));  iw=iw+1; // w10 SLT R11,R2,R10
    program_imem_word(iw, NOP);                         iw=iw+1; // w11 NOP  hazard R11
    // w12: BEQ R11,R0,done  |  done@w50, off = 50-12-2 = +36
    program_imem_word(iw, f_beq(4'd11,4'd0,16'd36));  iw=iw+1; // w12 BEQ R11,R0,done
    program_imem_word(iw, NOP);                         iw=iw+1; // w13 NOP  branch delay
    program_imem_word(iw, f_add_i(4'd3,4'd2, 8'd0));  iw=iw+1; // w14 ADD R3,R2,#0  j=i
    program_imem_word(iw, NOP);                         iw=iw+1; // w15 NOP  hazard R3
    program_imem_word(iw, f_add_i(4'd3,4'd3, 8'd1));  iw=iw+1; // w16 ADD R3,R3,#1  j=i+1
    program_imem_word(iw, NOP);                         iw=iw+1; // w17 NOP  hazard R3

    // -- j_loop: w18-45 -------------------------------------------------------
    if (iw !== 18) $display("ERROR: j_loop expected at w18, got w%0d", iw);
    program_imem_word(iw, f_slt(4'd11,4'd3, 4'd10));  iw=iw+1; // w18 SLT R11,R3,R10
    program_imem_word(iw, NOP);                         iw=iw+1; // w19 NOP  hazard R11
    // w20: BEQ R11,R0,i_next  |  i_next@w46, off = 46-20-2 = +24
    program_imem_word(iw, f_beq(4'd11,4'd0,16'd24));  iw=iw+1; // w20 BEQ R11,R0,i_next
    program_imem_word(iw, NOP);                         iw=iw+1; // w21 NOP  branch delay
    program_imem_word(iw, f_sll(4'd8, 4'd2, 4'd7));   iw=iw+1; // w22 SLL R8,R2,R7
    program_imem_word(iw, NOP);                         iw=iw+1; // w23 NOP  hazard R8
    program_imem_word(iw, f_add_r(4'd8,4'd1, 4'd8));  iw=iw+1; // w24 ADD R8,R1,R8
    program_imem_word(iw, NOP);                         iw=iw+1; // w25 NOP  hazard R8
    program_imem_word(iw, f_sll(4'd9, 4'd3, 4'd7));   iw=iw+1; // w26 SLL R9,R3,R7
    program_imem_word(iw, NOP);                         iw=iw+1; // w27 NOP  hazard R9
    program_imem_word(iw, f_add_r(4'd9,4'd1, 4'd9));  iw=iw+1; // w28 ADD R9,R1,R9
    program_imem_word(iw, NOP);                         iw=iw+1; // w29 NOP  hazard R9
    program_imem_word(iw, f_ldr(4'd5,4'd8, 12'd0));   iw=iw+1; // w30 LDR R5,[R8,#0]
    program_imem_word(iw, NOP);                         iw=iw+1; // w31 NOP  hazard R5
    program_imem_word(iw, f_ldr(4'd6,4'd9, 12'd0));   iw=iw+1; // w32 LDR R6,[R9,#0]
    program_imem_word(iw, NOP);                         iw=iw+1; // w33 NOP  hazard R6
    program_imem_word(iw, f_slt(4'd4, 4'd6, 4'd5));   iw=iw+1; // w34 SLT R4,R6,R5
    program_imem_word(iw, NOP);                         iw=iw+1; // w35 NOP  hazard R4
    // w36: BEQ R4,R0,no_swap  |  no_swap@w42, off = 42-36-2 = +4
    program_imem_word(iw, f_beq(4'd4, 4'd0, 16'd4));  iw=iw+1; // w36 BEQ R4,R0,no_swap
    program_imem_word(iw, NOP);                         iw=iw+1; // w37 NOP  branch delay
    program_imem_word(iw, f_str(4'd5,4'd9, 12'd0));   iw=iw+1; // w38 STR R5,[R9,#0]
    program_imem_word(iw, NOP);                         iw=iw+1; // w39 NOP  drain before STR
    program_imem_word(iw, f_str(4'd6,4'd8, 12'd0));   iw=iw+1; // w40 STR R6,[R8,#0]
    program_imem_word(iw, NOP);                         iw=iw+1; // w41 NOP  drain after STR

    // -- no_swap: w42-45 ------------------------------------------------------
    if (iw !== 42) $display("ERROR: no_swap expected at w42, got w%0d", iw);
    program_imem_word(iw, f_add_i(4'd3,4'd3, 8'd1));  iw=iw+1; // w42 ADD R3,R3,#1  j++
    program_imem_word(iw, NOP);                         iw=iw+1; // w43 NOP  hazard R3
    // w44: B j_loop  |  j_loop@w18, off = 18-44-2 = -28  (24'hFFFFE4)
    program_imem_word(iw, f_b(24'hFFFFE4));             iw=iw+1; // w44 B j_loop
    program_imem_word(iw, NOP);                         iw=iw+1; // w45 NOP  branch delay

    // -- i_next: w46-49 -------------------------------------------------------
    if (iw !== 46) $display("ERROR: i_next expected at w46, got w%0d", iw);
    program_imem_word(iw, f_add_i(4'd2,4'd2, 8'd1));  iw=iw+1; // w46 ADD R2,R2,#1  i++
    program_imem_word(iw, NOP);                         iw=iw+1; // w47 NOP  hazard R2
    // w48: B i_loop  |  i_loop@w8, off = 8-48-2 = -42  (24'hFFFFD6)
    program_imem_word(iw, f_b(24'hFFFFD6));             iw=iw+1; // w48 B i_loop
    program_imem_word(iw, NOP);                         iw=iw+1; // w49 NOP  branch delay

    // -- done / halt: w50-53 --------------------------------------------------
    if (iw !== 50) $display("ERROR: done expected at w50, got w%0d", iw);
    program_imem_word(iw, NOP);                         iw=iw+1; // w50 done: NOP
    // w51: B halt  |  halt@w53, off = 53-51-2 = 0  (24'h000000)
    program_imem_word(iw, f_b(24'h000000));             iw=iw+1; // w51 B halt
    program_imem_word(iw, NOP);                         iw=iw+1; // w52 NOP  branch delay
    if (iw !== 53) $display("ERROR: halt expected at w53, got w%0d", iw);
    program_imem_word(iw, NOP);                         iw=iw+1; // w53 halt: NOP
	repeat(458) begin program_imem_word(iw, NOP);                         iw=iw+1; end
    $display("  IMEM loaded: %0d words", iw);

    // =========================================================================
    // Step 3 - Run the sort
    //
    // Each j-loop body is 28 words -> 28 cycles + 2-cycle branch penalty.
    // Total j-iterations: 10+9+...+1 = 55.  55 * 30 ~ 1650 cycles.
    // i-loop overhead: 10 * 12 ~ 120 cycles.
    // Run 5000 cycles for a 2.5x safety margin.
    // =========================================================================
    $display("\n--- Running bubble sort ---");
    pulse_pc_reset();
    run_cycles(20000);
    $display("  Run complete.");

    // =========================================================================
    // Step 4 - Verify sorted array in DMEM
    // Expected ascending: [-455, -56, 0, 2, 10, 65, 98, 123, 125, 323]
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
      $display("  ALL TESTS PASSED - array sorted correctly");
    else
      $display("  *** FAILURES - inspect tb_sort.vcd ***");
    $display("======================================================\n");
	  $fclose(file_handle_dmem);
	  $fclose(file_handle_imem);
    $finish;
	 
  end

  // ---------------------------------------------------------------------------
  // Watchdog
  // ---------------------------------------------------------------------------
  initial begin
    #10_000_000;
    $display("TIMEOUT - simulation exceeded 10 ms");
    $finish;
  end

endmodule
