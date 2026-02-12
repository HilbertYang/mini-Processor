module stage_ID_EX #(data_width = 32, reg_addr = 3) (
  input clk, reset, enable,
  input WRegEn_in, WMemEn_in,
  input [data_width-1:0] r1_data_in, r2_data_in,
  input [reg_addr-1 : 0] wReg1_in,
  output reg WRegEn_out, WMemEn_out,
  output reg [data_width-1:0] r1_data_out, r2_data_out,
  output reg [reg_addr-1 : 0] wReg1_out
);
    
  always @ (posedge clk or posedge reset) begin
    if (reset) begin
     	WRegEn_out <= 1'b0;
     	WMemEn_out <= 1'b0;
    	r1_data_out <= {data_width{1'bx}};
    	r2_data_out <= {data_width{1'bx}};
    	wReg1_out <= {reg_addr{1'bx}};
    end
    else begin
      if (enable) begin
        WRegEn_out <= WRegEn_in;
        WMemEn_out <= WMemEn_in;
        r1_data_out <= r1_data_in;
        r2_data_out <= r2_data_in;
        wReg1_out <= wReg1_in;
      end
    end
  end
endmodule
