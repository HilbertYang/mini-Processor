module stage_EX #(data_width = 32, reg_addr = 3, imem_addr_width = 8) (
  	input [data_width-1 : 0] r1_data, r2_data,
  	input [reg_addr-1 : 0] wReg1_in,
  	input [3:0] aluctrl,
  	input WRegEn_in, WMemEn_in,
  	output [reg_addr-1 : 0] wReg1_out,
  	output [data_width-1 : 0] mem_addr,
  	output [data_width-1 : 0] wdata,
  	output WRegEn_out, WMemEn_out,pc_write,
  	output [imem_addr_width-1:0] pc);

  assign WRegEn_out = WRegEn_in;
  assign WMemEn_out = WMemEn_in;
  wire [data_width-1:0] alu_out;
  wire ovf, isAluOutZero, greater, less, greater_equal, less_equal, equal;
  assign isAluOutZero = ~(|(alu_out));
  assign equal = isAluOutZero;
  assign less = ovf;
  assign greater = ~(less || equal);
  assign greater_equal = greater || equal;
  assign less_equal = less || equal;
  assign less = ovf;
  
  ALU #(.data_width(data_width)) EX_ALU(
    .A(r1_data), .B(r2_data),
    .aluctrl(aluctrl),
    .Z(alu_out),
    .overflow(ovf)
  );
  
endmodule
