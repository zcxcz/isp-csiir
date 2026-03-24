//-----------------------------------------------------------------------------
// Module: stage4_iir_blend
// Purpose: IIR filtering and final blending
// Author: rtl-impl
// Date: 2026-03-24
// Version: v3.0 - Refactored with common_pipe and valid/ready handshake
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
//
// Handshake Protocol:
//   - valid_in/valid_out: Data valid indicators
//   - ready_in: Downstream back-pressure signal
//   - ready_out: Always 1 (simple pipeline without skid buffer)
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
    output wire                        stage3_ready,

    // Configuration
    input  wire [7:0]                  blending_ratio_0,
    input  wire [7:0]                  blending_ratio_1,
    input  wire [7:0]                  blending_ratio_2,
    input  wire [7:0]                  blending_ratio_3,

    // Output (u10 unsigned format)
    output wire [DATA_WIDTH-1:0]       dout,
    output wire                        dout_valid,
    input  wire                        dout_ready,

    // Position info
    input  wire [LINE_ADDR_WIDTH-1:0]  pixel_x,
    input  wire [ROW_CNT_WIDTH-1:0]    pixel_y,
    output wire [LINE_ADDR_WIDTH-1:0]  pixel_x_out,
    output wire [ROW_CNT_WIDTH-1:0]    pixel_y_out,

    // Line buffer writeback interface (for IIR feedback)
    output wire                        lb_wb_en,
    output wire [LINE_ADDR_WIDTH-1:0]  lb_wb_addr,
    output wire [DATA_WIDTH-1:0]       lb_wb_data
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam IIR_WIDTH = SIGNED_WIDTH + 7;  // 18-bit for IIR intermediate (signed)

    //=========================================================================
    // Ready Signal (Simple Pipeline - Always Ready)
    //=========================================================================
    assign stage3_ready = 1'b1;

    //=========================================================================
    // Cycle 0: Input Buffer
    //=========================================================================
    localparam PIPE_S0_WIDTH = 4 * SIGNED_WIDTH + DATA_WIDTH + WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 1;

    wire [PIPE_S0_WIDTH-1:0] pipe_s0_din = {blend0_dir_avg, blend1_dir_avg, avg0_u, avg1_u,
                                            center_pixel, win_size_clip, pixel_x, pixel_y, stage3_valid};

    wire [PIPE_S0_WIDTH-1:0] pipe_s0_dout;
    wire                     valid_s0;

    common_pipe #(
        .DATA_WIDTH (PIPE_S0_WIDTH),
        .STAGES     (1),
        .RESET_VAL  (0)
    ) u_pipe_s0 (
        .clk       (clk),
        .rst_n     (rst_n),
        .din       (pipe_s0_din),
        .valid_in  (stage3_valid),
        .ready_out (),
        .dout      (pipe_s0_dout),
        .valid_out (valid_s0),
        .ready_in  (dout_ready)
    );

    // Unpack signals
    wire signed [SIGNED_WIDTH-1:0] blend0_s0 = pipe_s0_dout[PIPE_S0_WIDTH-1 -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] blend1_s0 = pipe_s0_dout[PIPE_S0_WIDTH-1-SIGNED_WIDTH -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] avg0_u_s0 = pipe_s0_dout[PIPE_S0_WIDTH-1-2*SIGNED_WIDTH -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] avg1_u_s0 = pipe_s0_dout[PIPE_S0_WIDTH-1-3*SIGNED_WIDTH -: SIGNED_WIDTH];
    wire [DATA_WIDTH-1:0]     center_s0 = pipe_s0_dout[ROW_CNT_WIDTH + LINE_ADDR_WIDTH + WIN_SIZE_WIDTH + 1 +: DATA_WIDTH];
    wire [WIN_SIZE_WIDTH-1:0] win_size_s0 = pipe_s0_dout[ROW_CNT_WIDTH + LINE_ADDR_WIDTH + 1 +: WIN_SIZE_WIDTH];
    wire [LINE_ADDR_WIDTH-1:0] pixel_x_s0 = pipe_s0_dout[ROW_CNT_WIDTH + 1 +: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0]  pixel_y_s0 = pipe_s0_dout[1 +: ROW_CNT_WIDTH];

    //=========================================================================
    // Cycle 1: Ratio Selection
    //=========================================================================
    // Select blending ratio based on window size
    wire [2:0] ratio_idx_comb;
    assign ratio_idx_comb = (win_size_s0 < 6'd24) ? 3'd0 :
                            (win_size_s0 < 6'd32) ? 3'd1 :
                            (win_size_s0 < 6'd40) ? 3'd2 : 3'd3;

    wire [7:0] blend_ratio_comb = (ratio_idx_comb == 0) ? blending_ratio_0 :
                                  (ratio_idx_comb == 1) ? blending_ratio_1 :
                                  (ratio_idx_comb == 2) ? blending_ratio_2 : blending_ratio_3;

    // Blend factor for window mixing
    wire [2:0] blend_factor_comb = |win_size_s0[5:3] ? win_size_s0[5:3] : 3'd1;

    // Window size remainder
    wire [2:0] win_remain_comb = win_size_s0[2:0];

    //=========================================================================
    // Cycle 1 Pipeline Registers
    //=========================================================================
    localparam PIPE_S1_WIDTH = 4 * SIGNED_WIDTH + DATA_WIDTH + 8 + 3 + 3 + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 1;

    wire [PIPE_S1_WIDTH-1:0] pipe_s1_din = {blend0_s0, blend1_s0, avg0_u_s0, avg1_u_s0,
                                            center_s0, blend_ratio_comb, blend_factor_comb, win_remain_comb,
                                            pixel_x_s0, pixel_y_s0, valid_s0};

    wire [PIPE_S1_WIDTH-1:0] pipe_s1_dout;
    wire                     valid_s1;

    common_pipe #(
        .DATA_WIDTH (PIPE_S1_WIDTH),
        .STAGES     (1),
        .RESET_VAL  (0)
    ) u_pipe_s1 (
        .clk       (clk),
        .rst_n     (rst_n),
        .din       (pipe_s1_din),
        .valid_in  (valid_s0),
        .ready_out (),
        .dout      (pipe_s1_dout),
        .valid_out (valid_s1),
        .ready_in  (dout_ready)
    );

    // Unpack signals
    wire signed [SIGNED_WIDTH-1:0] blend0_s1 = pipe_s1_dout[PIPE_S1_WIDTH-1 -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] blend1_s1 = pipe_s1_dout[PIPE_S1_WIDTH-1-SIGNED_WIDTH -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] avg0_u_s1 = pipe_s1_dout[PIPE_S1_WIDTH-1-2*SIGNED_WIDTH -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] avg1_u_s1 = pipe_s1_dout[PIPE_S1_WIDTH-1-3*SIGNED_WIDTH -: SIGNED_WIDTH];
    wire [DATA_WIDTH-1:0]     center_s1 = pipe_s1_dout[LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 8 + 3 + 3 + 1 +: DATA_WIDTH];
    wire [7:0]                ratio_s1  = pipe_s1_dout[LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 3 + 3 + 1 +: 8];
    wire [2:0]                factor_s1 = pipe_s1_dout[LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 3 + 1 +: 3];
    wire [2:0]                remain_s1 = pipe_s1_dout[LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 1 +: 3];
    wire [LINE_ADDR_WIDTH-1:0] pixel_x_s1 = pipe_s1_dout[ROW_CNT_WIDTH + 1 +: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0]  pixel_y_s1 = pipe_s1_dout[1 +: ROW_CNT_WIDTH];

    //=========================================================================
    // Cycle 2: IIR Mixing (Signed Arithmetic)
    //=========================================================================
    // IIR blend: ratio * current + (64 - ratio) * previous / 64
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

    //=========================================================================
    // Cycle 2 Pipeline Registers
    //=========================================================================
    localparam PIPE_S2_WIDTH = 2 * SIGNED_WIDTH + DATA_WIDTH + 3 + 3 + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 1;

    wire [PIPE_S2_WIDTH-1:0] pipe_s2_din = {blend0_iir_sat, blend1_iir_sat, center_s1, factor_s1, remain_s1,
                                            pixel_x_s1, pixel_y_s1, valid_s1};

    wire [PIPE_S2_WIDTH-1:0] pipe_s2_dout;
    wire                     valid_s2;

    common_pipe #(
        .DATA_WIDTH (PIPE_S2_WIDTH),
        .STAGES     (1),
        .RESET_VAL  (0)
    ) u_pipe_s2 (
        .clk       (clk),
        .rst_n     (rst_n),
        .din       (pipe_s2_din),
        .valid_in  (valid_s1),
        .ready_out (),
        .dout      (pipe_s2_dout),
        .valid_out (valid_s2),
        .ready_in  (dout_ready)
    );

    // Unpack signals
    wire signed [SIGNED_WIDTH-1:0] blend0_iir_s2 = pipe_s2_dout[PIPE_S2_WIDTH-1 -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] blend1_iir_s2 = pipe_s2_dout[PIPE_S2_WIDTH-1-SIGNED_WIDTH -: SIGNED_WIDTH];
    wire [DATA_WIDTH-1:0] center_s2 = pipe_s2_dout[ROW_CNT_WIDTH + LINE_ADDR_WIDTH + 3 + 3 + 1 +: DATA_WIDTH];
    wire [2:0]            factor_s2 = pipe_s2_dout[ROW_CNT_WIDTH + LINE_ADDR_WIDTH + 3 + 1 +: 3];
    wire [2:0]            remain_s2 = pipe_s2_dout[ROW_CNT_WIDTH + LINE_ADDR_WIDTH + 1 +: 3];
    wire [LINE_ADDR_WIDTH-1:0] pixel_x_s2 = pipe_s2_dout[ROW_CNT_WIDTH + 1 +: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0]  pixel_y_s2 = pipe_s2_dout[1 +: ROW_CNT_WIDTH];

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

    //=========================================================================
    // Cycle 3 Pipeline Registers
    //=========================================================================
    localparam PIPE_S3_WIDTH = 2 * SIGNED_WIDTH + 3 + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 1;

    wire [PIPE_S3_WIDTH-1:0] pipe_s3_din = {blend0_out_sat, blend1_out_sat, remain_s2,
                                            pixel_x_s2, pixel_y_s2, valid_s2};

    wire [PIPE_S3_WIDTH-1:0] pipe_s3_dout;
    wire                     valid_s3;

    common_pipe #(
        .DATA_WIDTH (PIPE_S3_WIDTH),
        .STAGES     (1),
        .RESET_VAL  (0)
    ) u_pipe_s3 (
        .clk       (clk),
        .rst_n     (rst_n),
        .din       (pipe_s3_din),
        .valid_in  (valid_s2),
        .ready_out (),
        .dout      (pipe_s3_dout),
        .valid_out (valid_s3),
        .ready_in  (dout_ready)
    );

    // Unpack signals
    wire signed [SIGNED_WIDTH-1:0] blend0_out_s3 = pipe_s3_dout[PIPE_S3_WIDTH-1 -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] blend1_out_s3 = pipe_s3_dout[PIPE_S3_WIDTH-1-SIGNED_WIDTH -: SIGNED_WIDTH];
    wire [2:0]            remain_s3 = pipe_s3_dout[ROW_CNT_WIDTH + LINE_ADDR_WIDTH + 1 +: 3];
    wire [LINE_ADDR_WIDTH-1:0] pixel_x_s3 = pipe_s3_dout[ROW_CNT_WIDTH + 1 +: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0]  pixel_y_s3 = pipe_s3_dout[1 +: ROW_CNT_WIDTH];

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
    wire [11:0] temp_unsigned = $signed(blend_final_sat) + $signed(12'sd512);

    wire [DATA_WIDTH-1:0] dout_sat;
    assign dout_sat = (temp_unsigned[11]) ? 10'd0 :
                      (temp_unsigned > 12'd1023) ? 10'd1023 :
                      temp_unsigned[DATA_WIDTH-1:0];

    //=========================================================================
    // Output Registers
    //=========================================================================
    localparam PIPE_OUT_WIDTH = DATA_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 1;

    wire [PIPE_OUT_WIDTH-1:0] pipe_out_din = {dout_sat, pixel_x_s3, pixel_y_s3, valid_s3};

    wire [PIPE_OUT_WIDTH-1:0] pipe_out_dout;

    common_pipe #(
        .DATA_WIDTH (PIPE_OUT_WIDTH),
        .STAGES     (1),
        .RESET_VAL  (0)
    ) u_pipe_out (
        .clk       (clk),
        .rst_n     (rst_n),
        .din       (pipe_out_din),
        .valid_in  (valid_s3),
        .ready_out (),
        .dout      (pipe_out_dout),
        .valid_out (dout_valid),
        .ready_in  (dout_ready)
    );

    // Unpack output signals
    assign dout        = pipe_out_dout[PIPE_OUT_WIDTH-1 -: DATA_WIDTH];
    assign pixel_x_out = pipe_out_dout[ROW_CNT_WIDTH + 1 +: LINE_ADDR_WIDTH];
    assign pixel_y_out = pipe_out_dout[1 +: ROW_CNT_WIDTH];

    // Line buffer writeback
    assign lb_wb_en   = dout_valid;
    assign lb_wb_addr = pixel_x_out;
    assign lb_wb_data = dout;

endmodule