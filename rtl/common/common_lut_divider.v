//-----------------------------------------------------------------------------
// Module: common_lut_divider
// Purpose: Single-cycle LUT-based divider with index compression
// Author: rtl-impl
// Date: 2026-03-22
// Version: v1.0
//-----------------------------------------------------------------------------
// Description:
//   Implements single-cycle division using a 256-entry compressed LUT.
//   Compresses N-bit dividend index to 8-bit LUT index, multiplies by
//   inverse value to get quotient.
//
// Features:
//   - Single-cycle combinational operation
//   - 256-entry LUT with index compression
//   - Configurable input width
//   - No overlap index design
//
// Index Compression Scheme:
//   dividend 0:        index 0
//   dividend 1-127:    index 1-127 (direct mapping)
//   dividend 128-255:  index 128-159 (2:1 compression)
//   dividend 256-511:  index 160-191 (4:1 compression)
//   dividend 512-1023: index 192-223 (8:1 compression)
//   dividend 1024+:    index 224-255 (higher compression)
//
// Usage:
//   quotient = (dividend * inverse) >> SHIFT_BITS
//
// Timing:
//   - LUT read: combinational
//   - Multiplication: combinational
//   - Output: registered (1 cycle latency)
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
    // Index Compression Logic
    //=========================================================================
    // Compress DIVIDEND_WIDTH-bit dividend to 8-bit LUT index
    wire [7:0] lut_index;
    wire [DIVIDEND_WIDTH-1:0] gs = dividend;

    assign lut_index = (gs == 0) ? 8'd0 :
                       (gs < 128) ? gs[6:0] :                           // 1-127 → 1-127
                       (gs < 256) ? {2'b10, gs[6:1]} :                   // 128-255 → 128-159
                       (gs < 512) ? {2'b10, 5'b10000, gs[7:2]} :         // 256-511 → 160-191
                       (gs < 1024) ? {2'b11, gs[8:3]} :                  // 512-1023 → 192-223
                       (gs[DIVIDEND_WIDTH-1]) ? {5'b11111, gs[12:9]} :   // 65536+ → 248-255
                       (gs[DIVIDEND_WIDTH-2]) ? {5'b11110, gs[11:8]} :   // 32768-65535 → 240-247
                       (gs[DIVIDEND_WIDTH-3]) ? {5'b11101, gs[10:7]} :   // 16384-32767 → 232-239
                       (gs[DIVIDEND_WIDTH-4]) ? {5'b11100, gs[9:6]} :    // 8192-16383 → 224-231
                       {5'b11100, gs[9:6]};                              // fallback

    //=========================================================================
    // LUT (256 x 16-bit) for Inverse Values
    //=========================================================================
    // inv = round(2^PRODUCT_SHIFT / typical_dividend)
    reg [15:0] div_lut [0:255];

    // Initialize LUT with inverse values
    integer init_i;
    reg [31:0] lut_tmp;  // Temporary variable for LUT initialization

    initial begin
        // LUT values computed as: inv = round(2^26 / dividend)
        // dividend = 0: special case (max value)
        div_lut[0] = 16'd65535;  // dividend = 0

        // Index 1-127: dividend 1-127 (direct mapping)
        div_lut[1] = 16'd65535;  // dividend = 1, clamp to max
        for (init_i = 2; init_i < 128; init_i = init_i + 1) begin
            lut_tmp = 67108864 / init_i;
            div_lut[init_i] = (lut_tmp > 65535) ? 16'd65535 : lut_tmp[15:0];
        end

        // Index 128-159: dividend 128-255 (2:1 compression, use midpoint)
        for (init_i = 128; init_i < 160; init_i = init_i + 1) begin
            lut_tmp = 67108864 / ((init_i - 128) * 2 + 128);
            div_lut[init_i] = lut_tmp[15:0];
        end

        // Index 160-191: dividend 256-511 (4:1 compression)
        for (init_i = 160; init_i < 192; init_i = init_i + 1) begin
            lut_tmp = 67108864 / ((init_i - 160) * 4 + 256);
            div_lut[init_i] = lut_tmp[15:0];
        end

        // Index 192-223: dividend 512-1023 (8:1 compression)
        for (init_i = 192; init_i < 224; init_i = init_i + 1) begin
            lut_tmp = 67108864 / ((init_i - 192) * 8 + 512);
            div_lut[init_i] = lut_tmp[15:0];
        end

        // Index 224-231: dividend 8192-16383
        for (init_i = 224; init_i < 232; init_i = init_i + 1) begin
            lut_tmp = 67108864 / ((init_i - 224) * 1024 + 8192);
            div_lut[init_i] = lut_tmp[15:0];
        end

        // Index 232-239: dividend 16384-32767
        for (init_i = 232; init_i < 240; init_i = init_i + 1) begin
            lut_tmp = 67108864 / ((init_i - 232) * 2048 + 16384);
            div_lut[init_i] = lut_tmp[15:0];
        end

        // Index 240-247: dividend 32768-65535
        for (init_i = 240; init_i < 248; init_i = init_i + 1) begin
            lut_tmp = 67108864 / ((init_i - 240) * 4096 + 32768);
            div_lut[init_i] = lut_tmp[15:0];
        end

        // Index 248-255: dividend 65536-131071
        for (init_i = 248; init_i < 256; init_i = init_i + 1) begin
            lut_tmp = 67108864 / ((init_i - 248) * 8192 + 65536);
            div_lut[init_i] = lut_tmp[15:0];
        end
    end

    //=========================================================================
    // LUT Read and Multiplication (Combinational)
    //=========================================================================
    wire [15:0] inv_value = div_lut[lut_index];

    // Multiplication: numerator * inv_value
    wire [PRODUCT_SHIFT+15:0] product = numerator * inv_value;

    // Truncate to QUOTIENT_WIDTH output
    // Extract bits [PRODUCT_SHIFT+5:PRODUCT_SHIFT-QUOTIENT_WIDTH+6] for proper alignment
    localparam PRODUCT_HIGH = PRODUCT_SHIFT + 5;
    localparam PRODUCT_LOW  = PRODUCT_SHIFT - QUOTIENT_WIDTH + 6;

    wire [QUOTIENT_WIDTH-1:0] quotient_comb = (dividend != 0) ?
                                               product[PRODUCT_HIGH:PRODUCT_LOW] :
                                               {QUOTIENT_WIDTH{1'b0}};

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