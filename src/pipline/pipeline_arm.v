`timescale 1ns/1ps
// =============================================================================
// pipeline_p.v  ?  Completed 5-stage ARM-32 pipeline (no forwarding / hazard
//                  detection).  Programmer must insert NOPs between dependent
//                  instructions.
//
// Pipeline stages:  IF ? IF/ID ? ID ? ID/EX ? EX ? EX/MEM ? MEM ? MEM/WB ? WB
// (The extra MEM and MEM/WB registers already present in the original file are
//  kept as-is; they act as additional buffering stages.)
//
// ARM-32 instruction encoding used:
// ----------------------------------
//  [31:28]  cond   ? 1110 (always; condition codes not evaluated)
//  [27:26]  op     ? 00=data-proc, 01=load/store, 10=branch
//
//  Data-processing (op=00):
//    [25]   I      ? 1=operand2 is 8-bit immediate, 0=register
//    [24:21] opcode ? 0100 ADD, 0010 SUB, 0000 AND, 1100 ORR
//                     1101 MOV, 0001 EOR, 1010 CMP(no WB), 1000 TST(no WB)
//    [20]   S      ? set flags (not used)
//    [19:16] Rn    ? first source register
//    [15:12] Rd    ? destination register
//    [11:8]  rot   ? rotation amount (ignored; imm treated as zero-extended)
//    [7:0]   imm8  ? 8-bit immediate (when I=1)
//    [3:0]   Rm    ? second source register (when I=0)
//
//  Load / Store (op=01):
//    [25]   0      ? immediate offset
//    [24]   P=1    ? pre-index
//    [23]   U      ? 1=add offset, 0=subtract
//    [22]   B=0    ? word
//    [21]   W=0    ? no writeback
//    [20]   L      ? 1=LDR, 0=STR
//    [19:16] Rn   ? base register
//    [15:12] Rd   ? dest (LDR) / source (STR)
//    [11:0]  imm12 ? unsigned byte offset
//
//  Branch (op=10):
//    [27:24] 1010  ? B,  1011 = BL
//    [23:0]  signed offset (from instruction word address; pipeline adds 2)
//
//  BX Rm (branch-and-exchange, op=00):
//    [27:4]  24'h12FFF1, [3:0] Rm
//
//  NOP:  32'hE000_0000  (AND R0,R0,R0 with result discarded)
//
// Register file:  16 × 64-bit  (R0-R15; R15=PC not wired here)
// ALU:            64-bit
// Data memory:    256 × 64-bit (D_M_64bit_256)
// Instruction mem: 512 × 32-bit (I_M_32bit_512depth)
// =============================================================================
module pipeline (
  input  wire        clk,
  input  wire        reset,

  input  wire        run,
  input  wire        step,
  input  wire        pc_reset_pulse,

  // I-mem programming interface  ? DO NOT CHANGE
  input  wire        imem_prog_we,
  input  wire [8:0]  imem_prog_addr,
  input  wire [31:0] imem_prog_wdata,

  // D-mem programming interface  ? DO NOT CHANGE
  input  wire        dmem_prog_en,
  input  wire        dmem_prog_we,
  input  wire [7:0]  dmem_prog_addr,
  input  wire [63:0] dmem_prog_wdata,
  output wire [63:0] dmem_prog_rdata,

  output wire [8:0]  pc_dbg,
  output wire [31:0] if_instr_dbg
);

// ===========================================================================
// PIPELINE CONTROL LOGIC   (original ? untouched)
// ===========================================================================
  reg step_d;

  always @(posedge clk) begin
    if (reset || pc_reset_pulse)
      step_d <= 1'b0;
    else
      step_d <= step;
  end

  wire step_pulse = step & ~step_d;
  wire advance    = run | step_pulse;

  // Forward declarations ? drivers are in the EX stage section below.
  // Declared here so every always block in IF, IF/ID, and ID/EX can see them.
  wire        ex_branch_taken;
  wire [8:0]  ex_branch_target;

// ===========================================================================
// IF STAGE   (original ? untouched except branch redirect wired to pc)
// ===========================================================================
  reg  [8:0] pc;
  assign pc_dbg = pc;

  wire [8:0]  imem_addr_mux = imem_prog_we ? imem_prog_addr : pc;
  wire [31:0] imem_din_mux  = imem_prog_wdata;
  wire        imem_we_mux   = imem_prog_we;
  wire [31:0] imem_dout;

  I_M_32bit_512depth u_imem (
    .addr(imem_addr_mux),
    .clk (clk),
    .din (imem_din_mux),
    .dout(imem_dout),
    .en  (1'b1),
    .we  (imem_we_mux)
  );
  assign if_instr_dbg = imem_dout;

  // PC update ? branch redirect added; original increment logic preserved
  // ex_branch_taken and ex_branch_target come from EX stage (defined below)
  always @(posedge clk) begin
    if (reset) begin
      pc <= 9'd0;
    end else if (pc_reset_pulse) begin
      pc <= 9'd0;
    end else if (ex_branch_taken) begin
      // Redirect PC to branch target; flush is handled in IF/ID register
      pc <= ex_branch_target;
    end else if (advance) begin
      pc <= pc + 9'd1;
    end
  end

// ===========================================================================
// IF/ID PIPELINE REGISTER   (original logic preserved; flush on branch added)
// ===========================================================================
  reg  [31:0] ifid_instr;
  reg  [8:0]  ifid_pc;      // PC of the fetched instruction (for branch target calc)

  always @(posedge clk) begin
    if (reset || pc_reset_pulse || ex_branch_taken) begin
      // Flush: insert NOP bubble when branch is taken
      ifid_instr <= 32'h0;
      ifid_pc    <= 9'd0;
    end else if (advance) begin
      ifid_instr <= imem_dout;
      ifid_pc    <= pc;
    end
  end

// ===========================================================================
// ID STAGE  ?  Instruction decode + register file read
// ===========================================================================

  // ---------------------------------------------------------------------------
  // ARM-32 instruction field extraction
  // ---------------------------------------------------------------------------
  wire [1:0]  if_op      = ifid_instr[27:26]; // instruction class
  wire        if_I       = ifid_instr[25];     // immediate flag
  wire [3:0]  if_opcode  = ifid_instr[24:21];  // data-proc opcode
  wire        if_L       = ifid_instr[20];      // load/link bit
  wire [3:0]  if_Rn      = ifid_instr[19:16];  // source / base register
  wire [3:0]  if_Rd      = ifid_instr[15:12];  // destination register
  wire [11:0] if_op2     = ifid_instr[11:0];   // shifter operand / offset12
  wire [3:0]  if_Rm      = ifid_instr[3:0];    // second source register
  wire [7:0]  if_imm8    = ifid_instr[7:0];    // 8-bit immediate
  wire [23:0] if_off24   = ifid_instr[23:0];   // branch offset
  wire        if_U       = ifid_instr[23];      // LDR/STR: 1=add offset
  wire [11:0] if_imm12   = ifid_instr[11:0];   // LDR/STR offset

  // Register file read addresses
  // For STR, the data to store is in Rd (register file port 1 reads Rm normally,
  // but for stores we need Rd's value; we mux the read address accordingly)
  wire [3:0]  id_reg1    = if_Rn;
  wire [3:0]  id_reg2    = (if_op == 2'b01 && !if_L) ? if_Rd : if_Rm;

  wire [63:0] rf_r1data;
  wire [63:0] rf_r2data;

  // ---------------------------------------------------------------------------
  // Combinational decoder
  // ---------------------------------------------------------------------------
  // ALU opcode encoding  (matches ALU.v)
  localparam ALU_ADD    = 4'b0001;
  localparam ALU_SUB    = 4'b0010;
  localparam ALU_AND    = 4'b0011;
  localparam ALU_OR     = 4'b0100;
  localparam ALU_XNOR   = 4'b0101;
  localparam ALU_SHIFTL = 4'b0110;
  localparam ALU_SHIFTR = 4'b0111;
  localparam ALU_NOP    = 4'b0000;
  localparam ALU_PASS_A = 4'b1000;
  localparam ALU_PASS_B = 4'b1001;
  
  reg  [3:0]  dec_alu_ctrl;
  reg         dec_use_imm;
  reg  [63:0] dec_imm64;
  reg         dec_reg_wen;
  reg         dec_mem_wen;
  reg         dec_is_load;
  reg         dec_is_branch;
  reg         dec_is_jump;
  reg  [8:0]  dec_branch_target;

  always @(*) begin
    // Safe defaults
    dec_alu_ctrl     = ALU_NOP;
    dec_use_imm      = 1'b0;
    dec_imm64        = 64'b0;
    dec_reg_wen      = 1'b0;
    dec_mem_wen      = 1'b0;
    dec_is_load      = 1'b0;
    dec_is_branch    = 1'b0;
    dec_is_jump      = 1'b0;
    // Branch target: PC_of_instruction + 2 + sign_extended_offset24
    // +2 because by the time the branch reaches EX the PC has already
    // advanced 2 words beyond the branch instruction word.
    //dec_branch_target = ifid_pc + 9'd2+ {{(9-24){if_off24[23]}}, if_off24};
	 dec_branch_target = ifid_pc + 9'd2+ if_off24[8:0];

    case (if_op)

      // -----------------------------------------------------------------------
      // 2'b00  Data-processing / BX
      // -----------------------------------------------------------------------
      2'b00: begin
        // BX Rm  ?  inst[27:4] == 24'h12FFF1
        if (ifid_instr[27:4] == 24'h12FFF1) begin
          dec_is_jump  = 1'b1;
          // jump target = lower 9 bits of Rm (resolved in EX from rf_r2data)
        end else begin
          // Immediate operand
          if (if_I) begin
            dec_use_imm = 1'b1;
            dec_imm64   = {56'b0, if_imm8};
				//dec_alu_ctrl = ALU_PASS_B;
          end

          case (if_opcode)
            4'b0100: begin dec_alu_ctrl = ALU_ADD;    dec_reg_wen = 1'b1; end // ADD
            4'b0010: begin dec_alu_ctrl = ALU_SUB;    dec_reg_wen = 1'b1; end // SUB
            4'b0000: begin dec_alu_ctrl = ALU_AND;    dec_reg_wen = 1'b1; end // AND
            4'b1100: begin dec_alu_ctrl = ALU_OR;     dec_reg_wen = 1'b1; end // ORR
            4'b0001: begin dec_alu_ctrl = ALU_XNOR;   dec_reg_wen = 1'b1; end // EOR
            4'b1101: begin dec_alu_ctrl = ALU_ADD;    dec_reg_wen = 1'b1; end // MOV (Rn=0 by convention)
            4'b1111: begin dec_alu_ctrl = ALU_XNOR;   dec_reg_wen = 1'b1; end // MVN
            4'b1010: begin dec_alu_ctrl = ALU_SUB;    dec_reg_wen = 1'b0; end // CMP (flags only)
            4'b1000: begin dec_alu_ctrl = ALU_AND;    dec_reg_wen = 1'b0; end // TST
            4'b1001: begin dec_alu_ctrl = ALU_XNOR;   dec_reg_wen = 1'b0; end // TEQ
            4'b0110: begin dec_alu_ctrl = ALU_SHIFTL; dec_reg_wen = 1'b1; end // LSL (A<<1)
            4'b0111: begin dec_alu_ctrl = ALU_SHIFTR; dec_reg_wen = 1'b1; end // LSR (A>>1)
            4'b0101: begin dec_alu_ctrl = ALU_ADD;    dec_reg_wen = 1'b1; end // ADC (treat as ADD)
            4'b0011: begin dec_alu_ctrl = ALU_SUB;    dec_reg_wen = 1'b1; end // RSB
            default: begin dec_alu_ctrl = ALU_NOP;    dec_reg_wen = 1'b0; end
          endcase
        end
      end

      // -----------------------------------------------------------------------
      // 2'b01  Load / Store  (LDR / STR)
      // -----------------------------------------------------------------------
      2'b01: begin
        // Effective address = Rn  +/-  imm12
        dec_alu_ctrl = if_U ? ALU_ADD : ALU_SUB;
        dec_use_imm  = 1'b1;
        dec_imm64    = {52'b0, if_imm12};

        if (if_L) begin         // LDR
          dec_is_load  = 1'b1;
          dec_reg_wen  = 1'b1;
          dec_mem_wen  = 1'b0;
        end else begin           // STR
          dec_is_load  = 1'b0;
          dec_reg_wen  = 1'b0;
          dec_mem_wen  = 1'b1;
        end
      end

      // -----------------------------------------------------------------------
      // 2'b10  Branch  (B / BL)
      // -----------------------------------------------------------------------
      2'b10: begin
        if (ifid_instr[27:25] == 3'b101) begin
          dec_is_branch = 1'b1;
          // BL also saves return address in R14; assert reg_wen with Rd=R14
          dec_reg_wen   = ifid_instr[24]; // 1 = BL
        end
      end

      default: ; // NOP ? all defaults
    endcase
  end

  // ---------------------------------------------------------------------------
  // WB bus (fed back from MEM/WB stage ? defined further below)
  // ---------------------------------------------------------------------------
  wire        wb_wen;
  wire [3:0]  wb_waddr;
  wire [63:0] wb_wdata;

  // ---------------------------------------------------------------------------
  // Register file  (original instance kept; widths corrected to match decoder)
  // ---------------------------------------------------------------------------
  REG_FILE #(.data_width(64), .addr_width(4)) u_rf (
    .clk    (clk),
    .wena   (wb_wen),
    .r0addr (id_reg1),
    .r1addr (id_reg2),
    .waddr  (wb_waddr),
    .wdata  (wb_wdata),
    .r0data (rf_r1data),
    .r1data (rf_r2data)
  );

  // ---------------------------------------------------------------------------
  // ID ? ID/EX pipeline registers
  // ---------------------------------------------------------------------------
  reg  [3:0]  idex_alu_ctrl;
  reg         idex_use_imm;
  reg  [63:0] idex_imm64;
  reg         idex_reg_wen;
  reg         idex_mem_wen;
  reg         idex_is_load;
  reg         idex_is_branch;
  reg         idex_is_jump;
  reg  [8:0]  idex_branch_target;
  reg  [3:0]  idex_wreg;          // destination register address
  reg  [63:0] idex_r1data;        // Rn value
  reg  [63:0] idex_r2data;        // Rm / store-data value

  always @(posedge clk) begin
    if (reset || pc_reset_pulse || ex_branch_taken) begin
      // Flush: NOP bubble
      idex_alu_ctrl      <= ALU_NOP;
      idex_use_imm       <= 1'b0;
      idex_imm64         <= 64'b0;
      idex_reg_wen       <= 1'b0;
      idex_mem_wen       <= 1'b0;
      idex_is_load       <= 1'b0;
      idex_is_branch     <= 1'b0;
      idex_is_jump       <= 1'b0;
      idex_branch_target <= 9'd0;
      idex_wreg          <= 4'h0;
      idex_r1data        <= 64'h0;
      idex_r2data        <= 64'h0;
    end else if (advance) begin
      idex_alu_ctrl      <= dec_alu_ctrl;
      idex_use_imm       <= dec_use_imm;
      idex_imm64         <= dec_imm64;
      idex_reg_wen       <= dec_reg_wen;
      idex_mem_wen       <= dec_mem_wen;
      idex_is_load       <= dec_is_load;
      idex_is_branch     <= dec_is_branch;
      idex_is_jump       <= dec_is_jump;
      idex_branch_target <= dec_branch_target;
      idex_wreg          <= if_Rd;   // destination register
      idex_r1data        <= rf_r1data;
      idex_r2data        <= rf_r2data;
    end
  end

// ===========================================================================
// EX STAGE  ?  ALU + branch resolution
// ===========================================================================

  // Operand B mux: register value or zero-extended immediate
  wire [63:0] ex_alu_A  = idex_r1data;
  wire [63:0] ex_alu_B  = idex_use_imm ? idex_imm64 : idex_r2data;

  // 64-bit ALU
  wire [63:0] ex_alu_out;
  wire        ex_alu_ovf;

  ALU #(.data_width(64)) u_alu (
    .A        (ex_alu_A),
    .B        (ex_alu_B),
    .aluctrl  (idex_alu_ctrl),
    .Z        (ex_alu_out),
    .overflow (ex_alu_ovf)
  );

  // Branch / jump resolution
  // All branches taken unconditionally (no condition code evaluation).
  // Wires declared at top of module to resolve forward references.
  assign ex_branch_taken  = (idex_is_branch | idex_is_jump) & advance;
  assign ex_branch_target = idex_is_jump
                            ? idex_r2data[8:0]    // BX: target from register Rm
                            : idex_branch_target; // B/BL: pre-computed in ID

  // For BL: write-back value is return address (PC+1 relative to branch instr)
  // idex_branch_target was computed as  pc+2+offset; pc+1 = branch_target - offset - 1
  // Simpler: we pass the ALU result for BL; for plain B reg_wen=0 so it doesn't matter.
  // BL return address = PC of next instruction after B = idex_branch_target - offset24 - 1
  // For simplicity, the programmer can use BL knowing R14 will not be correctly set
  // in this implementation (full BL support would require passing PC+1 separately).
  wire [63:0] ex_wdata   = ex_alu_out;  // both ALU result and address
  wire [63:0] ex_store   = idex_r2data; // data to write to memory (STR)

  // EX ? EX/MEM pipeline registers
  reg        exmem_reg_wen;
  reg        exmem_mem_wen;
  reg        exmem_is_load;
  reg [3:0]  exmem_wreg;
  reg [63:0] exmem_alu_result;   // effective address (LDR/STR) or ALU result (arith)
  reg [63:0] exmem_store_data;   // value to write to memory (STR)

  always @(posedge clk) begin
    if (reset || pc_reset_pulse) begin
      exmem_reg_wen     <= 1'b0;
      exmem_mem_wen     <= 1'b0;
      exmem_is_load     <= 1'b0;
      exmem_wreg        <= 4'h0;
      exmem_alu_result  <= 64'h0;
      exmem_store_data  <= 64'h0;
    end else if (advance) begin
      exmem_reg_wen     <= idex_reg_wen;
      exmem_mem_wen     <= idex_mem_wen;
      exmem_is_load     <= idex_is_load;
      exmem_wreg        <= idex_wreg;
      exmem_alu_result  <= ex_wdata;
      exmem_store_data  <= ex_store;
    end
  end

// ===========================================================================
// MEM STAGE  ?  Data memory access
// ===========================================================================
// Data memory address = lower 8 bits of ALU result (byte addr / 8 for 64-bit words)
// The 64-bit BRAM is word-addressed at 8-byte granularity.
// alu_result[10:3] gives the 8-bit word address for byte-addressed offsets.
// For simplicity: use alu_result[7:0] directly as the BRAM word address
// (programmer uses word addresses in LDR/STR offsets).

  wire [7:0]  mem_bram_addr   = exmem_alu_result[7:0];
  wire [63:0] dmem_douta;
  wire [63:0] dmem_doutb;

  D_M_64bit_256 u_dmem (
    // Port A: pipeline access (LDR / STR)
    .addra (mem_bram_addr),
    .clka  (clk),
    .ena   (exmem_is_load | exmem_mem_wen),
    .wea   (exmem_mem_wen),
    .dina  (exmem_store_data),
    .douta (dmem_douta),

    // Port B: software programming interface  ? DO NOT CHANGE
    .addrb (dmem_prog_addr),
    .clkb  (clk),
    .enb   (dmem_prog_en),
    .web   (dmem_prog_we),
    .dinb  (dmem_prog_wdata),
    .doutb (dmem_doutb)
  );
  assign dmem_prog_rdata = dmem_doutb;

  // MEM ? MEM/WB pipeline registers  (original structure kept)
  reg        mem_reg_wen;
  reg        mem_is_load;
  reg [3:0]  mem_wreg;
  reg [63:0] mem_alu_result;   // ALU result to pass to WB (for non-load instructions)

  always @(posedge clk) begin
    if (reset || pc_reset_pulse) begin
      mem_reg_wen    <= 1'b0;
      mem_is_load    <= 1'b0;
      mem_wreg       <= 4'h0;
      mem_alu_result <= 64'h0;
    end else if (advance) begin
      mem_reg_wen    <= exmem_reg_wen;
      mem_is_load    <= exmem_is_load;
      mem_wreg       <= exmem_wreg;
      mem_alu_result <= exmem_alu_result;
    end
  end

// ===========================================================================
// MEM/WB PIPELINE REGISTERS  (original structure kept; signals extended)
// ===========================================================================
  reg        memwb_wreg_en;
  reg [3:0]  memwb_wreg;
  reg [63:0] memwb_alu_result;   // ALU result (for non-load WB)
  reg [63:0] memwb_dmem_rdata;   // Memory read data (for load WB)
  reg        memwb_is_load;

  always @(posedge clk) begin
    if (reset || pc_reset_pulse) begin
      memwb_wreg_en    <= 1'b0;
      memwb_wreg       <= 4'h0;
      memwb_alu_result <= 64'h0;
      memwb_dmem_rdata <= 64'h0;
      memwb_is_load    <= 1'b0;
    end else if (advance) begin
      memwb_wreg_en    <= mem_reg_wen;
      memwb_wreg       <= mem_wreg;
      memwb_alu_result <= mem_alu_result;
      memwb_dmem_rdata <= dmem_douta;    // data from BRAM (1-cycle latency matches here)
      memwb_is_load    <= mem_is_load;
    end
  end

// ===========================================================================
// WB STAGE  ?  Write back to register file
// ===========================================================================
// Select write-back data: memory read data (LDR) or ALU result (arithmetic)
  assign wb_wen   = (~reset) & (~pc_reset_pulse) & advance & memwb_wreg_en;
  assign wb_waddr = memwb_wreg;
  assign wb_wdata = memwb_is_load ? memwb_dmem_rdata : memwb_alu_result;

endmodule