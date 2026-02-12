
`timescale 1ns/1ps
module tb_reg_file;
  parameter DATA_W = 32;
  parameter ADDR_W = 5;
  localparam DEPTH = (2 ** ADDR_W);

  class genData;
  	rand bit [DATA_W-1:0] wdata;
  	rand bit [ADDR_W:0] r0addr, r1addr, waddr;
  endclass
  
  reg clk;
  reg wena;
  reg [ADDR_W-1:0] r0addr, r1addr, waddr;
  reg [DATA_W-1:0] wdata;
  wire [DATA_W-1:0] r0data, r1data;


  REG_FILE #(
    .data_width(DATA_W),
    .addr_width(ADDR_W)
  ) uut (
    .clk(clk),
    .wena(wena),
    .r0addr(r0addr),
    .r1addr(r1addr),
    .waddr(waddr),
    .wdata(wdata),
    .r0data(r0data),
    .r1data(r1data)
  );
  
  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end

  genData testData = new();
  
  bit [DATA_W-1:0] reg_data [DEPTH];
  
  initial begin
    
    wena <= 1'b1;
    #20;
    for (integer i = 0 ; i < DEPTH ; i = i + 1) begin
      wdata <= {DATA_W{1'b0}};
      #10;
      reg_data[i] = {DATA_W{1'b0}};
    end
    wena <= 1'b0;
    #20;
    
    for (integer i = 0 ; i < 50 ; i = i + 1) begin
    	testData.randomize();
      	wena <= 1'b1;
    	waddr = testData.waddr;
    	wdata = testData.wdata;
      	#10
      	wena <= 1'b0;
      	reg_data[waddr] = wdata;
      
      	r0addr = testData.r0addr;
    	r1addr = testData.r1addr;
      
     	if (r0data != reg_data[r0addr])
        	$display("error");
      	if (r1data != reg_data[r1addr])
        	$display("error");
      	#10;
      
      	//$display("mem: %p", reg_data); 
    end
    
    #10;
    
  end
  
endmodule
