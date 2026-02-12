module stage_IF_ID (
  input clk, reset, enable,
  input [31:0] INST_IN,
  output reg [31:0] INST_OUT);
    
  always @ (posedge clk or posedge reset) begin
    if (reset) 
      INST_OUT <= {32{1'b0}};
    else begin
      if (enable) begin
        INST_OUT <= INST_IN;
      end
    end
  end
endmodule
