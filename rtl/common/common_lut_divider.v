//-----------------------------------------------------------------------------
// Module: common_lut_divider
// Purpose: Single-cycle LUT-based divider with index compression
// Author: rtl-impl
// Date: 2026-03-22
// Version: v1.0
//-----------------------------------------------------------------------------
// Description:
//   Implements rounded unsigned division:
//     quotient = round(numerator / dividend)
//
//   This module originally used a compressed reciprocal LUT, but the bucketed
//   approximation diverged from the fixed-point golden model in Stage 3
//   integration. Keep the interface unchanged and compute the rounded divide
//   directly so RTL matches the model semantics exactly.
//
// Timing:
//   - Division is combinational
//   - Output remains registered (1 cycle latency)
//-----------------------------------------------------------------------------

module common_lut_divider #(
    parameter DIVIDEND_WIDTH = 17,  // Width of dividend input
    parameter QUOTIENT_WIDTH = 10,  // Width of quotient output
    parameter PRODUCT_SHIFT  = 26   // Right shift for final quotient
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // Data input
    input  wire [DIVIDEND_WIDTH-1:0]   dividend,
    input  wire [PRODUCT_SHIFT-1:0]    numerator,  // Value to be divided
    input  wire                        valid_in,

    // Data output
    output reg  [QUOTIENT_WIDTH-1:0]   quotient,
    output reg                         valid_out
);

    //=========================================================================
    // Rounded Divide (Combinational)
    //=========================================================================
    localparam DIVIDE_EXT_WIDTH = PRODUCT_SHIFT + 1;

    wire [DIVIDE_EXT_WIDTH-1:0] numerator_ext = {1'b0, numerator};
    wire [DIVIDE_EXT_WIDTH-1:0] half_divisor_ext = {{(DIVIDE_EXT_WIDTH-DIVIDEND_WIDTH){1'b0}}, dividend} >> 1;
    wire [DIVIDE_EXT_WIDTH-1:0] rounded_numerator = numerator_ext + half_divisor_ext;
    wire [DIVIDE_EXT_WIDTH-1:0] quotient_full = (dividend == 0) ? {DIVIDE_EXT_WIDTH{1'b0}} :
                                                (rounded_numerator / dividend);

    wire [QUOTIENT_WIDTH-1:0] quotient_comb =
        (dividend == 0) ? {QUOTIENT_WIDTH{1'b0}} :
        (|quotient_full[DIVIDE_EXT_WIDTH-1:QUOTIENT_WIDTH]) ? {QUOTIENT_WIDTH{1'b1}} :
                                                              quotient_full[QUOTIENT_WIDTH-1:0];

    //=========================================================================
    // Output Registers
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            quotient  <= {QUOTIENT_WIDTH{1'b0}};
            valid_out <= 1'b0;
        end else if (enable) begin
            quotient  <= quotient_comb;
            valid_out <= valid_in;
        end
    end

endmodule
