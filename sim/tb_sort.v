`timescale 1ns/1ps
// =============================================================================
// tb_sort.v  –  Bubble-sort testbench for pipeline_p.v (extended ISA)
//
// Implements the following ARM-like assembly in the pipeline's ISA:
//
//   main:
//     MOV R1,#0        ; base address of array (DMEM word 0)
//     MOV R0,#0        ; zero constant
//     MOV R7,#0        ; shift amount 0  ← KEY ADAPTATION
//     MOV R2,#0        ; i = 0
//   i_loop:
//     MOV R10,#10
//     SLT R11,R2,R10   ; R11 = (i<10)?1:0
//     BEQ R11,R0,done  ; i>=10 → done
//     [4 NOPs]
//     MOV R3,R2        ; j = i
//     ADD R3,R3,#1     ; j = i+1
//   j_loop:
//     SLT R11,R3,R10   ; R11 = (j<10)?1:0
//     BEQ R11,R0,i_next; j>=10 → i_next
//     [4 NOPs]
//     SLL R8,R2,R7     ; R8 = i<<0 = i  (word address of array[i])
//     ADD R8,R1,R8     ; R8 = 0 + i = i
//     SLL R9,R3,R7     ; R9 = j<<0 = j
//     ADD R9,R1,R9     ; R9 = 0 + j = j
//     LDR R5,[R8,#0]   ; R5 = array[i]
//     LDR R6,[R9,#0]   ; R6 = array[j]
//     SLT R4,R6,R5     ; R4 = (array[j]<array[i])?1:0
//     BEQ R4,R0,no_swap
//     [4 NOPs]
//     STR R5,[R9,#0]   ; array[j] = old array[i]
//     STR R6,[R8,#0]   ; array[i] = old array[j]
//   no_swap:
//     ADD R3,R3,#1     ; j++
//     B   j_loop
//     [4 NOPs]
//   i_next:
//     ADD R2,R2,#1     ; i++
//     B   i_loop
//     [4 NOPs]
//   done / halt:
//     NOP ; B halt ; [4 NOPs] ; halt: NOP
//
// MEMORY MODEL ADAPTATION (vs original ARM):
//   Original ARM uses byte addressing: addr = base + i*4
//   This pipeline: mem_bram_addr = alu_result[7:0] = WORD address
//   Solution: R7=0 so SLL Rx,Ri,R7 = Ri<<0 = Ri → addr = base + i = i
//   Array is stored at DMEM word addresses 0..9.
//
// WORD LAYOUT (computed by planning script):
//   main     = w0     i_loop  = w32    j_loop  = w69
//   no_swap  = w159   i_next  = w172   done    = w185
//   halt     = w191   total   = w207
//
// BRANCH OFFSETS (target - branch_word - 2):
//   BEQ @w48  → done   @w185  : off = +135
//   BEQ @w77  → i_next @w172  : off = +93
//   BEQ @w138 → no_swap@w159  : off = +19
//   B   @w167 → j_loop @w69   : off = -100
//   B   @w180 → i_loop @w32   : off = -150
//   B   @w186 → halt   @w191  : off = +3
//
// INPUT array:  {323, 123, -455, 2, 98, 125, 10, 65, -56, 0}
// OUTPUT array: {-455, -56, 0, 2, 10, 65, 98, 123, 125, 323}
// =============================================================================

module tb_sort;

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

  integer pass_count;
  integer fail_count;

  // ─── DUT ───────────────────────────────────────────────────────────────────
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

  // ─── Clock (10 ns) ─────────────────────────────────────────────────────────
  localparam CLK_PERIOD = 10;
  initial clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  // ===========================================================================
  // Encoding functions  (identical to tb_pipeline_p_ext.v)
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

  function [31:0] f_sll;
    input [3:0] Rd, Rn, Rm;
    f_sll = {4'hE, 3'b000, 4'b0110, 1'b0, Rn, Rd, 8'h00, Rm};
  endfunction

  function [31:0] f_slt;
    input [3:0] Rd, Rn, Rm;
    f_slt = {4'hE, 3'b000, 4'b1011, 1'b0, Rn, Rd, 8'h00, Rm};
  endfunction

  function [31:0] f_beq;   // off16 = target_word - beq_word - 2
    input [3:0] Rn, Rm; input [15:0] off16;
    f_beq = {4'hE, 4'b1000, Rn, Rm, off16};
  endfunction

  function [31:0] f_b;     // off24 = target_word - b_word - 2
    input [23:0] off24;
    f_b = {4'hE, 4'b1010, off24};
  endfunction

  function [31:0] f_ldr;
    input [3:0] Rd, Rn; input [11:0] off12;
    f_ldr = {4'hE, 8'b0101_1001, Rn, Rd, off12};
  endfunction

  function [31:0] f_str;
    input [3:0] Rd, Rn; input [11:0] off12;
    f_str = {4'hE, 8'b0101_1000, Rn, Rd, off12};
  endfunction

  // ===========================================================================
  // Tasks  (same discipline as tb_pipeline_p_ext.v)
  // ===========================================================================
  task program_imem_word;
    input [8:0]  waddr;
    input [31:0] data;
    begin
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
      run            = 1'b0; step = 1'b0; pc_reset_pulse = 1'b0;
      imem_prog_we   = 1'b0; imem_prog_addr = 9'h0; imem_prog_wdata = 32'h0;
      dmem_prog_en   = 1'b0; dmem_prog_we   = 1'b0;
      dmem_prog_addr = 8'h0; dmem_prog_wdata= 64'h0;
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

  // ─── check_dmem ────────────────────────────────────────────────────────────
  task check_dmem;
    input [7:0]   waddr;
    input [63:0]  expected;
    input [127:0] label;
    reg   [63:0]  actual;
    begin
      read_dmem_word(waddr, actual);
      if (actual === expected) begin
        $display("  PASS  %-34s  DMEM[%0d] = 0x%016h (%0d)",
                 label, waddr, actual, $signed(actual));
        pass_count = pass_count + 1;
      end else begin
        $display("  FAIL  %-34s  DMEM[%0d]  got=0x%016h (%0d)  exp=0x%016h (%0d)",
                 label, waddr, actual, $signed(actual),
                 expected, $signed(expected));
        fail_count = fail_count + 1;
      end
    end
  endtask

  // ─── WB monitor ────────────────────────────────────────────────────────────
  always @(posedge clk) begin
    if (!reset && dut.wb_wen)
      $display("[%0t] WB  R%0d <- 0x%016h  (pc=%0d)",
               $time, dut.wb_waddr, dut.wb_wdata, pc_dbg);
  end

  // ===========================================================================
  // MAIN
  // ===========================================================================
  integer iw; // imem word pointer

  initial begin
    pass_count = 0; fail_count = 0;
    reset = 1'b1; run = 1'b0; step = 1'b0; pc_reset_pulse = 1'b0;
    imem_prog_we = 1'b0; imem_prog_addr = 9'h0; imem_prog_wdata = 32'h0;
    dmem_prog_en = 1'b0; dmem_prog_we   = 1'b0;
    dmem_prog_addr = 8'h0; dmem_prog_wdata = 64'h0;

    $dumpfile("tb_sort.vcd");
    $dumpvars(0, tb_sort);

    $display("======================================================");
    $display("  Bubble Sort Testbench  (pipeline_p.v extended ISA)");
    $display("======================================================");

    repeat(3) @(posedge clk); #1;
    reset = 1'b0;
    @(posedge clk); #1;

    // =========================================================================
    // Step 1 – Load initial array into DMEM (word addresses 0..9)
    //   {323, 123, -455, 2, 98, 125, 10, 65, -56, 0}
    // =========================================================================
    $display("\n--- Loading array into DMEM ---");
    program_dmem_word(8'd0, 64'sd323);
    program_dmem_word(8'd1, 64'sd123);
    program_dmem_word(8'd2, 64'hFFFFFFFFFFFFFE39); // -455 as 64-bit two's complement
    program_dmem_word(8'd3, 64'sd2);
    program_dmem_word(8'd4, 64'sd98);
    program_dmem_word(8'd5, 64'sd125);
    program_dmem_word(8'd6, 64'sd10);
    program_dmem_word(8'd7, 64'sd65);
    program_dmem_word(8'd8, 64'hFFFFFFFFFFFFFFC8); // -56 as 64-bit two's complement
    program_dmem_word(8'd9, 64'sd0);

    $display("  Loaded: [323, 123, -455, 2, 98, 125, 10, 65, -56, 0]");

    // =========================================================================
    // Step 2 – Load bubble-sort program into IMEM
    //
    // Full listing (207 words):
    //
    //   LABEL        WORD  INSTRUCTION
    //   ──────────────────────────────────────────────────────────────
    //   main:        w0    MOV R1,#0          base = DMEM word 0
    //                w1-7  NOP x7
    //                w8    MOV R0,#0          zero constant
    //                w9-15 NOP x7
    //                w16   MOV R7,#0          shift=0 (word not byte addr)
    //                w17-23 NOP x7
    //                w24   MOV R2,#0          i=0
    //                w25-31 NOP x7
    //   i_loop:      w32   MOV R10,#10
    //                w33-39 NOP x7
    //                w40   SLT R11,R2,R10
    //                w41-47 NOP x7
    //                w48   BEQ R11,R0,done    off=+135 → w185
    //                w49-52 NOP x4
    //                w53   MOV R3,R2
    //                w54-60 NOP x7
    //                w61   ADD R3,R3,#1
    //                w62-68 NOP x7
    //   j_loop:      w69   SLT R11,R3,R10
    //                w70-76 NOP x7
    //                w77   BEQ R11,R0,i_next  off=+93 → w172
    //                w78-81 NOP x4
    //                w82   SLL R8,R2,R7
    //                w83-89 NOP x7
    //                w90   ADD R8,R1,R8
    //                w91-97 NOP x7
    //                w98   SLL R9,R3,R7
    //                w99-105 NOP x7
    //                w106  ADD R9,R1,R9
    //                w107-113 NOP x7
    //                w114  LDR R5,[R8,#0]
    //                w115-121 NOP x7
    //                w122  LDR R6,[R9,#0]
    //                w123-129 NOP x7
    //                w130  SLT R4,R6,R5
    //                w131-137 NOP x7
    //                w138  BEQ R4,R0,no_swap  off=+19 → w159
    //                w139-142 NOP x4
    //                w143  STR R5,[R9,#0]
    //                w144-150 NOP x7
    //                w151  STR R6,[R8,#0]
    //                w152-158 NOP x7
    //   no_swap:     w159  ADD R3,R3,#1
    //                w160-166 NOP x7
    //                w167  B j_loop           off=-100 → w69
    //                w168-171 NOP x4
    //   i_next:      w172  ADD R2,R2,#1
    //                w173-179 NOP x7
    //                w180  B i_loop           off=-150 → w32
    //                w181-184 NOP x4
    //   done:        w185  NOP
    //                w186  B halt             off=+3 → w191
    //                w187-190 NOP x4
    //   halt:        w191  NOP
    //                w192-206 NOP x15  (drain)
    // =========================================================================
    $display("\n--- Programming IMEM (207 words) ---");
    do_reset;
    iw = 0;

    // ── main (w0-31) ──────────────────────────────────────────────────────────
    program_imem_word(iw, f_mov(4'd1, 8'd0));   iw=iw+1; // w0   MOV R1,#0
    repeat(7) begin program_imem_word(iw,NOP); iw=iw+1; end // w1-7

    program_imem_word(iw, f_mov(4'd0, 8'd0));   iw=iw+1; // w8   MOV R0,#0
    repeat(7) begin program_imem_word(iw,NOP); iw=iw+1; end // w9-15

    program_imem_word(iw, f_mov(4'd7, 8'd0));   iw=iw+1; // w16  MOV R7,#0
    repeat(7) begin program_imem_word(iw,NOP); iw=iw+1; end // w17-23

    program_imem_word(iw, f_mov(4'd2, 8'd0));   iw=iw+1; // w24  MOV R2,#0  (i=0)
    repeat(7) begin program_imem_word(iw,NOP); iw=iw+1; end // w25-31

    // ── i_loop (w32-68) ───────────────────────────────────────────────────────
    if (iw !== 32) $display("ERROR: i_loop expected at w32, got w%0d", iw);
    program_imem_word(iw, f_mov(4'd10, 8'd10)); iw=iw+1; // w32  MOV R10,#10
    repeat(7) begin program_imem_word(iw,NOP); iw=iw+1; end // w33-39

    program_imem_word(iw, f_slt(4'd11,4'd2,4'd10)); iw=iw+1; // w40  SLT R11,R2,R10
    repeat(7) begin program_imem_word(iw,NOP); iw=iw+1; end  // w41-47

    // w48: BEQ R11,R0,done  |  done@185, off = 185-48-2 = +135
    program_imem_word(iw, f_beq(4'd11,4'd0, 16'd135)); iw=iw+1; // w48
    repeat(4) begin program_imem_word(iw,NOP); iw=iw+1; end // w49-52  (4 NOPs after BEQ)

    program_imem_word(iw, f_add_i(4'd3,4'd2,8'd0));    iw=iw+1; // w53  ADD R3,R2,#0 (j=i)
    repeat(7) begin program_imem_word(iw,NOP); iw=iw+1; end // w54-60

    program_imem_word(iw, f_add_i(4'd3,4'd3,8'd1));    iw=iw+1; // w61  ADD R3,R3,#1 (j=i+1)
    repeat(7) begin program_imem_word(iw,NOP); iw=iw+1; end // w62-68

    // ── j_loop (w69-171) ──────────────────────────────────────────────────────
    if (iw !== 69) $display("ERROR: j_loop expected at w69, got w%0d", iw);
    program_imem_word(iw, f_slt(4'd11,4'd3,4'd10)); iw=iw+1; // w69  SLT R11,R3,R10
    repeat(7) begin program_imem_word(iw,NOP); iw=iw+1; end  // w70-76

    // w77: BEQ R11,R0,i_next  |  i_next@172, off = 172-77-2 = +93
    program_imem_word(iw, f_beq(4'd11,4'd0,16'd93)); iw=iw+1; // w77
    repeat(4) begin program_imem_word(iw,NOP); iw=iw+1; end   // w78-81  (4 NOPs)

    program_imem_word(iw, f_sll(4'd8,4'd2,4'd7));    iw=iw+1; // w82  SLL R8,R2,R7
    repeat(7) begin program_imem_word(iw,NOP); iw=iw+1; end   // w83-89

    program_imem_word(iw, f_add_r(4'd8,4'd1,4'd8));  iw=iw+1; // w90  ADD R8,R1,R8
    repeat(7) begin program_imem_word(iw,NOP); iw=iw+1; end   // w91-97

    program_imem_word(iw, f_sll(4'd9,4'd3,4'd7));    iw=iw+1; // w98  SLL R9,R3,R7
    repeat(7) begin program_imem_word(iw,NOP); iw=iw+1; end   // w99-105

    program_imem_word(iw, f_add_r(4'd9,4'd1,4'd9));  iw=iw+1; // w106 ADD R9,R1,R9
    repeat(7) begin program_imem_word(iw,NOP); iw=iw+1; end   // w107-113

    program_imem_word(iw, f_ldr(4'd5,4'd8,12'd0));   iw=iw+1; // w114 LDR R5,[R8,#0]
    repeat(7) begin program_imem_word(iw,NOP); iw=iw+1; end   // w115-121

    program_imem_word(iw, f_ldr(4'd6,4'd9,12'd0));   iw=iw+1; // w122 LDR R6,[R9,#0]
    repeat(7) begin program_imem_word(iw,NOP); iw=iw+1; end   // w123-129

    program_imem_word(iw, f_slt(4'd4,4'd6,4'd5));    iw=iw+1; // w130 SLT R4,R6,R5
    repeat(7) begin program_imem_word(iw,NOP); iw=iw+1; end   // w131-137

    // w138: BEQ R4,R0,no_swap  |  no_swap@159, off = 159-138-2 = +19
    program_imem_word(iw, f_beq(4'd4,4'd0,16'd19));  iw=iw+1; // w138
    repeat(4) begin program_imem_word(iw,NOP); iw=iw+1; end   // w139-142  (4 NOPs)

    program_imem_word(iw, f_str(4'd5,4'd9,12'd0));   iw=iw+1; // w143 STR R5,[R9,#0]
    repeat(7) begin program_imem_word(iw,NOP); iw=iw+1; end   // w144-150

    program_imem_word(iw, f_str(4'd6,4'd8,12'd0));   iw=iw+1; // w151 STR R6,[R8,#0]
    repeat(7) begin program_imem_word(iw,NOP); iw=iw+1; end   // w152-158

    // ── no_swap (w159-171) ────────────────────────────────────────────────────
    if (iw !== 159) $display("ERROR: no_swap expected at w159, got w%0d", iw);
    program_imem_word(iw, f_add_i(4'd3,4'd3,8'd1));  iw=iw+1; // w159 ADD R3,R3,#1 (j++)
    repeat(7) begin program_imem_word(iw,NOP); iw=iw+1; end   // w160-166

    // w167: B j_loop  |  j_loop@69, off = 69-167-2 = -100
    program_imem_word(iw, f_b(24'hFFFF9C));           iw=iw+1; // w167  -100 = 0xFFFF9C (24-bit)
    repeat(4) begin program_imem_word(iw,NOP); iw=iw+1; end   // w168-171  (4 NOPs)

    // ── i_next (w172-184) ─────────────────────────────────────────────────────
    if (iw !== 172) $display("ERROR: i_next expected at w172, got w%0d", iw);
    program_imem_word(iw, f_add_i(4'd2,4'd2,8'd1));  iw=iw+1; // w172 ADD R2,R2,#1 (i++)
    repeat(7) begin program_imem_word(iw,NOP); iw=iw+1; end   // w173-179

    // w180: B i_loop  |  i_loop@32, off = 32-180-2 = -150
    program_imem_word(iw, f_b(24'hFFFF6A));           iw=iw+1; // w180  -150 = 0xFFFF6A (24-bit)
    repeat(4) begin program_imem_word(iw,NOP); iw=iw+1; end   // w181-184  (4 NOPs)

    // ── done / halt (w185-206) ────────────────────────────────────────────────
    if (iw !== 185) $display("ERROR: done expected at w185, got w%0d", iw);
    program_imem_word(iw, NOP);                       iw=iw+1; // w185 done: NOP

    // w186: B halt  |  halt@191, off = 191-186-2 = +3
    program_imem_word(iw, f_b(24'd3));                iw=iw+1; // w186
    repeat(4) begin program_imem_word(iw,NOP); iw=iw+1; end   // w187-190  (4 NOPs)

    if (iw !== 191) $display("ERROR: halt expected at w191, got w%0d", iw);
    program_imem_word(iw, NOP);                       iw=iw+1; // w191 halt: NOP

    // drain NOPs (flush pipeline)
    repeat(15) begin program_imem_word(iw,NOP); iw=iw+1; end  // w192-206

    $display("  IMEM loaded: %0d words", iw);

    // =========================================================================
    // Step 3 – Run the sort
    //
    // Cycles needed:
    //   Outer loop: 10 iterations of i
    //   Inner loop: up to 9 iterations of j per i, average ~5
    //   Each j-loop body: ~130 words including all NOPs
    //   Total real work: ~10*5*130 = ~6500 cycles; add 3x margin = 20000
    // =========================================================================
    $display("\n--- Running bubble sort ---");
    pulse_pc_reset();
    run_cycles(20000);
    $display("  Simulation complete.");

    // =========================================================================
    // Step 4 – Verify sorted array in DMEM
    //
    // Input:  [323, 123, -455, 2, 98, 125, 10, 65, -56, 0]
    // Output: [-455, -56, 0, 2, 10, 65, 98, 123, 125, 323]
    // =========================================================================
    $display("\n--- Checking sorted array ---");

    check_dmem(8'd0, 64'hFFFFFFFFFFFFFE39, "DMEM[0] = -455");
    check_dmem(8'd1, 64'hFFFFFFFFFFFFFFC8, "DMEM[1] = -56");
    check_dmem(8'd2, 64'h0000000000000000, "DMEM[2] = 0");
    check_dmem(8'd3, 64'h0000000000000002, "DMEM[3] = 2");
    check_dmem(8'd4, 64'h000000000000000A, "DMEM[4] = 10");
    check_dmem(8'd5, 64'h0000000000000041, "DMEM[5] = 65");
    check_dmem(8'd6, 64'h0000000000000062, "DMEM[6] = 98");
    check_dmem(8'd7, 64'h000000000000007B, "DMEM[7] = 123");
    check_dmem(8'd8, 64'h000000000000007D, "DMEM[8] = 125");
    check_dmem(8'd9, 64'h0000000000000143, "DMEM[9] = 323");

    // =========================================================================
    // SUMMARY
    // =========================================================================
    $display("\n======================================================");
    $display("  Results: %0d PASSED   %0d FAILED", pass_count, fail_count);
    $display("======================================================");
    if (fail_count == 0)
      $display("  ALL TESTS PASSED – array sorted correctly");
    else
      $display("  *** FAILURES – inspect tb_sort.vcd ***");
    $display("======================================================\n");

    $finish;
  end

  // ─── Watchdog ──────────────────────────────────────────────────────────────
  initial begin
    #30_000_000;
    $display("TIMEOUT – sort did not complete in 30 ms sim time");
    $finish;
  end

endmodule
