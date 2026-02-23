// =============================================================================
// ALU.v  –  64-bit ALU for the ARM-32 pipeline
//
// aluctrl encoding:
//   0000  NOP     Z = 0
//   0001  ADD     Z = A + B          (overflow detected)
//   0010  SUB     Z = A - B          (overflow detected)
//   0011  AND     Z = A & B
//   0100  OR      Z = A | B
//   0101  XNOR    Z = ~(A ^ B)
//   0110  SHIFTL  Z = A << 1         (shift left  by 1, immediate form)
//   0111  SHIFTR  Z = A >> 1         (shift right by 1, immediate form)
//   1000  SHIFTLV Z = A << B[1:0]   (variable shift left  – NEW)
//   1001  SHIFTRV Z = A >> B[1:0]   (variable shift right – NEW)
//   1010  SLT     Z = (A < B) ? 1 : 0  signed compare   – NEW)
// =============================================================================
module ALU #(parameter data_width = 32) (
  input  [data_width-1:0]     A, B,
  input  [3:0]                aluctrl,
  output reg [data_width-1:0] Z,
  output reg                  overflow
);

  localparam ALU_ADD     = 4'b0001;
  localparam ALU_SUB     = 4'b0010;
  localparam ALU_AND     = 4'b0011;
  localparam ALU_OR      = 4'b0100;
  localparam ALU_XNOR    = 4'b0101;
  localparam ALU_SHIFTL  = 4'b0110;
  localparam ALU_SHIFTR  = 4'b0111;
  localparam ALU_SHIFTLV = 4'b1000;
  localparam ALU_SHIFTRV = 4'b1001;
  localparam ALU_SLT     = 4'b1010;

  always @(*) begin
    overflow = 1'b0;
    case (aluctrl)
      ALU_ADD    : {overflow, Z} = A + B;
      ALU_SUB    : {overflow, Z} = A - B;
      ALU_AND    : Z = A & B;
      ALU_OR     : Z = A | B;
      ALU_XNOR   : Z = ~(A ^ B);
      ALU_SHIFTL : Z = A << 1;
      ALU_SHIFTR : Z = A >> 1;
      ALU_SHIFTLV: Z = A << B[5:0];
      ALU_SHIFTRV: Z = A >> B[5:0];
      ALU_SLT    : Z = ($signed(A) < $signed(B))
                       ? {{(data_width-1){1'b0}}, 1'b1}
                       : {data_width{1'b0}};
      default    : Z = {data_width{1'b0}};
    endcase
  end

endmodule