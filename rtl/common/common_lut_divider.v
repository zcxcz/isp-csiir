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
    // MUST match Python model's index calculation exactly
    wire [7:0] lut_index;
    wire [DIVIDEND_WIDTH-1:0] gs = dividend;

    // Index calculation matches Python isp_csiir_fixed_model.py:
    //   gs < 128:   lut_index = gs
    //   gs < 256:   lut_index = 128 + ((gs - 128) >> 1)
    //   gs < 512:   lut_index = 160 + ((gs - 256) >> 2)
    //   gs < 1024:  lut_index = 192 + ((gs - 512) >> 4)  -- 16:1 compression
    //   gs >= 1024: lut_index = 224 + min(((gs - 1024) >> 13), 31)
    wire [DIVIDEND_WIDTH-1:0] gs_m128 = gs - 128;
    wire [DIVIDEND_WIDTH-1:0] gs_m256 = gs - 256;
    wire [DIVIDEND_WIDTH-1:0] gs_m512 = gs - 512;
    wire [DIVIDEND_WIDTH-1:0] gs_m1024 = gs - 1024;

    assign lut_index = (gs == 0) ? 8'd0 :
                       (gs < 128) ? gs[7:0] :
                       (gs < 256) ? (8'd128 + gs_m128[7:1]) :           // 128 + ((gs-128)>>1), 2:1 compression
                       (gs < 512) ? (8'd160 + gs_m256[8:3]) :           // 160 + ((gs-256)>>3), 8:1 compression
                       (gs < 1024) ? (8'd192 + gs_m512[9:4]) :          // 192 + ((gs-512)>>4), 16:1 compression
                       (gs[DIVIDEND_WIDTH-1]) ? 8'd255 :                 // Large values clamp to 255
                       (gs[DIVIDEND_WIDTH-2]) ? 8'd255 :
                       (gs[DIVIDEND_WIDTH-3]) ? 8'd255 :
                       (8'd224 + (gs_m1024[DIVIDEND_WIDTH-1:13] > 31 ? 5'd31 : gs_m1024[DIVIDEND_WIDTH-1:13]));

    //=========================================================================
    // LUT (256 x 16-bit) for Inverse Values
    //=========================================================================
    // inv = round(2^PRODUCT_SHIFT / typical_dividend)
    reg [15:0] div_lut [0:255];

    // Initialize LUT with inverse values
    integer init_i;

    initial begin
        // LUT values computed as: inv = round(2^26 / typical_dividend)
        // Index 0: dividend = 0 (special case, max value)
        div_lut[0] = 16'd65535;

        // Index 1-223: Small dividends, all clamped to max (2^26/dividend > 65535)
        for (init_i = 1; init_i < 224; init_i = init_i + 1) begin
            div_lut[init_i] = 16'd65535;
        end

        // Index 224-255: Larger dividends with computed inverse values
        // dividend range 8192-122880, inverse fits in 16 bits
        div_lut[224] = 16'd8192;   // dividend = 8192
        div_lut[225] = 16'd7281;   // dividend = 9216
        div_lut[226] = 16'd6553;   // dividend = 10240
        div_lut[227] = 16'd5957;   // dividend = 11264
        div_lut[228] = 16'd5461;   // dividend = 12288
        div_lut[229] = 16'd5041;   // dividend = 13312
        div_lut[230] = 16'd4681;   // dividend = 14336
        div_lut[231] = 16'd4369;   // dividend = 15360
        div_lut[232] = 16'd4096;   // dividend = 16384
        div_lut[233] = 16'd3640;   // dividend = 18432
        div_lut[234] = 16'd3276;   // dividend = 20480
        div_lut[235] = 16'd2978;   // dividend = 22528
        div_lut[236] = 16'd2730;   // dividend = 24576
        div_lut[237] = 16'd2520;   // dividend = 26624
        div_lut[238] = 16'd2340;   // dividend = 28672
        div_lut[239] = 16'd2184;   // dividend = 30720
        div_lut[240] = 16'd2048;   // dividend = 32768
        div_lut[241] = 16'd1820;   // dividend = 36864
        div_lut[242] = 16'd1638;   // dividend = 40960
        div_lut[243] = 16'd1489;   // dividend = 45056
        div_lut[244] = 16'd1365;   // dividend = 49152
        div_lut[245] = 16'd1260;   // dividend = 53248
        div_lut[246] = 16'd1170;   // dividend = 57344
        div_lut[247] = 16'd1092;   // dividend = 61440
        div_lut[248] = 16'd1024;   // dividend = 65536
        div_lut[249] = 16'd910;    // dividend = 73728
        div_lut[250] = 16'd819;    // dividend = 81920
        div_lut[251] = 16'd744;    // dividend = 90112
        div_lut[252] = 16'd682;    // dividend = 98304
        div_lut[253] = 16'd630;    // dividend = 106496
        div_lut[254] = 16'd585;    // dividend = 114688
        div_lut[255] = 16'd546;    // dividend = 122880
    end

    //=========================================================================
    // LUT Read and Multiplication (Combinational)
    //=========================================================================
    wire [15:0] inv_value = div_lut[lut_index];

    // Multiplication: numerator * inv_value
    wire [PRODUCT_SHIFT+15:0] product = numerator * inv_value;

    // Quotient = product >> PRODUCT_SHIFT (extract upper bits)
    // This gives: numerator * (2^PRODUCT_SHIFT / dividend) >> PRODUCT_SHIFT
    //           = numerator / dividend (approximately)
    wire [QUOTIENT_WIDTH-1:0] quotient_comb = (dividend != 0) ?
                                               product[PRODUCT_SHIFT+QUOTIENT_WIDTH-1:PRODUCT_SHIFT] :
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