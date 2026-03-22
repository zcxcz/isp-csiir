//-----------------------------------------------------------------------------
// Module: common_delay_line
// Purpose: Shift register delay line
// Author: rtl-impl
// Date: 2026-03-22
// Version: v1.0
//-----------------------------------------------------------------------------
// Description:
//   Parameterized shift register supporting:
//   - Configurable data width
//   - Configurable number of stages
//   - Tap outputs for each stage
//-----------------------------------------------------------------------------

module common_delay_line #(
    parameter DATA_WIDTH  = 10,
    parameter STAGES      = 5
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,
    input  wire [DATA_WIDTH-1:0]       din,
    output wire [DATA_WIDTH-1:0]       dout,
    output wire [DATA_WIDTH-1:0]       tap [0:STAGES-1]
);

    //=========================================================================
    // Internal Signals
    //=========================================================================
    reg [DATA_WIDTH-1:0] delay_reg [0:STAGES-1];

    //=========================================================================
    // Delay Line Logic
    //=========================================================================
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < STAGES; i = i + 1) begin
                delay_reg[i] <= {DATA_WIDTH{1'b0}};
            end
        end else if (enable) begin
            delay_reg[0] <= din;
            for (i = 1; i < STAGES; i = i + 1) begin
                delay_reg[i] <= delay_reg[i-1];
            end
        end
    end

    //=========================================================================
    // Output Assignment
    //=========================================================================
    assign dout = delay_reg[STAGES-1];

    genvar g;
    generate
        for (g = 0; g < STAGES; g = g + 1) begin : gen_tap
            assign tap[g] = delay_reg[g];
        end
    endgenerate

endmodule