
// Warning: This is a AI generated testbech for the pipline,
// No garantee it is correct
// ------------------Haobo Yang------------------
//

`timescale 1ns/1ps

module tb_pipeline;

  // -----------------------
  // DUT inputs
  // -----------------------
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

  // DUT outputs
  wire [8:0]  pc_dbg;
  wire [31:0] if_instr_dbg;

  // -----------------------
  // Instantiate DUT
  // -----------------------
  pipeline dut (
    .clk(clk),
    .reset(reset),

    .run(run),
    .step(step),
    .pc_reset_pulse(pc_reset_pulse),

    .imem_prog_we(imem_prog_we),
    .imem_prog_addr(imem_prog_addr),
    .imem_prog_wdata(imem_prog_wdata),

    .dmem_prog_en(dmem_prog_en),
    .dmem_prog_we(dmem_prog_we),
    .dmem_prog_addr(dmem_prog_addr),
    .dmem_prog_wdata(dmem_prog_wdata),
    .dmem_prog_rdata(dmem_prog_rdata),

    .pc_dbg(pc_dbg),
    .if_instr_dbg(if_instr_dbg)
  );

  // -----------------------
  // Clock  
  // -----------------------
  localparam CLK_PERIOD = 10;//10ns -> 100MHz
  initial clk = 1'b0;
  always #(CLK_PERIOD/2) clk = ~clk;

  // -----------------------
  // Tasks: program memories
  // -----------------------

  // Write one 32-bit word into I-mem via programming port
  task program_imem_word;
    input [8:0]  addr;
    input [31:0] data;
    begin
      // program phase: keep CPU not running
      run  = 1'b0;
      step = 1'b0;

      imem_prog_addr  = addr;
      imem_prog_wdata = data;
      imem_prog_we    = 1'b1;

      @(posedge clk);
      #1;
      imem_prog_we    = 1'b0;

      // optional gap cycle
      @(posedge clk);
      #1;
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
      dmem_prog_we    = 1'b0;
      dmem_prog_en    = 1'b0;

      // optional gap cycle
      @(posedge clk);
      #1;
    end
  endtask

  // Read one 64-bit word from D-mem Port B
  task read_dmem_word;
    input  [7:0]  addr;
    output [63:0] data;
    begin
      run  = 1'b0;
      step = 1'b0;

      dmem_prog_addr = addr;
      dmem_prog_en   = 1'b1;
      dmem_prog_we   = 1'b0;
      dmem_prog_wdata= 64'h0;

      @(posedge clk);
      #1;
      data = dmem_prog_rdata;

      dmem_prog_en   = 1'b0;

      // optional gap cycle
      @(posedge clk);
      #1;
    end
  endtask

  // pulse PC reset
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

  // -----------------------
  // Instruction encoding helper
  // [31] WMemEn, [30] WRegEn,
  // [28:27] Reg1 (addr source, low 2 bits),
  // [25:24] Reg2 (store data source, low 2 bits),
  // [22:21] WReg (dest, low 2 bits)
  // -----------------------
  function [31:0] make_instr;
    input wmem_en;
    input wreg_en;
    input [1:0] reg1;
    input [1:0] reg2;
    input [1:0] wreg;
    begin
      make_instr = 32'h0;
      make_instr[31]    = wmem_en;
      make_instr[30]    = wreg_en;
      make_instr[28:27] = reg1;
      make_instr[25:24] = reg2;
      make_instr[22:21] = wreg;
    end
  endfunction

  // -----------------------
  // Monitor writeback + basic debug
  // -----------------------
  always @(posedge clk) begin
    if (!reset) begin
      if (dut.wb_wen) begin
        $display("[%0t] WB: wen=1 waddr=%0d wdata=0x%016h  (pc=%0d ifid_instr=0x%08h)",
                 $time, dut.wb_waddr, dut.wb_wdata, pc_dbg, if_instr_dbg);
      end
    end
  end

  // -----------------------
  // Main test 
  // -----------------------
  reg [63:0] rd0, rd4_before, rd4_after;
  initial begin
    // defaults
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

    $dumpfile("tb_pipeline_doc.vcd");
    $dumpvars(0, tb_pipeline_doc);

    // reset a few cycles
    repeat (3) @(posedge clk);
    #1 reset = 1'b0;
    @(posedge clk);
    #1;

    // -----
    // 1) Program D-mem like document example:
    // D-mem[0] = 4
    // D-mem[4] = 100
    // -----


    $display("== Program D-mem[0]=4, D-mem[4]=100 ==");
    program_dmem_word(8'd0, 64'd4);
    program_dmem_word(8'd4, 64'd100);

    // Read back to confirm
    read_dmem_word(8'd0, rd0);
    read_dmem_word(8'd4, rd4_before);
    $display("[%0t] Readback: D[0]=%0d (0x%h), D[4]=%0d (0x%h)",
             $time, rd0, rd0, rd4_before, rd4_before);

    if (rd0 !== 64'd4) begin
      $display("ERROR: D[0] not 4!");
      $stop;
    end
    if (rd4_before !== 64'd100) begin
      $display("ERROR: D[4] not 100!");
      $stop;
    end


    // -----
    // 2) Program I-mem program exactly like doc intent:
    //
    // Addr0: Load D-mem[Reg0=0] -> Reg2
    // Addr1: Load D-mem[Reg0=0] -> Reg3
    // Addr2: NOP
    // Addr3: NOP
    // Addr4: NOP
    // Addr5: Store Reg3 -> D-mem[Reg2]
    //
    // Register mapping (your design, 2-bit):
    // Reg0=00, Reg2=10, Reg3=11
    // -----
    $display("== Program I-mem (doc sequence) ==");

    // load to Reg2 (10)
    program_imem_word(9'd0, make_instr2(1'b0, 1'b1, 2'b00, 2'b00, 2'b10));

    // load to Reg3 (11)
    program_imem_word(9'd1, make_instr2(1'b0, 1'b1, 2'b00, 2'b00, 2'b11));

    // NOPs
    program_imem_word(9'd2, 32'h0);
    program_imem_word(9'd3, 32'h0);
    program_imem_word(9'd4, 32'h0);

    // store: address comes from Reg2 (10), data comes from Reg3 (11)
    // WMemEn=1, WRegEn=0
    program_imem_word(9'd5, make_instr2(1'b1, 1'b0, 2'b10, 2'b11, 2'b00));

    // reset PC so it starts at 0
    $display("== Pulse PC reset ==");
    pulse_pc_reset();




    // -----
    // 3) Run CPU enough cycles to execute through store
    // -----
    $display("== Run CPU ==");
    run = 1'b1;
    repeat (20) @(posedge clk);
    #1;
    run = 1'b0;




    // -----
    // 4) Read back D-mem[4], should become 4 after store
    // -----
    $display("== Check result: D-mem[4] should be 4 ==");
    read_dmem_word(8'd4, rd4_after);
    $display("[%0t] After run: D[4]=%0d (0x%h)", $time, rd4_after, rd4_after);

    if (rd4_after !== 64'd4) begin
      $display("ERROR: Expected D[4]=4 after store, got %0d (0x%h)", rd4_after, rd4_after);
      $stop;
    end

    $display("PASS:Program worked! D[4] changed 100 -> 4.");
    $finish;
  end


















  // // -----------------------
  // // Test sequence
  // // -----------------------
  // integer i;
  // reg [63:0] rd;

  // initial begin
  //   // defaults
  //   reset          = 1'b1;
  //   run            = 1'b0;
  //   step           = 1'b0;
  //   pc_reset_pulse = 1'b0;

  //   imem_prog_we   = 1'b0;
  //   imem_prog_addr = 9'd0;
  //   imem_prog_wdata= 32'h0;

  //   dmem_prog_en   = 1'b0;
  //   dmem_prog_we   = 1'b0;
  //   dmem_prog_addr = 8'd0;
  //   dmem_prog_wdata= 64'h0;

  //   // waveform
  //   $dumpfile("tb_pipeline.vcd");
  //   $dumpvars(0, tb_pipeline);

  //   // hold reset a few cycles
  //   repeat (3) @(posedge clk);
  //   #1;
  //   reset = 1'b0;
  //   @(posedge clk);
  //   #1;

  //   // -----------------------
  //   // Program D-mem[0] with known value, then read back
  //   // -----------------------
  //   $display("== Program D-mem[0] ==");
  //   program_dmem_word(8'h00, 64'hDEAD_BEEF_CAFE_1234);

  //   $display("== Readback D-mem[0] ==");
  //   read_dmem_word(8'h00, rd);
  //   $display("[%0t] D-mem[0] readback = 0x%016h", $time, rd);
  //   if (rd !== 64'hDEAD_BEEF_CAFE_1234) begin
  //     $display("ERROR: D-mem readback mismatch!");
  //     $stop;
  //   end

  //   // -----------------------
  //   // Program I-mem:
  //   // Put a load-like instruction that reads D-mem[Reg1] and writes to WReg
  //   // We'll use Reg1=00 so address = reg0[7:0]. Usually reg0 resets to 0 -> reads D-mem[0]
  //   // WRegEn=1, WMemEn=0, WReg=01
  //   // INSTRUCTION FORMAT
  //   // [31] WMemEn, [30] WRegEn,
  //   // [28:27] Reg1 (addr source, low 2 bits),
  //   // [25:24] Reg2 (store data source, low 2 bits),
  //   // [22:21] WReg (dest, low 2 bits)
  //   // -----------------------
  //   $display("== Program I-mem ==");
  //   program_imem_word(9'd0, make_instr(1'b0, 1'b1, 2'b00, 2'b00, 2'b01)); // LOAD -> write R1
  //   program_imem_word(9'd1, 32'h0); // NOP
  //   program_imem_word(9'd2, 32'h0); // NOP
  //   program_imem_word(9'd3, 32'h0); // NOP
  //   program_imem_word(9'd4, 32'h0); // NOP
  //   program_imem_word(9'd5, 32'h0); // NOP
  //   program_imem_word(9'd6, ); // STORE -> write D-mem[R1] = R1 (self copy)

  //   // reset PC to 0 before running
  //   $display("== Pulse PC reset ==");
  //   pulse_pc_reset();

  //   // -----------------------
  //   // Run a bit: expect WB to happen after pipeline latency
  //   // -----------------------
  //   $display("== Run CPU ==");
  //   run = 1'b1;
  //   // run enough cycles to see the load reach WB
  //   repeat (12) @(posedge clk);
  //   #1;
  //   run = 1'b0;

  //   // Done
  //   $display("== Done. Check WB printout above and VCD. ==");
  //   repeat (5) @(posedge clk);
  //   $finish;
  // end

endmodule
