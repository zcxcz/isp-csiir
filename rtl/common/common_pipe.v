//-----------------------------------------------------------------------------
// Module: common_pipe
// Purpose: Pipeline register with optional reset value
// Author: rtl-impl
// Date: 2026-03-22
// Version: v1.0
//-----------------------------------------------------------------------------
// Description:
//   Parameterized pipeline register supporting:
//   - Configurable data width
//   - Multiple pipeline stages
//   - Optional reset value
//   - Clock enable
//-----------------------------------------------------------------------------

module common_pipe #(
    parameter DATA_WIDTH  = 10,
    parameter STAGES      = 1,
    parameter RESET_VAL   = 0
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      enable,
    input  wire [DATA_WIDTH-1:0]     din,
    output wire [DATA_WIDTH-1:0]     dout
);

    //=========================================================================
    // Internal Signals
    //=========================================================================
    reg [DATA_WIDTH-1:0] pipe_reg [0:STAGES-1];

    //=========================================================================
    // Pipeline Register Logic
    //=========================================================================
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < STAGES; i = i + 1) begin
                pipe_reg[i] <= RESET_VAL[DATA_WIDTH-1:0];
            end
        end else if (enable) begin
            pipe_reg[0] <= din;
            for (i = 1; i < STAGES; i = i + 1) begin
                pipe_reg[i] <= pipe_reg[i-1];
            end
        end
    end

    //=========================================================================
    // Output Assignment
    //=========================================================================
    assign dout = pipe_reg[STAGES-1];

endmodule