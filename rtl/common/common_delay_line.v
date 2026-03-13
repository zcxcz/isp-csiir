//-----------------------------------------------------------------------------
// Module: common_delay_line
// Description: Parameterized delay line (shift register)
//              Used for aligning signals in pipeline
//-----------------------------------------------------------------------------

module common_delay_line #(
    parameter DATA_WIDTH = 1,
    parameter DELAY      = 1,
    parameter RESET_VAL  = 0
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      enable,
    input  wire [DATA_WIDTH-1:0]     din,

    output wire [DATA_WIDTH-1:0]     dout
);

    // Internal delay registers
    reg [DATA_WIDTH-1:0] delay_reg [0:DELAY-1];

    // Generate delay chain
    genvar i;
    generate
        for (i = 0; i < DELAY; i = i + 1) begin : gen_delay
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    delay_reg[i] <= RESET_VAL[DATA_WIDTH-1:0];
                end else if (enable) begin
                    if (i == 0)
                        delay_reg[i] <= din;
                    else
                        delay_reg[i] <= delay_reg[i-1];
                end
            end
        end
    endgenerate

    // Output assignment
    assign dout = delay_reg[DELAY-1];

endmodule