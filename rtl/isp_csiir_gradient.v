//-----------------------------------------------------------------------------
// Module: isp_csiir_gradient
// Purpose: Gradient calculation and window size determination
// Author: rtl-impl
// Date: 2026-04-12
// Version: v5.0 - Column-based interface with internal patch assembly
//-----------------------------------------------------------------------------
// Description:
//   Gradient calculation module with column-based data interface:
//   - Receives 5x1 column stream from line buffer
//   - Builds 5x5 window internally using patch assembler
//   - Outputs column stream (for downstream stages) + computed results
//
// Interface Convention:
//   - Column input: col_0 through col_4 (5x1 vertical pixels)
//   - Column output: out_col_0 through out_col_4 (5x1 delayed pixels)
//   - Computed results: grad_h, grad_v, grad, win_size_clip
//
// Pipeline Structure (5 cycles):
//   Cycle 0: Sobel row/column sum (combinational + register)
//   Cycle 1: Pipeline delay for row/column sums
//   Cycle 2: Gradient difference and absolute value
//   Cycle 3: Gradient maximum finding
//   Cycle 4: Window size LUT
//
// Handshake Protocol:
//   - din_valid/din_ready: Input handshake
//   - dout_valid/dout_ready: Output handshake
//-----------------------------------------------------------------------------

module isp_csiir_gradient #(
    parameter IMG_WIDTH        = 5472,
    parameter DATA_WIDTH      = 10,
    parameter GRAD_WIDTH      = 14,
    parameter WIN_SIZE_WIDTH  = 6,
    parameter LINE_ADDR_WIDTH = 14,
    parameter ROW_CNT_WIDTH   = 13
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // Column input (from line buffer)
    input  wire [DATA_WIDTH-1:0]      col_0,
    input  wire [DATA_WIDTH-1:0]      col_1,
    input  wire [DATA_WIDTH-1:0]      col_2,
    input  wire [DATA_WIDTH-1:0]      col_3,
    input  wire [DATA_WIDTH-1:0]      col_4,
    input  wire                        column_valid,
    output wire                        column_ready,
    input  wire [LINE_ADDR_WIDTH-1:0]  center_x,
    input  wire [ROW_CNT_WIDTH-1:0]    center_y,
    input  wire [LINE_ADDR_WIDTH-1:0]  img_width,

    // Configuration parameters
    input  wire [DATA_WIDTH-1:0]     win_size_clip_y_0,
    input  wire [DATA_WIDTH-1:0]     win_size_clip_y_1,
    input  wire [DATA_WIDTH-1:0]     win_size_clip_y_2,
    input  wire [DATA_WIDTH-1:0]     win_size_clip_y_3,
    input  wire [7:0]                 win_size_clip_sft_0,
    input  wire [7:0]                 win_size_clip_sft_1,
    input  wire [7:0]                 win_size_clip_sft_2,
    input  wire [7:0]                 win_size_clip_sft_3,

    // Output (computed results)
    output wire [GRAD_WIDTH-1:0]       grad_h,
    output wire [GRAD_WIDTH-1:0]       grad_v,
    output wire [GRAD_WIDTH-1:0]       grad,
    output wire [WIN_SIZE_WIDTH-1:0]   win_size_clip,
    output wire [DATA_WIDTH-1:0]       center_pixel,
    output wire                        dout_valid,
    input  wire                        dout_ready,

    // Position info
    output wire [LINE_ADDR_WIDTH-1:0]  pixel_x_out,
    output wire [ROW_CNT_WIDTH-1:0]    pixel_y_out,

    // Column output (for downstream stages - 5 cycles delayed)
    output wire [DATA_WIDTH-1:0]      out_col_0,
    output wire [DATA_WIDTH-1:0]      out_col_1,
    output wire [DATA_WIDTH-1:0]      out_col_2,
    output wire [DATA_WIDTH-1:0]      out_col_3,
    output wire [DATA_WIDTH-1:0]      out_col_4
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam ROW_SUM_WIDTH = DATA_WIDTH + 3;  // 13-bit for 5 pixels sum
    localparam LUT_X_WIDTH   = GRAD_WIDTH + 1;
    localparam LUT_Y_WIDTH   = DATA_WIDTH + 1;
    localparam LUT_MUL_WIDTH = LUT_X_WIDTH + DATA_WIDTH + 2;
    localparam PIPE_S0_WIDTH = 4 * ROW_SUM_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1;
    localparam PIPE_S1_WIDTH = 4 * ROW_SUM_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1;
    localparam PIPE_S2_WIDTH = 3 * GRAD_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1;
    localparam PIPE_S3_WIDTH = 4 * GRAD_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1;

    function [LUT_Y_WIDTH-1:0] lut_interp_round;
        input [LUT_X_WIDTH-1:0] x;
        input [LUT_X_WIDTH-1:0] x0;
        input [LUT_X_WIDTH-1:0] x1;
        input [DATA_WIDTH-1:0]  y0;
        input [DATA_WIDTH-1:0]  y1;
        reg [LUT_MUL_WIDTH-1:0] numer;
        reg [LUT_X_WIDTH-1:0]   denom;
        reg [DATA_WIDTH:0]      y_delta;
        begin
            if (x1 <= x0) begin
                lut_interp_round = {1'b0, y1};
            end else begin
                denom = x1 - x0;
                y_delta = {1'b0, y1} - {1'b0, y0};
                numer = (x - x0) * y_delta + (denom >> 1);
                lut_interp_round = {1'b0, y0} + (numer / denom);
            end
        end
    endfunction

    //=========================================================================
    // Internal Signal Declaration
    //=========================================================================
    // Pipeline stage valid signals
    wire                      pipe_s0_din_valid;
    wire                      pipe_s0_din_ready;
    wire                      pipe_s0_dout_valid;
    wire                      pipe_s0_dout_ready;
    wire                      pipe_s0_din_shake;

    wire                      pipe_s1_din_valid;
    wire                      pipe_s1_din_ready;
    wire                      pipe_s1_dout_valid;
    wire                      pipe_s1_dout_ready;
    wire                      pipe_s1_din_shake;

    wire                      pipe_s2_din_valid;
    wire                      pipe_s2_din_ready;
    wire                      pipe_s2_dout_valid;
    wire                      pipe_s2_dout_ready;
    wire                      pipe_s2_din_shake;

    wire                      pipe_s3_din_valid;
    wire                      pipe_s3_din_ready;
    wire                      pipe_s3_dout_valid;
    wire                      pipe_s3_dout_ready;
    wire                      pipe_s3_din_shake;

    // Output stage signals
    wire                      pipe_out_din_valid;
    wire                      pipe_out_din_ready;
    wire                      pipe_out_dout_valid;
    wire                      pipe_out_dout_ready;
    wire                      pipe_out_din_shake;

    //=========================================================================
    // Patch Assembler Internal Signals
    //=========================================================================
    // 5x5 window assembled from column input
    wire [DATA_WIDTH-1:0]    patch_window_0_0, patch_window_0_1, patch_window_0_2, patch_window_0_3, patch_window_0_4;
    wire [DATA_WIDTH-1:0]    patch_window_1_0, patch_window_1_1, patch_window_1_2, patch_window_1_3, patch_window_1_4;
    wire [DATA_WIDTH-1:0]    patch_window_2_0, patch_window_2_1, patch_window_2_2, patch_window_2_3, patch_window_2_4;
    wire [DATA_WIDTH-1:0]    patch_window_3_0, patch_window_3_1, patch_window_3_2, patch_window_3_3, patch_window_3_4;
    wire [DATA_WIDTH-1:0]    patch_window_4_0, patch_window_4_1, patch_window_4_2, patch_window_4_3, patch_window_4_4;
    wire                      patch_valid;
    wire                      patch_ready;

    //=========================================================================
    // Column Delay Line (5x1 shift register, 5 stages deep)
    //=========================================================================
    // Using common_delay_matrix for reusable column delay
    wire [DATA_WIDTH*5-1:0] col_din_flat;
    wire [DATA_WIDTH*5-1:0] col_dout_flat;

    assign col_din_flat = {col_4, col_3, col_2, col_1, col_0};

    common_delay_matrix #(
        .DATA_WIDTH (DATA_WIDTH),
        .NUM_COLS   (5),
        .STAGES     (5)
    ) u_col_delay (
        .clk     (clk),
        .rst_n   (rst_n),
        .enable  (enable && pipe_out_din_ready),
        .din_flat (col_din_flat),
        .dout_flat (col_dout_flat),
        .tap_flat ()
    );

    // Column output assignments (stage 4 = last stage)
    assign {out_col_4, out_col_3, out_col_2, out_col_1, out_col_0} = col_dout_flat;

    //=========================================================================
    // Pipe Stage 0: Sobel row/column sum
    //=========================================================================
    // comb: Sobel row sums
    wire [ROW_SUM_WIDTH-1:0] row0_sum_comb;
    wire [ROW_SUM_WIDTH-1:0] row4_sum_comb;
    // comb: Sobel column sums
    wire [ROW_SUM_WIDTH-1:0] col0_sum_comb;
    wire [ROW_SUM_WIDTH-1:0] col4_sum_comb;
    // pack/unpack
    wire [PIPE_S0_WIDTH-1:0] pipe_s0_din;
    wire [PIPE_S0_WIDTH-1:0] pipe_s0_dout;
    wire [ROW_SUM_WIDTH-1:0] row0_sum_s0;
    wire [ROW_SUM_WIDTH-1:0] row4_sum_s0;
    wire [ROW_SUM_WIDTH-1:0] col0_sum_s0;
    wire [ROW_SUM_WIDTH-1:0] col4_sum_s0;
    wire [LINE_ADDR_WIDTH-1:0] pixel_x_s0;
    wire [ROW_CNT_WIDTH-1:0]   pixel_y_s0;
    wire [DATA_WIDTH-1:0]     center_s0;

    //=========================================================================
    // Pipe Stage 1: row/column sum delay
    //=========================================================================
    // pack/unpack
    wire [PIPE_S1_WIDTH-1:0] pipe_s1_din;
    wire [PIPE_S1_WIDTH-1:0] pipe_s1_dout;
    wire [ROW_SUM_WIDTH-1:0] row0_sum_s1;
    wire [ROW_SUM_WIDTH-1:0] row4_sum_s1;
    wire [ROW_SUM_WIDTH-1:0] col0_sum_s1;
    wire [ROW_SUM_WIDTH-1:0] col4_sum_s1;
    wire [LINE_ADDR_WIDTH-1:0] pixel_x_s1;
    wire [ROW_CNT_WIDTH-1:0]   pixel_y_s1;
    wire [DATA_WIDTH-1:0]     center_s1;

    //=========================================================================
    // Pipe Stage 2: gradient diff/abs and neighbor tracking
    //=========================================================================
    // comb: Sobel gradient difference
    wire signed [GRAD_WIDTH-1:0] grad_h_raw_comb;
    wire signed [GRAD_WIDTH-1:0] grad_v_raw_comb;
    // comb: absolute value
    wire [GRAD_WIDTH-1:0] grad_h_abs_comb;
    wire [GRAD_WIDTH-1:0] grad_v_abs_comb;
    // comb: gradient magnitude
    wire [GRAD_WIDTH-1:0] grad_h_div5_comb;
    wire [GRAD_WIDTH-1:0] grad_v_div5_comb;
    wire [GRAD_WIDTH:0]   grad_sum_full;
    wire                  grad_sum_overflow;
    wire [GRAD_WIDTH-1:0] grad_sum_comb;
    // gradient shift register (2-stage for neighbor tracking)
    // Using always block - timing critical, requires simultaneous update
    reg  [GRAD_WIDTH-1:0] grad_l_reg;
    reg  [GRAD_WIDTH-1:0] grad_r_reg;
    // pack/unpack
    wire [PIPE_S2_WIDTH-1:0] pipe_s2_din;
    wire [PIPE_S2_WIDTH-1:0] pipe_s2_dout;
    wire [GRAD_WIDTH-1:0] grad_h_abs_s2;
    wire [GRAD_WIDTH-1:0] grad_v_abs_s2;
    wire [GRAD_WIDTH-1:0] grad_sum_s2;
    wire [LINE_ADDR_WIDTH-1:0] pixel_x_s2;
    wire [ROW_CNT_WIDTH-1:0]   pixel_y_s2;
    wire [DATA_WIDTH-1:0]      center_s2;

    //=========================================================================
    // Pipe Stage 3: gradient max finding
    //=========================================================================
    // comb: gradient maximum (neighbor tracking)
    wire [GRAD_WIDTH-1:0] max_0_1;
    wire [GRAD_WIDTH-1:0] grad_max_comb;
    // pack/unpack
    wire [PIPE_S3_WIDTH-1:0] pipe_s3_din;
    wire [PIPE_S3_WIDTH-1:0] pipe_s3_dout;
    wire [GRAD_WIDTH-1:0] grad_max_s3;
    wire [GRAD_WIDTH-1:0] grad_sum_s3;
    wire [GRAD_WIDTH-1:0] grad_h_abs_s3;
    wire [GRAD_WIDTH-1:0] grad_v_abs_s3;
    wire [LINE_ADDR_WIDTH-1:0] pixel_x_s3;
    wire [ROW_CNT_WIDTH-1:0]   pixel_y_s3;
    wire [DATA_WIDTH-1:0]     center_s3;

    //=========================================================================
    // Pipe Stage Out: window size LUT
    //=========================================================================
    // comb: gradient max extension for LUT
    wire [LUT_X_WIDTH-1:0] grad_max_ext;
    wire [LUT_X_WIDTH-1:0] lut_x0;
    wire [LUT_X_WIDTH-1:0] lut_x1;
    wire [LUT_X_WIDTH-1:0] lut_x2;
    wire [LUT_X_WIDTH-1:0] lut_x3;
    // comb: window size interpolation
    wire [LUT_Y_WIDTH-1:0] win_size_grad_comb;
    // comb: window size clipping
    wire [WIN_SIZE_WIDTH-1:0] win_size_comb;
    // pack/unpack
    localparam PIPE_OUT_WIDTH = 3 * GRAD_WIDTH + WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1;
    wire [PIPE_OUT_WIDTH-1:0] pipe_out_din;
    wire [PIPE_OUT_WIDTH-1:0] pipe_out_dout;

    //=========================================================================
    // Backpressure Propagation
    //=========================================================================
    // column_ready: from pipe_s0 input (backpressure starts here)
    assign column_ready = pipe_s0_din_ready;

    //=========================================================================
    // Internal Patch Assembler (reusable module)
    //=========================================================================
    isp_csiir_patch_assembler_5x5 #(
        .IMG_WIDTH       (IMG_WIDTH),
        .DATA_WIDTH      (DATA_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH)
    ) u_patch_assembler (
        .clk             (clk),
        .rst_n           (rst_n),
        .enable          (enable),
        .img_width       (img_width),
        .col_0           (col_0),
        .col_1           (col_1),
        .col_2           (col_2),
        .col_3           (col_3),
        .col_4           (col_4),
        .column_valid    (column_valid),
        .column_ready    (column_ready),
        .column_issue_allow (1'b1),
        .center_x        (center_x),
        .center_y        (center_y),
        .window_0_0      (patch_window_0_0),
        .window_0_1      (patch_window_0_1),
        .window_0_2      (patch_window_0_2),
        .window_0_3      (patch_window_0_3),
        .window_0_4      (patch_window_0_4),
        .window_1_0      (patch_window_1_0),
        .window_1_1      (patch_window_1_1),
        .window_1_2      (patch_window_1_2),
        .window_1_3      (patch_window_1_3),
        .window_1_4      (patch_window_1_4),
        .window_2_0      (patch_window_2_0),
        .window_2_1      (patch_window_2_1),
        .window_2_2      (patch_window_2_2),
        .window_2_3      (patch_window_2_3),
        .window_2_4      (patch_window_2_4),
        .window_3_0      (patch_window_3_0),
        .window_3_1      (patch_window_3_1),
        .window_3_2      (patch_window_3_2),
        .window_3_3      (patch_window_3_3),
        .window_3_4      (patch_window_3_4),
        .window_4_0      (patch_window_4_0),
        .window_4_1      (patch_window_4_1),
        .window_4_2      (patch_window_4_2),
        .window_4_3      (patch_window_4_3),
        .window_4_4      (patch_window_4_4),
        .window_valid    (patch_valid),
        .window_ready    (patch_ready),
        .patch_center_x  (),
        .patch_center_y  (),
        .patch_5x5       ()
    );

    assign patch_ready = pipe_s0_din_ready;

    //=========================================================================
    ////// pipe stage 0: Sobel row/column sum
    //=========================================================================
    // comb: Sobel row sums (using patched window)
    assign row0_sum_comb = patch_window_0_0 + patch_window_0_1 + patch_window_0_2 + patch_window_0_3 + patch_window_0_4;
    assign row4_sum_comb = patch_window_4_0 + patch_window_4_1 + patch_window_4_2 + patch_window_4_3 + patch_window_4_4;

    // comb: Sobel column sums
    assign col0_sum_comb = patch_window_0_0 + patch_window_1_0 + patch_window_2_0 + patch_window_3_0 + patch_window_4_0;
    assign col4_sum_comb = patch_window_0_4 + patch_window_1_4 + patch_window_2_4 + patch_window_3_4 + patch_window_4_4;

    //=========================================================================
    ////// pipe stage 0: pack and pipeline
    //=========================================================================
    // din_valid: from patch_valid
    assign pipe_s0_din_valid = patch_valid;
    // din_ready: from pipe_s1 (backpressure propagation)
    assign pipe_s0_din_ready = pipe_s1_din_ready;
    // din_shake: handshake indicator
    assign pipe_s0_din_shake = pipe_s0_din_valid & pipe_s0_din_ready;
    // data pack for pipeline register input
    assign pipe_s0_din = {row0_sum_comb, row4_sum_comb, col0_sum_comb, col4_sum_comb,
                          center_x, center_y, patch_window_2_2, pipe_s0_din_valid};
    // dout_ready: from pipe_s1
    assign pipe_s0_dout_ready = pipe_s1_din_ready;

    common_pipe_slice #(
        .DATA_WIDTH (PIPE_S0_WIDTH),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_s0 (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_s0_din),
        .din_valid  (pipe_s0_din_valid),
        .din_ready  (pipe_s0_din_ready),
        .dout       (pipe_s0_dout),
        .dout_valid (pipe_s0_dout_valid),
        .dout_ready (pipe_s0_dout_ready)
    );

    // data unpack from pipe_s0 output
    assign row0_sum_s0 = pipe_s0_dout[PIPE_S0_WIDTH-1 -: ROW_SUM_WIDTH];
    assign row4_sum_s0 = pipe_s0_dout[PIPE_S0_WIDTH-1-ROW_SUM_WIDTH -: ROW_SUM_WIDTH];
    assign col0_sum_s0 = pipe_s0_dout[PIPE_S0_WIDTH-1-2*ROW_SUM_WIDTH -: ROW_SUM_WIDTH];
    assign col4_sum_s0 = pipe_s0_dout[PIPE_S0_WIDTH-1-3*ROW_SUM_WIDTH -: ROW_SUM_WIDTH];
    assign pixel_x_s0  = pipe_s0_dout[DATA_WIDTH + ROW_CNT_WIDTH + 1 +: LINE_ADDR_WIDTH];
    assign pixel_y_s0  = pipe_s0_dout[DATA_WIDTH + 1 +: ROW_CNT_WIDTH];
    assign center_s0   = pipe_s0_dout[1 +: DATA_WIDTH];

    //=========================================================================
    ////// pipe stage 1: row/column sum delay
    //=========================================================================
    // din_valid: from pipe_s0 output valid
    assign pipe_s1_din_valid = pipe_s0_dout_valid;
    // din_ready: from pipe_s2 (backpressure propagation)
    assign pipe_s1_din_ready = pipe_s2_din_ready;
    // din_shake: handshake indicator
    assign pipe_s1_din_shake = pipe_s1_din_valid & pipe_s1_din_ready;
    // data pack for pipeline register input
    assign pipe_s1_din = {row0_sum_s0, row4_sum_s0, col0_sum_s0, col4_sum_s0,
                          pixel_x_s0, pixel_y_s0, center_s0, pipe_s1_din_valid};
    // dout_ready: from pipe_s2
    assign pipe_s1_dout_ready = pipe_s2_din_ready;

    common_pipe_slice #(
        .DATA_WIDTH (PIPE_S1_WIDTH),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_s1 (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_s1_din),
        .din_valid  (pipe_s1_din_valid),
        .din_ready  (pipe_s1_din_ready),
        .dout       (pipe_s1_dout),
        .dout_valid (pipe_s1_dout_valid),
        .dout_ready (pipe_s1_dout_ready)
    );

    // data unpack from pipe_s1 output
    assign row0_sum_s1 = pipe_s1_dout[PIPE_S1_WIDTH-1 -: ROW_SUM_WIDTH];
    assign row4_sum_s1 = pipe_s1_dout[PIPE_S1_WIDTH-1-ROW_SUM_WIDTH -: ROW_SUM_WIDTH];
    assign col0_sum_s1 = pipe_s1_dout[PIPE_S1_WIDTH-1-2*ROW_SUM_WIDTH -: ROW_SUM_WIDTH];
    assign col4_sum_s1 = pipe_s1_dout[PIPE_S1_WIDTH-1-3*ROW_SUM_WIDTH -: ROW_SUM_WIDTH];
    assign pixel_x_s1  = pipe_s1_dout[DATA_WIDTH + ROW_CNT_WIDTH + 1 +: LINE_ADDR_WIDTH];
    assign pixel_y_s1  = pipe_s1_dout[DATA_WIDTH + 1 +: ROW_CNT_WIDTH];
    assign center_s1   = pipe_s1_dout[1 +: DATA_WIDTH];

    //=========================================================================
    ////// pipe stage 2: gradient diff/abs and neighbor tracking
    //=========================================================================
    // comb: Sobel gradient difference
    assign grad_h_raw_comb = $signed({1'b0, row0_sum_s1}) - $signed({1'b0, row4_sum_s1});
    assign grad_v_raw_comb = $signed({1'b0, col0_sum_s1}) - $signed({1'b0, col4_sum_s1});

    // comb: absolute value
    assign grad_h_abs_comb = (grad_h_raw_comb[GRAD_WIDTH-1]) ?
                            ~grad_h_raw_comb + 1'b1 : grad_h_raw_comb;
    assign grad_v_abs_comb = (grad_v_raw_comb[GRAD_WIDTH-1]) ?
                            ~grad_v_raw_comb + 1'b1 : grad_v_raw_comb;

    // comb: gradient magnitude (ref semantics: round(|grad_h|/5) + round(|grad_v|/5))
    assign grad_h_div5_comb = (grad_h_abs_comb + 3'd2) / 3'd5;
    assign grad_v_div5_comb = (grad_v_abs_comb + 3'd2) / 3'd5;
    assign grad_sum_full = grad_h_div5_comb + grad_v_div5_comb;
    assign grad_sum_overflow = grad_sum_full[GRAD_WIDTH];
    assign grad_sum_comb = grad_sum_overflow ?
                          {GRAD_WIDTH{1'b1}} : grad_sum_full[GRAD_WIDTH-1:0];

    //=========================================================================
    ////// gradient shift register (always block - timing critical)
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grad_l_reg <= {GRAD_WIDTH{1'b0}};
            grad_r_reg <= {GRAD_WIDTH{1'b0}};
        end else if (enable && pipe_out_din_ready) begin
            grad_r_reg <= grad_l_reg;
            grad_l_reg <= grad_sum_comb;
        end
    end

    //=========================================================================
    ////// pipe stage 2: pack and pipeline
    //=========================================================================
    // din_valid: from pipe_s1 output valid
    assign pipe_s2_din_valid = pipe_s1_dout_valid;
    // din_ready: from pipe_s3 (backpressure propagation)
    assign pipe_s2_din_ready = pipe_s3_din_ready;
    // din_shake: handshake indicator
    assign pipe_s2_din_shake = pipe_s2_din_valid & pipe_s2_din_ready;
    // data pack for pipeline register input
    assign pipe_s2_din = {grad_h_abs_comb, grad_v_abs_comb, grad_sum_comb,
                          pixel_x_s1, pixel_y_s1, center_s1, pipe_s2_din_valid};
    // dout_ready: from pipe_s3
    assign pipe_s2_dout_ready = pipe_s3_din_ready;

    common_pipe_slice #(
        .DATA_WIDTH (PIPE_S2_WIDTH),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_s2 (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_s2_din),
        .din_valid  (pipe_s2_din_valid),
        .din_ready  (pipe_s2_din_ready),
        .dout       (pipe_s2_dout),
        .dout_valid (pipe_s2_dout_valid),
        .dout_ready (pipe_s2_dout_ready)
    );

    // data unpack from pipe_s2 output
    assign grad_h_abs_s2 = pipe_s2_dout[PIPE_S2_WIDTH-1 -: GRAD_WIDTH];
    assign grad_v_abs_s2 = pipe_s2_dout[PIPE_S2_WIDTH-1-GRAD_WIDTH -: GRAD_WIDTH];
    assign grad_sum_s2   = pipe_s2_dout[PIPE_S2_WIDTH-1-2*GRAD_WIDTH -: GRAD_WIDTH];
    assign pixel_x_s2    = pipe_s2_dout[DATA_WIDTH + ROW_CNT_WIDTH + 1 +: LINE_ADDR_WIDTH];
    assign pixel_y_s2    = pipe_s2_dout[DATA_WIDTH + 1 +: ROW_CNT_WIDTH];
    assign center_s2     = pipe_s2_dout[1 +: DATA_WIDTH];

    //=========================================================================
    ////// pipe stage 3: gradient max finding
    //=========================================================================
    // comb: gradient maximum (neighbor tracking)
    assign max_0_1 = (grad_l_reg >= grad_sum_s2) ? grad_l_reg : grad_sum_s2;
    assign grad_max_comb = (max_0_1 >= grad_r_reg) ? max_0_1 : grad_r_reg;

    //=========================================================================
    ////// pipe stage 3: pack and pipeline
    //=========================================================================
    // din_valid: from pipe_s2 output valid
    assign pipe_s3_din_valid = pipe_s2_dout_valid;
    // din_ready: from pipe_out (backpressure propagation)
    assign pipe_s3_din_ready = pipe_out_din_ready;
    // din_shake: handshake indicator
    assign pipe_s3_din_shake = pipe_s3_din_valid & pipe_s3_din_ready;
    // data pack for pipeline register input
    assign pipe_s3_din = {grad_max_comb, grad_sum_s2, grad_h_abs_s2, grad_v_abs_s2,
                          pixel_x_s2, pixel_y_s2, center_s2, pipe_s3_din_valid};
    // dout_ready: from pipe_out
    assign pipe_s3_dout_ready = pipe_out_din_ready;

    common_pipe_slice #(
        .DATA_WIDTH (PIPE_S3_WIDTH),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_s3 (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_s3_din),
        .din_valid  (pipe_s3_din_valid),
        .din_ready  (pipe_s3_din_ready),
        .dout       (pipe_s3_dout),
        .dout_valid (pipe_s3_dout_valid),
        .dout_ready (pipe_s3_dout_ready)
    );

    // data unpack from pipe_s3 output
    assign grad_max_s3   = pipe_s3_dout[PIPE_S3_WIDTH-1 -: GRAD_WIDTH];
    assign grad_sum_s3   = pipe_s3_dout[PIPE_S3_WIDTH-1-GRAD_WIDTH -: GRAD_WIDTH];
    assign grad_h_abs_s3 = pipe_s3_dout[PIPE_S3_WIDTH-1-2*GRAD_WIDTH -: GRAD_WIDTH];
    assign grad_v_abs_s3 = pipe_s3_dout[PIPE_S3_WIDTH-1-3*GRAD_WIDTH -: GRAD_WIDTH];
    assign pixel_x_s3    = pipe_s3_dout[DATA_WIDTH + ROW_CNT_WIDTH + 1 +: LINE_ADDR_WIDTH];
    assign pixel_y_s3    = pipe_s3_dout[DATA_WIDTH + 1 +: ROW_CNT_WIDTH];
    assign center_s3     = pipe_s3_dout[1 +: DATA_WIDTH];

    //=========================================================================
    ////// pipe stage out: window size LUT
    //=========================================================================
    // comb: gradient max extension for LUT
    assign grad_max_ext = {1'b0, grad_max_s3};
    assign lut_x0 = {{GRAD_WIDTH{1'b0}}, 1'b1} << win_size_clip_sft_0;
    assign lut_x1 = lut_x0 + ({{GRAD_WIDTH{1'b0}}, 1'b1} << win_size_clip_sft_1);
    assign lut_x2 = lut_x1 + ({{GRAD_WIDTH{1'b0}}, 1'b1} << win_size_clip_sft_2);
    assign lut_x3 = lut_x2 + ({{GRAD_WIDTH{1'b0}}, 1'b1} << win_size_clip_sft_3);

    // comb: window size interpolation
    assign win_size_grad_comb =
        (grad_max_ext <= lut_x0) ? {1'b0, win_size_clip_y_0} :
        (grad_max_ext >= lut_x3) ? {1'b0, win_size_clip_y_3} :
        (grad_max_ext <= lut_x1) ? lut_interp_round(grad_max_ext, lut_x0, lut_x1, win_size_clip_y_0, win_size_clip_y_1) :
        (grad_max_ext <= lut_x2) ? lut_interp_round(grad_max_ext, lut_x1, lut_x2, win_size_clip_y_1, win_size_clip_y_2) :
                                   lut_interp_round(grad_max_ext, lut_x2, lut_x3, win_size_clip_y_2, win_size_clip_y_3);

    // comb: window size clipping
    assign win_size_comb =
        (win_size_grad_comb < 16) ? 6'd16 :
        (win_size_grad_comb > 40) ? 6'd40 :
                                    win_size_grad_comb[WIN_SIZE_WIDTH-1:0];

    //=========================================================================
    ////// pipe stage out: pack and pipeline
    //=========================================================================
    // din_valid: from pipe_s3 output valid
    assign pipe_out_din_valid = pipe_s3_dout_valid;
    // din_ready: from dout_ready (backpressure propagation)
    assign pipe_out_din_ready = dout_ready;
    // din_shake: handshake indicator
    assign pipe_out_din_shake = pipe_out_din_valid & pipe_out_din_ready;
    // data pack for pipeline register input
    assign pipe_out_din = {grad_h_abs_s3, grad_v_abs_s3, grad_sum_s3, win_size_comb,
                           pixel_x_s3, pixel_y_s3, center_s3, pipe_out_din_valid};
    // dout_ready: to downstream
    assign pipe_out_dout_ready = dout_ready;

    common_pipe_slice #(
        .DATA_WIDTH (PIPE_OUT_WIDTH),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_out (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_out_din),
        .din_valid  (pipe_out_din_valid),
        .din_ready  (pipe_out_din_ready),
        .dout       (pipe_out_dout),
        .dout_valid (dout_valid),
        .dout_ready (pipe_out_dout_ready)
    );

    //=========================================================================
    ////// dout
    //=========================================================================
    // data unpack from pipe_out output
    assign grad_h        = pipe_out_dout[PIPE_OUT_WIDTH-1 -: GRAD_WIDTH];
    assign grad_v        = pipe_out_dout[PIPE_OUT_WIDTH-1-GRAD_WIDTH -: GRAD_WIDTH];
    assign grad          = pipe_out_dout[PIPE_OUT_WIDTH-1-2*GRAD_WIDTH -: GRAD_WIDTH];
    assign win_size_clip = pipe_out_dout[PIPE_OUT_WIDTH-1-3*GRAD_WIDTH -: WIN_SIZE_WIDTH];
    assign pixel_x_out   = pipe_out_dout[ROW_CNT_WIDTH + DATA_WIDTH + 1 +: LINE_ADDR_WIDTH];
    assign pixel_y_out   = pipe_out_dout[DATA_WIDTH + 1 +: ROW_CNT_WIDTH];
    assign center_pixel  = pipe_out_dout[1 +: DATA_WIDTH];

endmodule
