module stage_MEM #(data_width = 32, reg_addr = 3) (
  input WRegEn_in, WMemEn,
  input [reg_addr-1 : 0] wReg1_in,
  input [data_width-1 : 0] mem_addr,
  input [data_width-1 : 0] wdata_in,
  input clk, isMemInst,
  output WRegEn_out,
  output [reg_addr-1 : 0] wReg1_out,
  output [data_width-1 : 0] wdata_out
	);
  wire [data_width-1 : 0] mem_out;
  assign wReg1_out = wReg1_in;
  assign wdata_out = (isMemInst & ~(WMemEn))?  mem_out : wdata_in;
  
  MEM #(.data_width(data_width), .addr_width(8)) data_mem (
    .addr(mem_addr),
    .din(din),
    .clk(clk), .wen(WMemEn),
    .dout(mem_out));
  
endmodule
