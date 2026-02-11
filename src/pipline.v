`timescale 1ns/1ps
module pipeline (
  input  wire        clk,
  input  wire        reset,

  input  wire        run,           
  input  wire        step,          
  input  wire        pc_reset_pulse, // Reset PC to 0

  //I-mem programming interface (from reg stage)
  input  wire        imem_prog_we,
  input  wire [8:0]  imem_prog_addr,
  input  wire [31:0] imem_prog_wdata,

  //NEW: D-mem programming interface (from reg stage, use Port B)
  input  wire        dmem_prog_en,
  input  wire        dmem_prog_we,
  input  wire [7:0]  dmem_prog_addr,
  input  wire [63:0] dmem_prog_wdata,
  output wire [63:0] dmem_prog_rdata,


  output wire [8:0]  pc_dbg,
  output wire [31:0] if_instr_dbg
);
  
// ---------
// control signals  step control signals
// ---------

  reg step_d;
  
  always @(posedge clk) begin
    if (reset || pc_reset_pulse) begin
        step_d <= 1'b0;
    end else begin       
        step_d <= step; // Store the previous value of step
    end
  end

  wire step_pulse = step & ~step_d;       // edge detect
  wire advance    = run | step_pulse; 

// ---------
// IF: PC and I-mem
// ---------

  reg  [8:0] pc;
  assign pc_dbg = pc;

  // I-mem instance with programming interface
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


  // // I-mem instance
  // wire [8:0]  imem_addr;
  // wire [31:0] imem_dout;
  // assign imem_addr = pc;  // combinationally feed PC to I-mem addr (no need to register)
  // I_M_32bit_512depth u_imem (
  //   .addr(imem_addr),
  //   .clk (clk),
  //   .din (32'h0),     // no writes to I-mem, use software interface to porgram
  //   .dout(imem_dout),
  //   .en  (1'b1),
  //   .we  (1'b0)
  // );

  //pc update
  always @(posedge clk) begin
    if (reset) begin
      pc <= 9'd0;
    end else if (pc_reset_pulse) begin
      pc <= 9'd0;
    end else if (advance) begin
      pc <= pc + 9'd1;
    end
  end


  // // feed PC to I-mem address,this is sequential logic
  // always @(posedge clk) begin
  //   if (reset) begin
  //     imem_addr <= 9'd0;
  //   end else if (pc_reset_pulse) begin
  //     imem_addr <= 9'd0;
  //   end else if (advance) begin
  //     imem_addr <= pc;
  //   end
  // end


  // IF -> ID
  reg  [31:0] ifid_instr;
  assign if_instr_dbg = ifid_instr;//output for debug

  always @(posedge clk) begin
    if (reset) begin
      ifid_instr <= 32'h0;
    end else if (pc_reset_pulse) begin
      ifid_instr <= 32'h0;
    end else if (advance) begin
      ifid_instr <= imem_dout;
    end
  end

  // ------------------
  // ID: decode AND regfile read
  // INSTRUCTION FORMAT (32 bits):
  // [31] WMemEn, [30] WRegEn, [29:27] Reg1, [26:24] Reg2, [23:21] WReg1, rest unused
  // ------------------ 
  wire        id_wmem_en = ifid_instr[31];
  wire        id_wreg_en = ifid_instr[30];
  wire [1:0]  id_reg1    = ifid_instr[28:27]; // low 2 bits of [29:27]
  wire [1:0]  id_reg2    = ifid_instr[25:24]; // low 2 bits of [26:24]
  wire [1:0]  id_wreg    = ifid_instr[22:21]; // low 2 bits of [23:21]
  wire [63:0] rf_r0data;
  wire [63:0] rf_r1data;

  // WB signals, defined as wire later, assigned from MEM/WB pipeline register
  // reg        wb_wen;
  // reg [1:0]  wb_waddr;
  // reg [63:0] wb_wdata;
  
  // WB signals (directly from MEM/WB, gated by advance)
  reg        memwb_wreg_en;
  reg [1:0]  memwb_wreg;
  reg [63:0] memwb_load_data;

  wire        wb_wen;
  wire [1:0]  wb_waddr;
  wire [63:0] wb_wdata;

  // assign wb_wen   = advance & memwb_wreg_en;
  assign wb_wen = (~reset) & (~pc_reset_pulse) & advance & memwb_wreg_en;
  assign wb_waddr = memwb_wreg;
  assign wb_wdata = memwb_load_data;


  register_file u_rf (
    .clk   (clk),
    .reset (reset),
    .r0addr(id_reg1),
    .r1addr(id_reg2),
    .waddr0(wb_waddr[0]),
    .waddr1(wb_waddr[1]),
    .wdata (wb_wdata),
    .wen   (wb_wen),
    .r0data(rf_r0data),
    .r1data(rf_r1data)
  ); 

  // ID->EX 
  reg        idex_wmem_en;
  reg        idex_wreg_en;
  reg [1:0]  idex_wreg;
  reg [63:0] idex_r1out;
  reg [63:0] idex_r2out;

  always @(posedge clk) begin
    if (reset) begin
      idex_wmem_en <= 1'b0;
      idex_wreg_en <= 1'b0;
      idex_wreg    <= 2'b00;
      idex_r1out   <= 64'h0;
      idex_r2out   <= 64'h0;
    end else if (pc_reset_pulse) begin
      idex_wmem_en <= 1'b0;
      idex_wreg_en <= 1'b0;
      idex_wreg    <= 2'b00;
      idex_r1out   <= 64'h0;
      idex_r2out   <= 64'h0;
    end else if (advance) begin
      idex_wmem_en <= id_wmem_en;
      idex_wreg_en <= id_wreg_en;
      idex_wreg    <= id_wreg;
      idex_r1out   <= rf_r0data; 
      idex_r2out   <= rf_r1data; 
    end
  end

  // -----------------------------
  // EX: form D-mem address AND store data
  // -----------------------------
  wire [7:0] ex_dmem_addr  = idex_r1out[7:0];
  wire [63:0] ex_store_data = idex_r2out;

  // EX->MEM pipeline registers
  reg        exmem_wmem_en;
  reg        exmem_wreg_en;
  reg [1:0]  exmem_wreg;
  reg [7:0]  exmem_addr;
  reg [63:0] exmem_store_data;

  always @(posedge clk) begin
    if (reset) begin
      exmem_wmem_en     <= 1'b0;
      exmem_wreg_en     <= 1'b0;
      exmem_wreg        <= 2'b00;
      exmem_addr        <= 8'h00;
      exmem_store_data  <= 64'h0;
    end else if (pc_reset_pulse) begin
      exmem_wmem_en     <= 1'b0;
      exmem_wreg_en     <= 1'b0;
      exmem_wreg        <= 2'b00;
      exmem_addr        <= 8'h00;
      exmem_store_data  <= 64'h0;
    end else if (advance) begin
      exmem_wmem_en     <= idex_wmem_en;
      exmem_wreg_en     <= idex_wreg_en;
      exmem_wreg        <= idex_wreg;
      exmem_addr        <= ex_dmem_addr;
      exmem_store_data  <= ex_store_data;
    end
  end

  // -----------------------------------------
  // MEM: D-mem access (use Port A for pipeline)
  // if exmem_wmem_en is set, write to mem;
  // if exmem_wreg_en is set, do read;
  // -----------------------------------------
  
  // wire [63:0] dmem_douta;

  // D_M_64bit_256 u_dmem (
  //   .addra(exmem_addr),
  //   .addrb(8'h00),
  //   .clka (clk),
  //   .clkb (clk),
  //   .dina (exmem_store_data),
  //   .dinb (64'h0),
  //   .douta(dmem_douta),
  //   .doutb(),
  //   .ena  (1'b1),
  //   .enb  (1'b0),
  //   .wea  (exmem_wmem_en),
  //   .web  (1'b0)
  // ); 

  wire [63:0] dmem_douta;
  wire [63:0] dmem_doutb;

  D_M_64bit_256 u_dmem (
    // Port A: pipeline
    .addra(exmem_addr),
    .clka (clk),
    .ena  (1'b1),
    .wea  (exmem_wmem_en),
    .dina (exmem_store_data),
    .douta(dmem_douta),

    // Port B: programming / verify
    .addrb(dmem_prog_addr),
    .clkb (clk),
    .enb  (dmem_prog_en),
    .web  (dmem_prog_we),
    .dinb (dmem_prog_wdata),
    .doutb(dmem_doutb)
  );

  assign dmem_prog_rdata = dmem_doutb;

  // MEM->WB
  // MEM/WB pipeline registers are being defined at ID stage, and updated here in MEM stage.  
  // reg        memwb_wreg_en;
  // reg [1:0]  memwb_wreg;
  // reg [63:0] memwb_load_data;


  always @(posedge clk) begin
    if (reset) begin
      memwb_wreg_en   <= 1'b0;
      memwb_wreg      <= 2'b00;
      memwb_load_data <= 64'h0;
    end else if (pc_reset_pulse) begin
      memwb_wreg_en   <= 1'b0;
      memwb_wreg      <= 2'b00;
      memwb_load_data <= 64'h0;
    end else if (advance) begin
      memwb_wreg_en   <= exmem_wreg_en;
      memwb_wreg      <= exmem_wreg;
      memwb_load_data <= dmem_douta; 
    end
  end

  
  // ---------------------------
  // WB: writeback to regfile
  // We write when memwb_wreg_en=1.
  // ---------------------------

  //   always @(posedge clk) begin
  //   if (reset) begin
  //     wb_wen   <= 1'b0;
  //     wb_waddr <= 2'b00;
  //     wb_wdata <= 64'h0;
  //   end else if (pc_reset_pulse) begin
  //     wb_wen   <= 1'b0;
  //     wb_waddr <= 2'b00;
  //     wb_wdata <= 64'h0;
  //   end else if (advance) begin
  //     wb_wen   <= memwb_wreg_en;
  //     wb_waddr <= memwb_wreg;
  //     wb_wdata <= memwb_load_data;
  //   end else begin
  //     // no writeback if stall (advance=0)
  //     wb_wen <= 1'b0;
  //   end
  // end



endmodule