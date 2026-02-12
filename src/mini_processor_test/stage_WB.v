
module stage_WB #(data_width = 32, reg_addr = 3) (
  input WRegEn_in,
  input [reg_addr-1 : 0] wReg1_in,
  input [data_width-1 : 0] wdata_in,
  output WRegEn_out,
  output [reg_addr-1 : 0] wReg1_out,
  output [data_width-1 : 0] wdata_out
);
  assign WRegEn_out = WRegEn_in;
  assign wReg1_out = wReg1_in;
  assign wdata_out = wdata_in;

 endmodule
