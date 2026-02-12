module stage_MEM_WB #(data_width = 32, reg_addr = 3) (
  input clk, reset, enable,
  input WRegEn_in,
  input [reg_addr-1 : 0] wReg1_in,
  input [data_width-1 : 0] wdata_in,
  output reg WRegEn_out,
  output reg [reg_addr-1 : 0] wReg1_out,
  output reg [data_width-1 : 0] wdata_out
);
    
  always @ (posedge clk or posedge reset) begin
    if (reset) begin
     	WRegEn_out <= 1'b0;
    	wdata_out <= {data_width{1'bx}};
       	wReg1_out <={reg_addr{1'bx}};
    end
    else begin
      if (enable) begin
        WRegEn_out <= WRegEn_in;
        wdata_out <= wdata_in;
        wReg1_out <= wReg1_in;
      end
    end
  end
endmodule
