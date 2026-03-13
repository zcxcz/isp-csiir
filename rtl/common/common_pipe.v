//-----------------------------------------------------------------------------
// Module: common_pipe
// Description: Parameterized data pipe (pipeline register)
//              Combinational input -> Registered output
//              Supports reset, enable, and clear
//-----------------------------------------------------------------------------

module common_pipe #(
    parameter DATA_WIDTH = 8,
    parameter RESET_VAL  = 0,
    parameter STAGES     = 1   // Number of pipeline stages (1 = single register)
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      enable,
    input  wire                      clear,     // Synchronous clear
    input  wire [DATA_WIDTH-1:0]     din,
    output wire [DATA_WIDTH-1:0]     dout
);

    // Internal pipeline registers
    reg [DATA_WIDTH-1:0] pipe_reg [0:STAGES-1];

    // Generate pipeline stages
    genvar i;
    generate
        for (i = 0; i < STAGES; i = i + 1) begin : gen_pipe
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    pipe_reg[i] <= RESET_VAL[DATA_WIDTH-1:0];
                end else if (clear) begin
                    pipe_reg[i] <= RESET_VAL[DATA_WIDTH-1:0];
                end else if (enable) begin
                    if (i == 0)
                        pipe_reg[i] <= din;
                    else
                        pipe_reg[i] <= pipe_reg[i-1];
                end
            end
        end
    endgenerate

    // Output assignment
    assign dout = pipe_reg[STAGES-1];

endmodule