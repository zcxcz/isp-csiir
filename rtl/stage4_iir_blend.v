//-----------------------------------------------------------------------------
// Module: stage4_iir_blend
// Purpose: IIR filtering, patch blending, and final output generation
// Author: rtl-impl
// Date: 2026-03-24
// Version: v3.1 - Patch-level mix aligned to reference semantics
//-----------------------------------------------------------------------------

module stage4_iir_blend #(
    parameter DATA_WIDTH      = 10,
    parameter SIGNED_WIDTH    = 11,
    parameter GRAD_WIDTH      = 14,
    parameter WIN_SIZE_WIDTH  = 6,
    parameter LINE_ADDR_WIDTH = 14,
    parameter ROW_CNT_WIDTH   = 13
)(
    input  wire                             clk,
    input  wire                             rst_n,
    input  wire                             enable,

    // Stage 3 outputs (s11 signed format)
    input  wire signed [SIGNED_WIDTH-1:0]   blend0_dir_avg,
    input  wire signed [SIGNED_WIDTH-1:0]   blend1_dir_avg,
    input  wire                             stage3_valid,
    input  wire signed [SIGNED_WIDTH-1:0]   avg0_u,
    input  wire signed [SIGNED_WIDTH-1:0]   avg1_u,
    input  wire [WIN_SIZE_WIDTH-1:0]        win_size_clip,
    input  wire [DATA_WIDTH*25-1:0]         src_patch_5x5,
    input  wire [GRAD_WIDTH-1:0]            grad_h,
    input  wire [GRAD_WIDTH-1:0]            grad_v,
    input  wire [7:0]                       reg_edge_protect,
    input  wire [DATA_WIDTH-1:0]            center_pixel,
    output wire                             stage3_ready,

    // Configuration
    input  wire [7:0]                       blending_ratio_0,
    input  wire [7:0]                       blending_ratio_1,
    input  wire [7:0]                       blending_ratio_2,
    input  wire [7:0]                       blending_ratio_3,

    // Output (u10 unsigned format)
    output wire [DATA_WIDTH-1:0]            dout,
    output wire                             dout_valid,
    input  wire                             dout_ready,

    // Position info
    input  wire [LINE_ADDR_WIDTH-1:0]       pixel_x,
    input  wire [ROW_CNT_WIDTH-1:0]         pixel_y,
    output wire [LINE_ADDR_WIDTH-1:0]       pixel_x_out,
    output wire [ROW_CNT_WIDTH-1:0]         pixel_y_out,

    // Patch feedback interface
    output wire                             patch_valid,
    input  wire                             patch_ready,
    output wire [LINE_ADDR_WIDTH-1:0]       patch_center_x,
    output wire [ROW_CNT_WIDTH-1:0]         patch_center_y,
    output wire [DATA_WIDTH*25-1:0]         patch_5x5,

    // Line buffer writeback interface (for IIR feedback)
    output wire                             lb_wb_en,
    output wire [LINE_ADDR_WIDTH-1:0]       lb_wb_addr,
    output wire [DATA_WIDTH-1:0]            lb_wb_data
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam IIR_WIDTH          = SIGNED_WIDTH + 7;
    localparam PATCH_WIDTH        = DATA_WIDTH * 25;
    localparam PATCH_BUCKET_WIDTH = 3;
    localparam PATCH_CENTER_LSB   = 12 * DATA_WIDTH;

    //=========================================================================
    // Helper Functions
    //=========================================================================
    function [2:0] factor_2x2_h;
        input integer idx;
        begin
            case (idx)
                11, 12, 13: factor_2x2_h = 3'd1;
                default:    factor_2x2_h = 3'd0;
            endcase
        end
    endfunction

    function [2:0] factor_2x2_v;
        input integer idx;
        begin
            case (idx)
                7, 12, 17: factor_2x2_v = 3'd1;
                default:   factor_2x2_v = 3'd0;
            endcase
        end
    endfunction

    function [2:0] factor_2x2;
        input integer idx;
        begin
            case (idx)
                6, 8, 16, 18: factor_2x2 = 3'd1;
                7, 11, 13, 17: factor_2x2 = 3'd2;
                12:            factor_2x2 = 3'd4;
                default:       factor_2x2 = 3'd0;
            endcase
        end
    endfunction

    function [2:0] factor_3x3;
        input integer idx;
        begin
            case (idx)
                6, 7, 8, 11, 12, 13, 16, 17, 18: factor_3x3 = 3'd1;
                default:                         factor_3x3 = 3'd0;
            endcase
        end
    endfunction

    function [2:0] factor_4x4;
        input integer idx;
        begin
            case (idx)
                0, 4, 20, 24: factor_4x4 = 3'd1;
                1, 2, 3, 5, 9, 10, 14, 15, 19, 21, 22, 23: factor_4x4 = 3'd2;
                default:      factor_4x4 = 3'd4;
            endcase
        end
    endfunction

    function [2:0] factor_5x5;
        input integer idx;
        begin
            factor_5x5 = 3'd4;
        end
    endfunction

    function signed [24:0] round_div_pow2;
        input signed [24:0] value;
        input [2:0] shift;
        reg [24:0] abs_value;
        reg [24:0] bias;
        begin
            bias = 25'd1 << (shift - 1'b1);
            if (value >= 0)
                round_div_pow2 = (value + $signed(bias)) >>> shift;
            else begin
                abs_value = -value;
                round_div_pow2 = -$signed((abs_value + bias) >> shift);
            end
        end
    endfunction

    function signed [SIGNED_WIDTH-1:0] sat_s11;
        input signed [24:0] value;
        begin
            if (value > $signed(25'sd511))
                sat_s11 = $signed(11'sd511);
            else if (value < $signed(-25'sd512))
                sat_s11 = $signed(-11'sd512);
            else
                sat_s11 = value[SIGNED_WIDTH-1:0];
        end
    endfunction

    function [DATA_WIDTH-1:0] s11_to_u10;
        input signed [SIGNED_WIDTH-1:0] value;
        reg signed [11:0] unsigned_temp;
        begin
            unsigned_temp = value + $signed(12'sd512);
            if (unsigned_temp < 0)
                s11_to_u10 = 10'd0;
            else if (unsigned_temp > 12'sd1023)
                s11_to_u10 = 10'd1023;
            else
                s11_to_u10 = unsigned_temp[DATA_WIDTH-1:0];
        end
    endfunction

    function signed [SIGNED_WIDTH-1:0] mix_scalar_patch_s11;
        input signed [SIGNED_WIDTH-1:0] scalar;
        input signed [SIGNED_WIDTH-1:0] src_cell;
        input [2:0] factor;
        reg [3:0] inv_factor;
        reg signed [24:0] numer;
        begin
            inv_factor = 4'd4 - {1'b0, factor};
            numer = scalar * $signed({1'b0, factor}) + src_cell * $signed(inv_factor);
            mix_scalar_patch_s11 = sat_s11(round_div_pow2(numer, 3'd2));
        end
    endfunction

    function signed [SIGNED_WIDTH-1:0] mix_edge_protect_s11;
        input signed [SIGNED_WIDTH-1:0] a;
        input signed [SIGNED_WIDTH-1:0] b;
        input [7:0] edge_protect;
        reg [8:0] inv_edge;
        reg signed [24:0] numer;
        begin
            inv_edge = 9'd64 - {1'b0, edge_protect};
            numer = a * $signed({1'b0, edge_protect}) + b * $signed(inv_edge);
            mix_edge_protect_s11 = sat_s11(round_div_pow2(numer, 3'd6));
        end
    endfunction

    function signed [SIGNED_WIDTH-1:0] mix_remain_s11;
        input signed [SIGNED_WIDTH-1:0] a;
        input signed [SIGNED_WIDTH-1:0] b;
        input [2:0] remain;
        reg [4:0] inv_remain;
        reg signed [24:0] numer;
        begin
            inv_remain = 5'd8 - {2'b00, remain};
            numer = a * $signed({1'b0, remain}) + b * $signed(inv_remain);
            mix_remain_s11 = sat_s11(round_div_pow2(numer, 3'd3));
        end
    endfunction

    //=========================================================================
    // Ready Signal
    //=========================================================================
    wire consumer_ready;
    wire stage4_ready;

    assign consumer_ready = dout_ready && patch_ready;
    assign stage4_ready   = consumer_ready;
    assign stage3_ready   = stage4_ready;

    //=========================================================================
    // Cycle 0: Input Buffer
    //=========================================================================
    localparam PIPE_S0_WIDTH = PATCH_WIDTH + 2 * GRAD_WIDTH + 4 * SIGNED_WIDTH + DATA_WIDTH +
                               WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 1;

    wire [PIPE_S0_WIDTH-1:0] pipe_s0_din = {src_patch_5x5, grad_h, grad_v,
                                            blend0_dir_avg, blend1_dir_avg, avg0_u, avg1_u,
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
        .ready_in  (stage4_ready)
    );

    wire [PATCH_WIDTH-1:0] src_patch_s0 = pipe_s0_dout[PIPE_S0_WIDTH-1 -: PATCH_WIDTH];
    wire [GRAD_WIDTH-1:0] grad_h_s0 = pipe_s0_dout[PIPE_S0_WIDTH-1-PATCH_WIDTH -: GRAD_WIDTH];
    wire [GRAD_WIDTH-1:0] grad_v_s0 = pipe_s0_dout[PIPE_S0_WIDTH-1-PATCH_WIDTH-GRAD_WIDTH -: GRAD_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] blend0_s0 = pipe_s0_dout[PIPE_S0_WIDTH-1-PATCH_WIDTH-2*GRAD_WIDTH -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] blend1_s0 = pipe_s0_dout[PIPE_S0_WIDTH-1-PATCH_WIDTH-2*GRAD_WIDTH-SIGNED_WIDTH -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] avg0_u_s0 = pipe_s0_dout[PIPE_S0_WIDTH-1-PATCH_WIDTH-2*GRAD_WIDTH-2*SIGNED_WIDTH -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] avg1_u_s0 = pipe_s0_dout[PIPE_S0_WIDTH-1-PATCH_WIDTH-2*GRAD_WIDTH-3*SIGNED_WIDTH -: SIGNED_WIDTH];
    wire [DATA_WIDTH-1:0]     center_s0 = pipe_s0_dout[ROW_CNT_WIDTH + LINE_ADDR_WIDTH + WIN_SIZE_WIDTH + 1 +: DATA_WIDTH];
    wire [WIN_SIZE_WIDTH-1:0] win_size_s0 = pipe_s0_dout[ROW_CNT_WIDTH + LINE_ADDR_WIDTH + 1 +: WIN_SIZE_WIDTH];
    wire [LINE_ADDR_WIDTH-1:0] pixel_x_s0 = pipe_s0_dout[ROW_CNT_WIDTH + 1 +: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0]  pixel_y_s0 = pipe_s0_dout[1 +: ROW_CNT_WIDTH];

    //=========================================================================
    // Cycle 1: Ratio Selection
    //=========================================================================
    wire [2:0] ratio_idx_comb;
    assign ratio_idx_comb = (win_size_s0 < 6'd24) ? 3'd0 :
                            (win_size_s0 < 6'd32) ? 3'd1 :
                            (win_size_s0 < 6'd40) ? 3'd2 : 3'd3;

    wire [7:0] blend_ratio_comb = (ratio_idx_comb == 0) ? blending_ratio_0 :
                                  (ratio_idx_comb == 1) ? blending_ratio_1 :
                                  (ratio_idx_comb == 2) ? blending_ratio_2 : blending_ratio_3;

    wire [2:0] blend_factor_comb = (win_size_s0 >= 6'd32) ? 3'd4 :
                                   (win_size_s0 >= 6'd24) ? 3'd3 :
                                   (win_size_s0 >= 6'd16) ? 3'd2 : 3'd1;

    wire [2:0] patch_bucket_comb = (win_size_s0 < 6'd16) ? 3'd0 :
                                   (win_size_s0 < 6'd24) ? 3'd1 :
                                   (win_size_s0 < 6'd32) ? 3'd2 :
                                   (win_size_s0 < 6'd40) ? 3'd3 : 3'd4;

    wire [2:0] win_remain_comb = win_size_s0[2:0];

    //=========================================================================
    // Cycle 1 Pipeline Registers
    //=========================================================================
    localparam PIPE_S1_WIDTH = PATCH_WIDTH + 2 * GRAD_WIDTH + PATCH_BUCKET_WIDTH +
                               4 * SIGNED_WIDTH + DATA_WIDTH + 8 + 3 + 3 +
                               LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 1;

    wire [PIPE_S1_WIDTH-1:0] pipe_s1_din = {src_patch_s0, grad_h_s0, grad_v_s0, patch_bucket_comb,
                                            blend0_s0, blend1_s0, avg0_u_s0, avg1_u_s0,
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
        .ready_in  (stage4_ready)
    );

    wire [PATCH_WIDTH-1:0] src_patch_s1 = pipe_s1_dout[PIPE_S1_WIDTH-1 -: PATCH_WIDTH];
    wire [GRAD_WIDTH-1:0] grad_h_s1 = pipe_s1_dout[PIPE_S1_WIDTH-1-PATCH_WIDTH -: GRAD_WIDTH];
    wire [GRAD_WIDTH-1:0] grad_v_s1 = pipe_s1_dout[PIPE_S1_WIDTH-1-PATCH_WIDTH-GRAD_WIDTH -: GRAD_WIDTH];
    wire [PATCH_BUCKET_WIDTH-1:0] patch_bucket_s1 = pipe_s1_dout[PIPE_S1_WIDTH-1-PATCH_WIDTH-2*GRAD_WIDTH -: PATCH_BUCKET_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] blend0_s1 = pipe_s1_dout[PIPE_S1_WIDTH-1-PATCH_WIDTH-2*GRAD_WIDTH-PATCH_BUCKET_WIDTH -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] blend1_s1 = pipe_s1_dout[PIPE_S1_WIDTH-1-PATCH_WIDTH-2*GRAD_WIDTH-PATCH_BUCKET_WIDTH-SIGNED_WIDTH -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] avg0_u_s1 = pipe_s1_dout[PIPE_S1_WIDTH-1-PATCH_WIDTH-2*GRAD_WIDTH-PATCH_BUCKET_WIDTH-2*SIGNED_WIDTH -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] avg1_u_s1 = pipe_s1_dout[PIPE_S1_WIDTH-1-PATCH_WIDTH-2*GRAD_WIDTH-PATCH_BUCKET_WIDTH-3*SIGNED_WIDTH -: SIGNED_WIDTH];
    wire [DATA_WIDTH-1:0]     center_s1 = pipe_s1_dout[LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 8 + 3 + 3 + 1 +: DATA_WIDTH];
    wire [7:0]                ratio_s1  = pipe_s1_dout[LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 3 + 3 + 1 +: 8];
    wire [2:0]                factor_s1 = pipe_s1_dout[LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 3 + 1 +: 3];
    wire [2:0]                remain_s1 = pipe_s1_dout[LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 1 +: 3];
    wire [LINE_ADDR_WIDTH-1:0] pixel_x_s1 = pipe_s1_dout[ROW_CNT_WIDTH + 1 +: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0]  pixel_y_s1 = pipe_s1_dout[1 +: ROW_CNT_WIDTH];

    //=========================================================================
    // Cycle 2: IIR Mixing (Signed Arithmetic)
    //=========================================================================
    wire signed [24:0] blend0_iir_numer = $signed(ratio_s1) * blend0_s1 + $signed(9'd64 - {1'b0, ratio_s1}) * avg0_u_s1;
    wire signed [24:0] blend1_iir_numer = $signed(ratio_s1) * blend1_s1 + $signed(9'd64 - {1'b0, ratio_s1}) * avg1_u_s1;

    wire signed [SIGNED_WIDTH-1:0] blend0_iir_sat = sat_s11(round_div_pow2(blend0_iir_numer, 3'd6));
    wire signed [SIGNED_WIDTH-1:0] blend1_iir_sat = sat_s11(round_div_pow2(blend1_iir_numer, 3'd6));

    //=========================================================================
    // Cycle 2 Pipeline Registers
    //=========================================================================
    localparam PIPE_S2_WIDTH = PATCH_WIDTH + 2 * GRAD_WIDTH + PATCH_BUCKET_WIDTH +
                               2 * SIGNED_WIDTH + DATA_WIDTH + 3 + 3 +
                               LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 1;

    wire [PIPE_S2_WIDTH-1:0] pipe_s2_din = {src_patch_s1, grad_h_s1, grad_v_s1, patch_bucket_s1,
                                            blend0_iir_sat, blend1_iir_sat, center_s1, factor_s1, remain_s1,
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
        .ready_in  (stage4_ready)
    );

    wire [PATCH_WIDTH-1:0] src_patch_s2 = pipe_s2_dout[PIPE_S2_WIDTH-1 -: PATCH_WIDTH];
    wire [GRAD_WIDTH-1:0] grad_h_s2 = pipe_s2_dout[PIPE_S2_WIDTH-1-PATCH_WIDTH -: GRAD_WIDTH];
    wire [GRAD_WIDTH-1:0] grad_v_s2 = pipe_s2_dout[PIPE_S2_WIDTH-1-PATCH_WIDTH-GRAD_WIDTH -: GRAD_WIDTH];
    wire [PATCH_BUCKET_WIDTH-1:0] patch_bucket_s2 = pipe_s2_dout[PIPE_S2_WIDTH-1-PATCH_WIDTH-2*GRAD_WIDTH -: PATCH_BUCKET_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] blend0_iir_s2 = pipe_s2_dout[PIPE_S2_WIDTH-1-PATCH_WIDTH-2*GRAD_WIDTH-PATCH_BUCKET_WIDTH -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] blend1_iir_s2 = pipe_s2_dout[PIPE_S2_WIDTH-1-PATCH_WIDTH-2*GRAD_WIDTH-PATCH_BUCKET_WIDTH-SIGNED_WIDTH -: SIGNED_WIDTH];
    wire [DATA_WIDTH-1:0] center_s2 = pipe_s2_dout[ROW_CNT_WIDTH + LINE_ADDR_WIDTH + 3 + 3 + 1 +: DATA_WIDTH];
    wire [2:0]            factor_s2 = pipe_s2_dout[ROW_CNT_WIDTH + LINE_ADDR_WIDTH + 3 + 1 +: 3];
    wire [2:0]            remain_s2 = pipe_s2_dout[ROW_CNT_WIDTH + LINE_ADDR_WIDTH + 1 +: 3];
    wire [LINE_ADDR_WIDTH-1:0] pixel_x_s2 = pipe_s2_dout[ROW_CNT_WIDTH + 1 +: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0]  pixel_y_s2 = pipe_s2_dout[1 +: ROW_CNT_WIDTH];

    // Keep scalar metadata visible for debug/alignment, though final dout is
    // taken from the center of the patch-level result.
    wire [DATA_WIDTH-1:0] unused_center_s2 = center_s2;
    wire [2:0]            unused_factor_s2 = factor_s2;

    //=========================================================================
    // Cycle 3: Patch-Level Window Mixing
    //=========================================================================
    wire orient_is_h_s2 = (grad_v_s2 > grad_h_s2);
    wire [PATCH_WIDTH-1:0] final_patch_u10_s3_comb;

    genvar gi;
    generate
        for (gi = 0; gi < 25; gi = gi + 1) begin : gen_patch_mix
            wire [DATA_WIDTH-1:0] src_cell_u10 = src_patch_s2[gi*DATA_WIDTH +: DATA_WIDTH];
            wire signed [SIGNED_WIDTH-1:0] src_cell_s11 = $signed({1'b0, src_cell_u10}) - $signed(11'sd512);
            wire [2:0] orient_factor_cell = orient_is_h_s2 ? factor_2x2_h(gi) : factor_2x2_v(gi);
            wire [2:0] factor_2x2_cell = factor_2x2(gi);
            wire [2:0] factor_3x3_cell = factor_3x3(gi);
            wire [2:0] factor_4x4_cell = factor_4x4(gi);
            wire [2:0] factor_5x5_cell = factor_5x5(gi);

            wire signed [SIGNED_WIDTH-1:0] blend10_cell = mix_scalar_patch_s11(blend1_iir_s2, src_cell_s11, orient_factor_cell);
            wire signed [SIGNED_WIDTH-1:0] blend11_cell = mix_scalar_patch_s11(blend1_iir_s2, src_cell_s11, factor_2x2_cell);
            wire signed [SIGNED_WIDTH-1:0] blend1_edge_cell = mix_edge_protect_s11(blend10_cell, blend11_cell, reg_edge_protect);

            wire signed [SIGNED_WIDTH-1:0] blend0_3x3_cell = mix_scalar_patch_s11(blend0_iir_s2, src_cell_s11, factor_3x3_cell);
            wire signed [SIGNED_WIDTH-1:0] blend1_3x3_cell = mix_scalar_patch_s11(blend1_iir_s2, src_cell_s11, factor_3x3_cell);
            wire signed [SIGNED_WIDTH-1:0] blend0_4x4_cell = mix_scalar_patch_s11(blend0_iir_s2, src_cell_s11, factor_4x4_cell);
            wire signed [SIGNED_WIDTH-1:0] blend1_4x4_cell = mix_scalar_patch_s11(blend1_iir_s2, src_cell_s11, factor_4x4_cell);
            wire signed [SIGNED_WIDTH-1:0] blend0_5x5_cell = mix_scalar_patch_s11(blend0_iir_s2, src_cell_s11, factor_5x5_cell);

            wire signed [SIGNED_WIDTH-1:0] final_patch_cell_s11 =
                (patch_bucket_s2 == 3'd0) ? blend1_edge_cell :
                (patch_bucket_s2 == 3'd1) ? mix_remain_s11(blend0_3x3_cell, blend1_edge_cell, remain_s2) :
                (patch_bucket_s2 == 3'd2) ? mix_remain_s11(blend0_4x4_cell, blend1_3x3_cell, remain_s2) :
                (patch_bucket_s2 == 3'd3) ? mix_remain_s11(blend0_5x5_cell, blend1_4x4_cell, remain_s2) :
                                            blend0_5x5_cell;

            assign final_patch_u10_s3_comb[gi*DATA_WIDTH +: DATA_WIDTH] = s11_to_u10(final_patch_cell_s11);
        end
    endgenerate

    //=========================================================================
    // Cycle 3 Pipeline Registers
    //=========================================================================
    localparam PIPE_S3_WIDTH = PATCH_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 1;

    wire [PIPE_S3_WIDTH-1:0] pipe_s3_din = {final_patch_u10_s3_comb, pixel_x_s2, pixel_y_s2, valid_s2};
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
        .ready_in  (stage4_ready)
    );

    wire [PATCH_WIDTH-1:0] final_patch_u10_s3 = pipe_s3_dout[PIPE_S3_WIDTH-1 -: PATCH_WIDTH];
    wire [LINE_ADDR_WIDTH-1:0] pixel_x_s3 = pipe_s3_dout[ROW_CNT_WIDTH + 1 +: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0]  pixel_y_s3 = pipe_s3_dout[1 +: ROW_CNT_WIDTH];

    //=========================================================================
    // Output Pipeline
    //=========================================================================
    localparam PIPE_OUT_WIDTH = PATCH_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 1;

    wire [PIPE_OUT_WIDTH-1:0] pipe_out_din = {final_patch_u10_s3, pixel_x_s3, pixel_y_s3, valid_s3};
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
        .valid_out (),
        .ready_in  (stage4_ready)
    );

    //=========================================================================
    // Outputs
    //=========================================================================
    assign patch_5x5      = pipe_out_dout[PIPE_OUT_WIDTH-1 -: PATCH_WIDTH];
    assign pixel_x_out    = pipe_out_dout[ROW_CNT_WIDTH + 1 +: LINE_ADDR_WIDTH];
    assign pixel_y_out    = pipe_out_dout[1 +: ROW_CNT_WIDTH];
    assign dout_valid     = pipe_out_dout[0];
    assign patch_valid    = pipe_out_dout[0];
    assign patch_center_x = pixel_x_out;
    assign patch_center_y = pixel_y_out;
    assign dout           = patch_5x5[PATCH_CENTER_LSB +: DATA_WIDTH];

    // Line buffer writeback commits only on atomic accept.
    assign lb_wb_en   = dout_valid && consumer_ready;
    assign lb_wb_addr = pixel_x_out;
    assign lb_wb_data = dout;

endmodule
