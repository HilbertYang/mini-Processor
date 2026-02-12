module MEM #(parameter data_width = 32, addr_width = 8) (
  input [addr_width-1:0] addr,
  input [data_width-1:0] din,
  input clk, wen,
  output [data_width-1:0] dout
	);
  reg [data_width-1:0] mem [addr_width];
  assign dout = mem[addr];
  always @ (posedge clk) begin
    if (wen)
      mem[addr] <= din;
  end
  
endmodule
