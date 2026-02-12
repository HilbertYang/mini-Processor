
module stage_ID #(data_width = 32, reg_addr = 3) (
  	input [31:0] inst,
  	input clk, WRegEn_in,
  	input [reg_addr-1 : 0] wReg1,
  	input [data_width-1 : 0] wdata,
  	output WRegEn_out, WMemEn,
  	output [data_width-1 : 0] r1_data_out, r2_data_out,
  	output [reg_addr-1 : 0] wReg1_out,
  	output [3:0] aluctrl,
	output isBranch, isJump, isMemInst);
  
  REG_FILE #(.data_width(data_width), .addr_width(reg_addr)) ID_REG_FILE (
    .clk(clk), .wena(WRegEn_in),
    .r0addr(), .r1addr(), .waddr(),
    .wdata(wReg1),
    .r0data(r1_data_out), .r1data(r2_data_out));
  
endmodule
