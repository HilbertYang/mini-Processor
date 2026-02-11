`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date:    08:27:20 02/10/2026 
// Design Name: 
// Module Name:    raddrmux4_1 
// Project Name: 
// Target Devices: 
// Tool versions: 
// Description: 
//
// Dependencies: 
//
// Revision: 
// Revision 0.01 - File Created
// Additional Comments: 
//
//////////////////////////////////////////////////////////////////////////////////
module raddrmux4_1(
    input [63:0] R0,
    input [63:0] R1,
    input [63:0] R2,
    input [63:0] R3,
    input [1:0] addr,
    output [63:0] o
    );
	 
	 assign o = (addr == 2'b00)? R0 :
	            (addr == 2'b01)? R1 : 
					(addr == 2'b10)? R2 :R3;


endmodule
