//-----------------------------------------------------------------------------
// Module: stage4_iir_blend
// Purpose: IIR filtering and final blending
// Author: rtl-impl
// Date: 2026-03-22
// Version: v1.0
//-----------------------------------------------------------------------------
// Description:
//   Implements Stage 4 of ISP-CSIIR pipeline:
//   - Blend ratio selection based on window size
//   - IIR horizontal blending (current row with previous row)
//   - Window blending (blend0 vs blend1 vs center)
//   - Final output generation
//
// Pipeline Structure (5 cycles):
//   Cycle 0: Input buffer
//   Cycle 1: Ratio selection
//   Cycle 2: IIR mixing
//   Cycle 3: Window mixing
//   Cycle 4: Final mixing
//-----------------------------------------------------------------------------

module stage4_iir_blend #(
    parameter DATA_WIDTH     = 10,
    parameter GRAD_WIDTH     = 14,
    parameter WIN_SIZE_WIDTH = 6,
    parameter LINE_ADDR_WIDTH = 14,
    parameter ROW_CNT_WIDTH  = 13
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // Stage 3 outputs
    input  wire [DATA_WIDTH-1:0]       blend0_dir_avg,
    input  wire [DATA_WIDTH-1:0]       blend1_dir_avg,
    input  wire                        stage3_valid,
    input  wire [DATA_WIDTH-1:0]       avg0_u,
    input  wire [DATA_WIDTH-1:0]       avg1_u,
    input  wire [WIN_SIZE_WIDTH-1:0]   win_size_clip,
    input  wire [DATA_WIDTH-1:0]       center_pixel,

    // Configuration
    input  wire [7:0]                  blending_ratio_0,
    input  wire [7:0]                  blending_ratio_1,
    input  wire [7:0]                  blending_ratio_2,
    input  wire [7:0]                  blending_ratio_3,

    // Output
    output reg  [DATA_WIDTH-1:0]       dout,
    output reg                         dout_valid,

    // Position info
    input  wire [LINE_ADDR_WIDTH-1:0]  pixel_x,
    input  wire [ROW_CNT_WIDTH-1:0]    pixel_y,
    output reg  [LINE_ADDR_WIDTH-1:0]  pixel_x_out,
    output reg  [ROW_CNT_WIDTH-1:0]    pixel_y_out,

    // IIR feedback control
    output reg                         iir_wb_en,
    output reg  [LINE_ADDR_WIDTH-1:0]  iir_wb_addr,
    output reg  [DATA_WIDTH-1:0]       iir_wb_data
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam IIR_WIDTH = DATA_WIDTH + 7;  // 17-bit for IIR intermediate

    //=========================================================================
    // Cycle 0: Input Buffer
    //=========================================================================
    reg [DATA_WIDTH-1:0]     blend0_s0, blend1_s0;
    reg [DATA_WIDTH-1:0]     avg0_u_s0, avg1_u_s0;
    reg [DATA_WIDTH-1:0]     center_s0;
    reg [WIN_SIZE_WIDTH-1:0] win_size_s0;
    reg                      valid_s0;
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_s0;
    reg [ROW_CNT_WIDTH-1:0]  pixel_y_s0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blend0_s0   <= {DATA_WIDTH{1'b0}};
            blend1_s0   <= {DATA_WIDTH{1'b0}};
            avg0_u_s0   <= {DATA_WIDTH{1'b0}};
            avg1_u_s0   <= {DATA_WIDTH{1'b0}};
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
    reg [DATA_WIDTH-1:0]     blend0_s1, blend1_s1;
    reg [DATA_WIDTH-1:0]     avg0_u_s1, avg1_u_s1;
    reg [DATA_WIDTH-1:0]     center_s1;
    reg [7:0]                ratio_s1;
    reg [2:0]                factor_s1;
    reg [2:0]                remain_s1;
    reg                      valid_s1;
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_s1;
    reg [ROW_CNT_WIDTH-1:0]  pixel_y_s1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blend0_s1   <= {DATA_WIDTH{1'b0}};
            blend1_s1   <= {DATA_WIDTH{1'b0}};
            avg0_u_s1   <= {DATA_WIDTH{1'b0}};
            avg1_u_s1   <= {DATA_WIDTH{1'b0}};
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
    // Cycle 2: IIR Mixing
    //=========================================================================
    // IIR blend: ratio * current + (64 - ratio) * previous / 64
    wire [IIR_WIDTH-1:0] blend0_iir_comb = (ratio_s1 * blend0_s1 + (64 - ratio_s1) * avg0_u_s1) >> 6;
    wire [IIR_WIDTH-1:0] blend1_iir_comb = (ratio_s1 * blend1_s1 + (64 - ratio_s1) * avg1_u_s1) >> 6;

    // Saturate to 10-bit
    wire [DATA_WIDTH-1:0] blend0_iir_sat = (blend0_iir_comb > {{IIR_WIDTH-DATA_WIDTH{1'b0}}, {DATA_WIDTH{1'b1}}}) ?
                                           {DATA_WIDTH{1'b1}} : blend0_iir_comb[DATA_WIDTH-1:0];
    wire [DATA_WIDTH-1:0] blend1_iir_sat = (blend1_iir_comb > {{IIR_WIDTH-DATA_WIDTH{1'b0}}, {DATA_WIDTH{1'b1}}}) ?
                                           {DATA_WIDTH{1'b1}} : blend1_iir_comb[DATA_WIDTH-1:0];

    // Pipeline registers for Cycle 2
    reg [DATA_WIDTH-1:0] blend0_iir_s2, blend1_iir_s2;
    reg [DATA_WIDTH-1:0] center_s2;
    reg [2:0]            factor_s2;
    reg [2:0]            remain_s2;
    reg                  valid_s2;
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_s2;
    reg [ROW_CNT_WIDTH-1:0]  pixel_y_s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blend0_iir_s2 <= {DATA_WIDTH{1'b0}};
            blend1_iir_s2 <= {DATA_WIDTH{1'b0}};
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
    // Cycle 3: Window Mixing
    //=========================================================================
    // Window blend: factor * iir + (4 - factor) * center / 4
    wire [11:0] blend0_out_comb = (blend0_iir_s2 * factor_s2 + center_s2 * (4 - factor_s2)) >> 2;
    wire [11:0] blend1_out_comb = (blend1_iir_s2 * factor_s2 + center_s2 * (4 - factor_s2)) >> 2;

    // Saturate to 10-bit
    wire [DATA_WIDTH-1:0] blend0_out_sat = (blend0_out_comb > {2'b0, {DATA_WIDTH{1'b1}}}) ?
                                           {DATA_WIDTH{1'b1}} : blend0_out_comb[DATA_WIDTH-1:0];
    wire [DATA_WIDTH-1:0] blend1_out_sat = (blend1_out_comb > {2'b0, {DATA_WIDTH{1'b1}}}) ?
                                           {DATA_WIDTH{1'b1}} : blend1_out_comb[DATA_WIDTH-1:0];

    // Pipeline registers for Cycle 3
    reg [DATA_WIDTH-1:0] blend0_out_s3, blend1_out_s3;
    reg [2:0]            remain_s3;
    reg                  valid_s3;
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_s3;
    reg [ROW_CNT_WIDTH-1:0]  pixel_y_s3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blend0_out_s3 <= {DATA_WIDTH{1'b0}};
            blend1_out_s3 <= {DATA_WIDTH{1'b0}};
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
    // Cycle 4: Final Mixing
    //=========================================================================
    // Final blend: remain * blend0 + (8 - remain) * blend1 / 8
    wire [12:0] dout_comb = (blend0_out_s3 * remain_s3 + blend1_out_s3 * (8 - remain_s3)) >> 3;

    // Saturate to 10-bit
    wire [DATA_WIDTH-1:0] dout_sat = (dout_comb > {3'b0, {DATA_WIDTH{1'b1}}}) ?
                                     {DATA_WIDTH{1'b1}} : dout_comb[DATA_WIDTH-1:0];

    // Output registers
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout        <= {DATA_WIDTH{1'b0}};
            dout_valid  <= 1'b0;
            pixel_x_out <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_out <= {ROW_CNT_WIDTH{1'b0}};
            iir_wb_en   <= 1'b0;
            iir_wb_addr <= {LINE_ADDR_WIDTH{1'b0}};
            iir_wb_data <= {DATA_WIDTH{1'b0}};
        end else if (enable) begin
            dout        <= dout_sat;
            dout_valid  <= valid_s3;
            pixel_x_out <= pixel_x_s3;
            pixel_y_out <= pixel_y_s3;
            // IIR feedback control
            iir_wb_en   <= valid_s3;
            iir_wb_addr <= pixel_x_s3;
            iir_wb_data <= dout_sat;
        end
    end

endmodule