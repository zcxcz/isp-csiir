//-----------------------------------------------------------------------------
// Module: stage4_iir_blend
// Purpose: IIR filtering and final blending
// Author: rtl-impl
// Date: 2026-03-22
// Version: v2.0 - Added signed data support and line buffer writeback
//-----------------------------------------------------------------------------
// Description:
//   Implements Stage 4 of ISP-CSIIR pipeline:
//   - Blend ratio selection based on window size
//   - IIR horizontal blending (current row with previous row) - signed arithmetic
//   - Window blending (blend0 vs blend1 vs center)
//   - s11 to u10 conversion with saturation
//   - Final output generation and line buffer writeback
//
// Data Format:
//   - Input blend: s11 (11-bit signed, range -512 to +511)
//   - Output: u10 (10-bit unsigned, range 0-1023)
//
// Pipeline Structure (5 cycles):
//   Cycle 0: Input buffer
//   Cycle 1: Ratio selection
//   Cycle 2: IIR mixing (signed)
//   Cycle 3: Window mixing (signed)
//   Cycle 4: Final mixing + s11->u10 conversion
//-----------------------------------------------------------------------------

module stage4_iir_blend #(
    parameter DATA_WIDTH     = 10,
    parameter SIGNED_WIDTH   = 11,   // Signed data width
    parameter GRAD_WIDTH     = 14,
    parameter WIN_SIZE_WIDTH = 6,
    parameter LINE_ADDR_WIDTH = 14,
    parameter ROW_CNT_WIDTH  = 13
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // Stage 3 outputs (s11 signed format)
    input  wire signed [SIGNED_WIDTH-1:0] blend0_dir_avg,
    input  wire signed [SIGNED_WIDTH-1:0] blend1_dir_avg,
    input  wire                        stage3_valid,
    input  wire signed [SIGNED_WIDTH-1:0] avg0_u,
    input  wire signed [SIGNED_WIDTH-1:0] avg1_u,
    input  wire [WIN_SIZE_WIDTH-1:0]   win_size_clip,
    input  wire [DATA_WIDTH-1:0]       center_pixel,

    // Configuration
    input  wire [7:0]                  blending_ratio_0,
    input  wire [7:0]                  blending_ratio_1,
    input  wire [7:0]                  blending_ratio_2,
    input  wire [7:0]                  blending_ratio_3,

    // Output (u10 unsigned format)
    output reg  [DATA_WIDTH-1:0]       dout,
    output reg                         dout_valid,

    // Position info
    input  wire [LINE_ADDR_WIDTH-1:0]  pixel_x,
    input  wire [ROW_CNT_WIDTH-1:0]    pixel_y,
    output reg  [LINE_ADDR_WIDTH-1:0]  pixel_x_out,
    output reg  [ROW_CNT_WIDTH-1:0]    pixel_y_out,

    // Line buffer writeback interface (for IIR feedback)
    output reg                         lb_wb_en,
    output reg  [LINE_ADDR_WIDTH-1:0]  lb_wb_addr,
    output reg  [DATA_WIDTH-1:0]       lb_wb_data
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam IIR_WIDTH = SIGNED_WIDTH + 7;  // 18-bit for IIR intermediate (signed)

    //=========================================================================
    // Cycle 0: Input Buffer
    //=========================================================================
    reg signed [SIGNED_WIDTH-1:0] blend0_s0, blend1_s0;
    reg signed [SIGNED_WIDTH-1:0] avg0_u_s0, avg1_u_s0;
    reg [DATA_WIDTH-1:0]     center_s0;
    reg [WIN_SIZE_WIDTH-1:0] win_size_s0;
    reg                      valid_s0;
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_s0;
    reg [ROW_CNT_WIDTH-1:0]  pixel_y_s0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blend0_s0   <= {SIGNED_WIDTH{1'b0}};
            blend1_s0   <= {SIGNED_WIDTH{1'b0}};
            avg0_u_s0   <= {SIGNED_WIDTH{1'b0}};
            avg1_u_s0   <= {SIGNED_WIDTH{1'b0}};
            center_s0   <= {DATA_WIDTH{1'b0}};
            win_size_s0 <= {WIN_SIZE_WIDTH{1'b0}};
            valid_s0    <= 1'b0;
            pixel_x_s0  <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s0  <= {ROW_CNT_WIDTH{1'b0}};
        end else if (enable) begin
            blend0_s0   <= blend0_dir_avg;
            blend1_s0   <= blend1_dir_avg;
            avg0_u_s0   <= avg0_u;
            avg1_u_s0   <= avg1_u;
            center_s0   <= center_pixel;
            win_size_s0 <= win_size_clip;
            valid_s0    <= stage3_valid;
            pixel_x_s0  <= pixel_x;
            pixel_y_s0  <= pixel_y;
        end
    end

    //=========================================================================
    // Cycle 1: Ratio Selection
    //=========================================================================
    // Select blending ratio based on window size
    // win_size: 16-23 -> ratio0, 24-31 -> ratio1, 32-39 -> ratio2, 40+ -> ratio3
    wire [2:0] ratio_idx_comb;
    assign ratio_idx_comb = (win_size_s0 < 6'd24) ? 3'd0 :
                            (win_size_s0 < 6'd32) ? 3'd1 :
                            (win_size_s0 < 6'd40) ? 3'd2 : 3'd3;

    wire [7:0] blend_ratio_comb = (ratio_idx_comb == 0) ? blending_ratio_0 :
                                  (ratio_idx_comb == 1) ? blending_ratio_1 :
                                  (ratio_idx_comb == 2) ? blending_ratio_2 : blending_ratio_3;

    // Blend factor for window mixing
    wire [2:0] blend_factor_comb = (win_size_s0 < 6'd24) ? 3'd1 :
                                   (win_size_s0 < 6'd32) ? 3'd2 :
                                   (win_size_s0 < 6'd40) ? 3'd3 : 3'd4;

    // Window size remainder
    wire [2:0] win_remain_comb = win_size_s0[2:0];  // win_size % 8

    // Pipeline registers for Cycle 1
    reg signed [SIGNED_WIDTH-1:0] blend0_s1, blend1_s1;
    reg signed [SIGNED_WIDTH-1:0] avg0_u_s1, avg1_u_s1;
    reg [DATA_WIDTH-1:0]     center_s1;
    reg [7:0]                ratio_s1;
    reg [2:0]                factor_s1;
    reg [2:0]                remain_s1;
    reg                      valid_s1;
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_s1;
    reg [ROW_CNT_WIDTH-1:0]  pixel_y_s1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blend0_s1   <= {SIGNED_WIDTH{1'b0}};
            blend1_s1   <= {SIGNED_WIDTH{1'b0}};
            avg0_u_s1   <= {SIGNED_WIDTH{1'b0}};
            avg1_u_s1   <= {SIGNED_WIDTH{1'b0}};
            center_s1   <= {DATA_WIDTH{1'b0}};
            ratio_s1    <= 8'd32;
            factor_s1   <= 3'd2;
            remain_s1   <= 3'd0;
            valid_s1    <= 1'b0;
            pixel_x_s1  <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s1  <= {ROW_CNT_WIDTH{1'b0}};
        end else if (enable) begin
            blend0_s1   <= blend0_s0;
            blend1_s1   <= blend1_s0;
            avg0_u_s1   <= avg0_u_s0;
            avg1_u_s1   <= avg1_u_s0;
            center_s1   <= center_s0;
            ratio_s1    <= blend_ratio_comb;
            factor_s1   <= blend_factor_comb;
            remain_s1   <= win_remain_comb;
            valid_s1    <= valid_s0;
            pixel_x_s1  <= pixel_x_s0;
            pixel_y_s1  <= pixel_y_s0;
        end
    end

    //=========================================================================
    // Cycle 2: IIR Mixing (Signed Arithmetic)
    //=========================================================================
    // IIR blend: ratio * current + (64 - ratio) * previous / 64
    // Using signed arithmetic
    wire signed [IIR_WIDTH-1:0] blend0_iir_comb = (ratio_s1 * blend0_s1 + (64 - ratio_s1) * avg0_u_s1) >>> 6;
    wire signed [IIR_WIDTH-1:0] blend1_iir_comb = (ratio_s1 * blend1_s1 + (64 - ratio_s1) * avg1_u_s1) >>> 6;

    // Saturate to s11 range [-512, +511]
    wire signed [SIGNED_WIDTH-1:0] blend0_iir_sat;
    wire signed [SIGNED_WIDTH-1:0] blend1_iir_sat;

    assign blend0_iir_sat = (blend0_iir_comb > $signed(11'sd511)) ? $signed(11'sd511) :
                            (blend0_iir_comb < $signed(-11'sd512)) ? $signed(-11'sd512) :
                            blend0_iir_comb[SIGNED_WIDTH-1:0];

    assign blend1_iir_sat = (blend1_iir_comb > $signed(11'sd511)) ? $signed(11'sd511) :
                            (blend1_iir_comb < $signed(-11'sd512)) ? $signed(-11'sd512) :
                            blend1_iir_comb[SIGNED_WIDTH-1:0];

    // Pipeline registers for Cycle 2
    reg signed [SIGNED_WIDTH-1:0] blend0_iir_s2, blend1_iir_s2;
    reg [DATA_WIDTH-1:0] center_s2;
    reg [2:0]            factor_s2;
    reg [2:0]            remain_s2;
    reg                  valid_s2;
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_s2;
    reg [ROW_CNT_WIDTH-1:0]  pixel_y_s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blend0_iir_s2 <= {SIGNED_WIDTH{1'b0}};
            blend1_iir_s2 <= {SIGNED_WIDTH{1'b0}};
            center_s2     <= {DATA_WIDTH{1'b0}};
            factor_s2     <= 3'd2;
            remain_s2     <= 3'd0;
            valid_s2      <= 1'b0;
            pixel_x_s2    <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s2    <= {ROW_CNT_WIDTH{1'b0}};
        end else if (enable) begin
            blend0_iir_s2 <= blend0_iir_sat;
            blend1_iir_s2 <= blend1_iir_sat;
            center_s2     <= center_s1;
            factor_s2     <= factor_s1;
            remain_s2     <= remain_s1;
            valid_s2      <= valid_s1;
            pixel_x_s2    <= pixel_x_s1;
            pixel_y_s2    <= pixel_y_s1;
        end
    end

    //=========================================================================
    // Cycle 3: Window Mixing (Signed Arithmetic)
    //=========================================================================
    // Convert center pixel (u10) to s11 for mixing
    wire signed [SIGNED_WIDTH-1:0] center_s11 = $signed({1'b0, center_s2}) - $signed(11'sd512);

    // Compute inverse factor (4 - factor)
    wire [3:0] inv_factor = 4'd4 - {1'b0, factor_s2};

    // Window blend: factor * iir + (4 - factor) * center / 4 (signed)
    wire signed [13:0] blend0_out_comb = (blend0_iir_s2 * $signed({5'b0, factor_s2}) +
                                          center_s11 * $signed({5'b0, inv_factor})) >>> 2;
    wire signed [13:0] blend1_out_comb = (blend1_iir_s2 * $signed({5'b0, factor_s2}) +
                                          center_s11 * $signed({5'b0, inv_factor})) >>> 2;

    // Saturate to s11 range
    wire signed [SIGNED_WIDTH-1:0] blend0_out_sat;
    wire signed [SIGNED_WIDTH-1:0] blend1_out_sat;

    assign blend0_out_sat = (blend0_out_comb > $signed(11'sd511)) ? $signed(11'sd511) :
                            (blend0_out_comb < $signed(-11'sd512)) ? $signed(-11'sd512) :
                            blend0_out_comb[SIGNED_WIDTH-1:0];

    assign blend1_out_sat = (blend1_out_comb > $signed(11'sd511)) ? $signed(11'sd511) :
                            (blend1_out_comb < $signed(-11'sd512)) ? $signed(-11'sd512) :
                            blend1_out_comb[SIGNED_WIDTH-1:0];

    // Pipeline registers for Cycle 3
    reg signed [SIGNED_WIDTH-1:0] blend0_out_s3, blend1_out_s3;
    reg [2:0]            remain_s3;
    reg                  valid_s3;
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_s3;
    reg [ROW_CNT_WIDTH-1:0]  pixel_y_s3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blend0_out_s3 <= {SIGNED_WIDTH{1'b0}};
            blend1_out_s3 <= {SIGNED_WIDTH{1'b0}};
            remain_s3     <= 3'd0;
            valid_s3      <= 1'b0;
            pixel_x_s3    <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s3    <= {ROW_CNT_WIDTH{1'b0}};
        end else if (enable) begin
            blend0_out_s3 <= blend0_out_sat;
            blend1_out_s3 <= blend1_out_sat;
            remain_s3     <= remain_s2;
            valid_s3      <= valid_s2;
            pixel_x_s3    <= pixel_x_s2;
            pixel_y_s3    <= pixel_y_s2;
        end
    end

    //=========================================================================
    // Cycle 4: Final Mixing + s11 to u10 Conversion
    //=========================================================================
    // Compute inverse remainder (8 - remain)
    wire [4:0] inv_remain = 5'd8 - {2'b0, remain_s3};

    // Final blend: remain * blend0 + (8 - remain) * blend1 / 8 (signed)
    wire signed [14:0] blend_final_s11 = (blend0_out_s3 * $signed({5'b0, remain_s3}) +
                                          blend1_out_s3 * $signed({5'b0, inv_remain})) >>> 3;

    // Saturate to s11 range
    wire signed [SIGNED_WIDTH-1:0] blend_final_sat;
    assign blend_final_sat = (blend_final_s11 > $signed(11'sd511)) ? $signed(11'sd511) :
                             (blend_final_s11 < $signed(-11'sd512)) ? $signed(-11'sd512) :
                             blend_final_s11[SIGNED_WIDTH-1:0];

    //=========================================================================
    // s11 to u10 Conversion with Saturation
    //=========================================================================
    // u10 = clip(s11 + 512, 0, 1023)
    // s11 range: [-512, +511], s11 + 512 range: [0, 1023]
    wire [11:0] temp_unsigned = $signed(blend_final_sat) + $signed(12'sd512);

    wire [DATA_WIDTH-1:0] dout_sat;
    assign dout_sat = (temp_unsigned[11]) ? 10'd0 :                    // Negative -> 0
                      (temp_unsigned > 12'd1023) ? 10'd1023 :          // Overflow -> 1023
                      temp_unsigned[DATA_WIDTH-1:0];                   // Normal case

    // Output registers
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout        <= {DATA_WIDTH{1'b0}};
            dout_valid  <= 1'b0;
            pixel_x_out <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_out <= {ROW_CNT_WIDTH{1'b0}};
            lb_wb_en    <= 1'b0;
            lb_wb_addr  <= {LINE_ADDR_WIDTH{1'b0}};
            lb_wb_data  <= {DATA_WIDTH{1'b0}};
        end else if (enable) begin
            dout        <= dout_sat;
            dout_valid  <= valid_s3;
            pixel_x_out <= pixel_x_s3;
            pixel_y_out <= pixel_y_s3;
            // Line buffer writeback control
            lb_wb_en    <= valid_s3;
            lb_wb_addr  <= pixel_x_s3;
            lb_wb_data  <= dout_sat;
        end
    end

endmodule