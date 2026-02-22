module REG_FILE_BANK #(
    parameter data_width = 64, 
    parameter addr_width = 4,
    parameter th_id_width = 2   // Added parameter for thread ID width
)(
    input clk, wena,
    input [th_id_width-1:0] rd_th_id, w_th_id, 
    input [addr_width-1:0] r0addr, r1addr, waddr, 
    input [data_width-1:0] wdata,
    output [data_width-1:0] r0data, r1data
);

    // Fixed array size: (1 << th_id_width) automatically sizes it for 4 threads
    reg [data_width-1:0] regFile [0:(1 << th_id_width)-1][0:(1 << addr_width)-1];

    // Synchronous Write: Prevents the write operation from touching regFile[0]
    always @(posedge clk) begin
        if (wena && (waddr != 0))
            regFile[w_th_id][waddr] <= wdata;
    end

    // Asynchronous Read: Hardwiring the zero at the output mux level
    assign r0data = (r0addr == 0) ? {data_width{1'b0}} : regFile[rd_th_id][r0addr];
    assign r1data = (r1addr == 0) ? {data_width{1'b0}} : regFile[rd_th_id][r1addr];

endmodule
