module stage_IF #(data_width = 32, imem_addr_width = 8) (
  input reset, clk, pc_write,
  input [imem_addr_width-1:0] pc_in,
  output [31:0] inst
);
  
  reg [imem_addr_width-1:0] pc;
  
  MEM #(.data_width(32), .addr_width(imem_addr_width)) data_mem (
    .addr(pc),
    .din(),
    .clk(clk), .wen(1'b0),
    .dout(inst));
  
  always @ (posedge clk) begin
    if (reset) begin
      pc <= {32{1'b0}};
    end
    else begin
    	pc <= pc + 4;
    	if (pc_write)
      		pc <= pc_in;
    end
  end
  
endmodule
