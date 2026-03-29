//-----------------------------------------------------------------------------
// Module: common_ff
// Purpose: Single-stage register with valid/ready control and data gating
// Author: rtl-impl
// Date: 2026-03-28
// Version: v1.0
//-----------------------------------------------------------------------------
// Features:
//   - Configurable data width
//   - Optional reset value
//   - Valid/Ready style control interface
//   - Data register updates only on valid input to reduce switching activity
//   - Pure Verilog-2001 (synthesizable)
//-----------------------------------------------------------------------------
// Handshake Notes:
//   - This is a lightweight pipeline FF, not a skid buffer
//   - ready_out is always 1
//   - When ready_in=0, both control and data hold their values
//   - When ready_in=1 and valid_in=0, valid_out clears while data holds
//-----------------------------------------------------------------------------

module common_ff #(
    parameter DATA_WIDTH = 10,
    parameter RESET_VAL  = 0
) (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire [DATA_WIDTH-1:0] din,
    input  wire                  valid_in,
    output wire                  ready_out,

    output wire [DATA_WIDTH-1:0] dout,
    output wire                  valid_out,
    input  wire                  ready_in
);

    reg [DATA_WIDTH-1:0] data_reg;
    reg                  valid_reg;

    assign ready_out = 1'b1;

    // Control path tracks valid/bubble movement every accepted cycle.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            valid_reg <= 1'b0;
        else if (ready_in)
            valid_reg <= valid_in;
    end

    // Data path updates only on meaningful transfers to reduce toggling.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            data_reg <= RESET_VAL[DATA_WIDTH-1:0];
        else if (ready_in && valid_in)
            data_reg <= din;
    end

    assign dout      = data_reg;
    assign valid_out = valid_reg;

endmodule
