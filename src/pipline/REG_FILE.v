module REG_FILE #(
    parameter data_width = 64, 
    parameter addr_width = 4 
)(
    input clk, wena,
    input [addr_width-1:0] r0addr, r1addr, waddr, 
    input [data_width-1:0] wdata,
    output [data_width-1:0] r0data, r1data
);

    reg [data_width-1:0] regFile [0:(1 << addr_width)-1];

    // Synchronous Write: Added condition (waddr != 0) 
    // This prevents the write operation from ever touching regFile[0]
    always @(posedge clk) begin
        if (wena && (waddr != 0))
            regFile[waddr] <= wdata;
    end

    // Asynchronous Read: Ternary operator returns 0 if address is 0
    // This is "Hardwiring" the zero at the output mux level
    assign r0data = (r0addr == 0) ? {data_width{1'b0}} : regFile[r0addr];
    assign r1data = (r1addr == 0) ? {data_width{1'b0}} : regFile[r1addr];

endmodule
