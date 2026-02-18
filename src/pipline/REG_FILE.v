module REG_FILE #(
    parameter data_width = 64, 
    parameter addr_width = 4    // Default: 4 registers (2^2)
)(
    input clk, wena,
    input [2**addr_width-1:0] r0addr, r1addr, waddr, // Your custom addr width
    input [data_width-1:0] wdata,
    output [data_width-1:0] r0data, r1data
);

    // Internal storage: size is 2 to the power of addr_width
    reg [data_width-1:0] regFile [0:(1 << addr_width)-1];

    // Synchronous Write: Updates on positive edge if Write Enable (wena) is high
    always @(posedge clk) begin
        if (wena)
            regFile[waddr] <= wdata;
    end

    // Asynchronous Read: Ports 0 and 1 provide data immediately based on address
    assign r0data = regFile[r0addr];
    assign r1data = regFile[r1addr];

endmodule
