//-----------------------------------------------------------------------------
// Module: stage1_gradient
// Purpose: Gradient calculation and window size determination
// Author: rtl-impl
// Date: 2026-03-24
// Version: v3.0 - Refactored with common_pipe and valid/ready handshake
//-----------------------------------------------------------------------------
// Description:
//   Implements Stage 1 of ISP-CSIIR pipeline:
//   - Sobel convolution for horizontal/vertical gradients
//   - Gradient magnitude calculation
//   - Neighborhood gradient maximum finding
//   - Window size LUT lookup
//
// Pipeline Structure (5 cycles):
//   Cycle 0: Sobel row/column sum (combinational + register)
//   Cycle 1: Pipeline delay for row/column sums
//   Cycle 2: Gradient difference and absolute value
//   Cycle 3: Gradient maximum finding
//   Cycle 4: Window size LUT
//
// Handshake Protocol:
//   - valid_in/valid_out: Data valid indicators
//   - ready_in: Downstream back-pressure signal
//   - ready_out: Always 1 (simple pipeline without skid buffer)
//-----------------------------------------------------------------------------

module stage1_gradient #(
    parameter DATA_WIDTH     = 10,
    parameter GRAD_WIDTH     = 14,
    parameter WIN_SIZE_WIDTH = 6,
    parameter LINE_ADDR_WIDTH = 14,
    parameter ROW_CNT_WIDTH  = 13
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // 5x5 Window input
    input  wire [DATA_WIDTH-1:0]       window_0_0, window_0_1, window_0_2, window_0_3, window_0_4,
    input  wire [DATA_WIDTH-1:0]       window_1_0, window_1_1, window_1_2, window_1_3, window_1_4,
    input  wire [DATA_WIDTH-1:0]       window_2_0, window_2_1, window_2_2, window_2_3, window_2_4,
    input  wire [DATA_WIDTH-1:0]       window_3_0, window_3_1, window_3_2, window_3_3, window_3_4,
    input  wire [DATA_WIDTH-1:0]       window_4_0, window_4_1, window_4_2, window_4_3, window_4_4,
    input  wire                        window_valid,
    output wire                        window_ready,

    // Configuration parameters
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_0,
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_1,
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_2,
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_3,

    // Output
    output wire [GRAD_WIDTH-1:0]       grad_h,
    output wire [GRAD_WIDTH-1:0]       grad_v,
    output wire [GRAD_WIDTH-1:0]       grad,
    output wire [WIN_SIZE_WIDTH-1:0]   win_size_clip,
    output wire                        stage1_valid,
    input  wire                        stage1_ready,

    // Position info (passed through)
    input  wire [LINE_ADDR_WIDTH-1:0]  pixel_x,
    input  wire [ROW_CNT_WIDTH-1:0]    pixel_y,
    output wire [LINE_ADDR_WIDTH-1:0]  pixel_x_out,
    output wire [ROW_CNT_WIDTH-1:0]    pixel_y_out,

    // Center pixel (passed through for Stage 4)
    output wire [DATA_WIDTH-1:0]       center_pixel
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam ROW_SUM_WIDTH = DATA_WIDTH + 3;  // 13-bit for 5 pixels sum
    localparam PIPE_S0_WIDTH = 4 * ROW_SUM_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1;
    localparam PIPE_S1_WIDTH = 4 * ROW_SUM_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1;
    localparam PIPE_S2_WIDTH = 4 * GRAD_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1;
    localparam PIPE_S3_WIDTH = 4 * GRAD_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1;

    //=========================================================================
    // Ready Signal (Simple Pipeline - Always Ready)
    //=========================================================================
    assign window_ready = 1'b1;

    //=========================================================================
    // Cycle 0: Sobel Row/Column Sum (Combinational)
    //=========================================================================
    // Row sums (5 pixels each)
    wire [ROW_SUM_WIDTH-1:0] row0_sum_comb = window_0_0 + window_0_1 + window_0_2 + window_0_3 + window_0_4;
    wire [ROW_SUM_WIDTH-1:0] row4_sum_comb = window_4_0 + window_4_1 + window_4_2 + window_4_3 + window_4_4;

    // Column sums (5 pixels each)
    wire [ROW_SUM_WIDTH-1:0] col0_sum_comb = window_0_0 + window_1_0 + window_2_0 + window_3_0 + window_4_0;
    wire [ROW_SUM_WIDTH-1:0] col4_sum_comb = window_0_4 + window_1_4 + window_2_4 + window_3_4 + window_4_4;

    //=========================================================================
    // Cycle 0 Pipeline Registers
    //=========================================================================
    // Pack signals for common_pipe
    wire [PIPE_S0_WIDTH-1:0] pipe_s0_din = {row0_sum_comb, row4_sum_comb, col0_sum_comb, col4_sum_comb,
                                            pixel_x, pixel_y, window_2_2, window_valid};

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
        .valid_in  (window_valid),
        .ready_out (),
        .dout      (pipe_s0_dout),
        .valid_out (valid_s0),
        .ready_in  (stage1_ready)
    );

    // Unpack signals
    wire [ROW_SUM_WIDTH-1:0]   row0_sum_s0 = pipe_s0_dout[PIPE_S0_WIDTH-1 -: ROW_SUM_WIDTH];
    wire [ROW_SUM_WIDTH-1:0]   row4_sum_s0 = pipe_s0_dout[PIPE_S0_WIDTH-1-ROW_SUM_WIDTH -: ROW_SUM_WIDTH];
    wire [ROW_SUM_WIDTH-1:0]   col0_sum_s0 = pipe_s0_dout[PIPE_S0_WIDTH-1-2*ROW_SUM_WIDTH -: ROW_SUM_WIDTH];
    wire [ROW_SUM_WIDTH-1:0]   col4_sum_s0 = pipe_s0_dout[PIPE_S0_WIDTH-1-3*ROW_SUM_WIDTH -: ROW_SUM_WIDTH];
    wire [LINE_ADDR_WIDTH-1:0] pixel_x_s0  = pipe_s0_dout[DATA_WIDTH + ROW_CNT_WIDTH + 1 +: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0]   pixel_y_s0  = pipe_s0_dout[DATA_WIDTH + 1 +: ROW_CNT_WIDTH];
    wire [DATA_WIDTH-1:0]      center_s0   = pipe_s0_dout[DATA_WIDTH + 1 +: DATA_WIDTH];

    //=========================================================================
    // Cycle 1: Pipeline Delay for Row/Column Sums
    //=========================================================================
    wire [PIPE_S1_WIDTH-1:0] pipe_s1_din = {row0_sum_s0, row4_sum_s0, col0_sum_s0, col4_sum_s0,
                                            pixel_x_s0, pixel_y_s0, center_s0, valid_s0};

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
        .ready_in  (stage1_ready)
    );

    // Unpack signals
    wire [ROW_SUM_WIDTH-1:0]   row0_sum_s1 = pipe_s1_dout[PIPE_S1_WIDTH-1 -: ROW_SUM_WIDTH];
    wire [ROW_SUM_WIDTH-1:0]   row4_sum_s1 = pipe_s1_dout[PIPE_S1_WIDTH-1-ROW_SUM_WIDTH -: ROW_SUM_WIDTH];
    wire [ROW_SUM_WIDTH-1:0]   col0_sum_s1 = pipe_s1_dout[PIPE_S1_WIDTH-1-2*ROW_SUM_WIDTH -: ROW_SUM_WIDTH];
    wire [ROW_SUM_WIDTH-1:0]   col4_sum_s1 = pipe_s1_dout[PIPE_S1_WIDTH-1-3*ROW_SUM_WIDTH -: ROW_SUM_WIDTH];
    wire [LINE_ADDR_WIDTH-1:0] pixel_x_s1  = pipe_s1_dout[DATA_WIDTH + ROW_CNT_WIDTH + 1 +: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0]   pixel_y_s1  = pipe_s1_dout[DATA_WIDTH + 1 +: ROW_CNT_WIDTH];
    wire [DATA_WIDTH-1:0]      center_s1   = pipe_s1_dout[DATA_WIDTH + 1 +: DATA_WIDTH];

    //=========================================================================
    // Cycle 2: Gradient Difference and Absolute Value (Combinational)
    //=========================================================================
    wire signed [GRAD_WIDTH-1:0] grad_h_raw_comb = $signed({1'b0, row0_sum_s1}) - $signed({1'b0, row4_sum_s1});
    wire signed [GRAD_WIDTH-1:0] grad_v_raw_comb = $signed({1'b0, col0_sum_s1}) - $signed({1'b0, col4_sum_s1});

    wire [GRAD_WIDTH-1:0] grad_h_abs_comb = (grad_h_raw_comb[GRAD_WIDTH-1]) ?
                                            ~grad_h_raw_comb + 1'b1 : grad_h_raw_comb;
    wire [GRAD_WIDTH-1:0] grad_v_abs_comb = (grad_v_raw_comb[GRAD_WIDTH-1]) ?
                                            ~grad_v_raw_comb + 1'b1 : grad_v_raw_comb;

    // Gradient sum using multiply approximation for /5
    // grad = (grad_h + grad_v) * 205 >> 10 (approximates /5)
    wire [GRAD_WIDTH:0] grad_sum_raw = grad_h_abs_comb + grad_v_abs_comb;
    wire [GRAD_WIDTH+9:0] grad_full = grad_sum_raw * 9'd205;

    // Right shift by 10 with rounding
    wire [GRAD_WIDTH-1:0] grad_shifted = grad_full[GRAD_WIDTH+9:10];
    wire                  round_carry = grad_full[9];
    wire [GRAD_WIDTH:0]   grad_rounded_full = grad_shifted + round_carry;
    wire                  overflow = grad_rounded_full[GRAD_WIDTH];
    wire [GRAD_WIDTH-1:0] grad_sum_comb = overflow ?
                                          {GRAD_WIDTH{1'b1}} : grad_rounded_full[GRAD_WIDTH-1:0];

    // Neighbor gradients shift register (need to maintain across cycles)
    reg [GRAD_WIDTH-1:0] grad_l_reg, grad_r_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grad_l_reg <= {GRAD_WIDTH{1'b0}};
            grad_r_reg <= {GRAD_WIDTH{1'b0}};
        end else if (enable && stage1_ready) begin
            grad_r_reg <= grad_l_reg;
            grad_l_reg <= grad_sum_comb;
        end
    end

    //=========================================================================
    // Cycle 2 Pipeline Registers
    //=========================================================================
    wire [PIPE_S2_WIDTH-1:0] pipe_s2_din = {grad_h_abs_comb, grad_v_abs_comb, grad_sum_comb,
                                            pixel_x_s1, pixel_y_s1, center_s1, valid_s1};

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
        .ready_in  (stage1_ready)
    );

    // Unpack signals
    wire [GRAD_WIDTH-1:0]       grad_h_abs_s2 = pipe_s2_dout[PIPE_S2_WIDTH-1 -: GRAD_WIDTH];
    wire [GRAD_WIDTH-1:0]       grad_v_abs_s2 = pipe_s2_dout[PIPE_S2_WIDTH-1-GRAD_WIDTH -: GRAD_WIDTH];
    wire [GRAD_WIDTH-1:0]       grad_sum_s2   = pipe_s2_dout[PIPE_S2_WIDTH-1-2*GRAD_WIDTH -: GRAD_WIDTH];
    wire [LINE_ADDR_WIDTH-1:0]  pixel_x_s2    = pipe_s2_dout[DATA_WIDTH + ROW_CNT_WIDTH + 1 +: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0]    pixel_y_s2    = pipe_s2_dout[DATA_WIDTH + 1 +: ROW_CNT_WIDTH];
    wire [DATA_WIDTH-1:0]       center_s2     = pipe_s2_dout[DATA_WIDTH + 1 +: DATA_WIDTH];

    //=========================================================================
    // Cycle 3: Gradient Maximum (Combinational)
    //=========================================================================
    wire [GRAD_WIDTH-1:0] max_0_1 = (grad_l_reg >= grad_sum_s2) ? grad_l_reg : grad_sum_s2;
    wire [GRAD_WIDTH-1:0] grad_max_comb = (max_0_1 >= grad_r_reg) ? max_0_1 : grad_r_reg;

    //=========================================================================
    // Cycle 3 Pipeline Registers
    //=========================================================================
    wire [PIPE_S3_WIDTH-1:0] pipe_s3_din = {grad_max_comb, grad_sum_s2, grad_h_abs_s2, grad_v_abs_s2,
                                            pixel_x_s2, pixel_y_s2, center_s2, valid_s2};

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
        .ready_in  (stage1_ready)
    );

    // Unpack signals
    wire [GRAD_WIDTH-1:0]       grad_max_s3   = pipe_s3_dout[PIPE_S3_WIDTH-1 -: GRAD_WIDTH];
    wire [GRAD_WIDTH-1:0]       grad_sum_s3   = pipe_s3_dout[PIPE_S3_WIDTH-1-GRAD_WIDTH -: GRAD_WIDTH];
    wire [GRAD_WIDTH-1:0]       grad_h_abs_s3 = pipe_s3_dout[PIPE_S3_WIDTH-1-2*GRAD_WIDTH -: GRAD_WIDTH];
    wire [GRAD_WIDTH-1:0]       grad_v_abs_s3 = pipe_s3_dout[PIPE_S3_WIDTH-1-3*GRAD_WIDTH -: GRAD_WIDTH];
    wire [LINE_ADDR_WIDTH-1:0]  pixel_x_s3    = pipe_s3_dout[DATA_WIDTH + ROW_CNT_WIDTH + 1 +: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0]    pixel_y_s3    = pipe_s3_dout[DATA_WIDTH + 1 +: ROW_CNT_WIDTH];
    wire [DATA_WIDTH-1:0]       center_s3     = pipe_s3_dout[DATA_WIDTH + 1 +: DATA_WIDTH];

    //=========================================================================
    // Cycle 4: Window Size LUT (Combinational)
    //=========================================================================
    wire [WIN_SIZE_WIDTH-1:0] win_size_comb = (grad_max_s3 < {3'b0, win_size_clip_y_0}) ? 6'd16 :
                                              (grad_max_s3 < {3'b0, win_size_clip_y_1}) ? 6'd24 :
                                              (grad_max_s3 < {3'b0, win_size_clip_y_2}) ? 6'd32 :
                                              (grad_max_s3 < {3'b0, win_size_clip_y_3}) ? 6'd40 : 6'd40;

    //=========================================================================
    // Output Registers (Cycle 4)
    //=========================================================================
    // Pack output signals
    localparam PIPE_OUT_WIDTH = 3 * GRAD_WIDTH + WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1;
    wire [PIPE_OUT_WIDTH-1:0] pipe_out_din = {grad_h_abs_s3, grad_v_abs_s3, grad_sum_s3, win_size_comb,
                                              pixel_x_s3, pixel_y_s3, center_s3, valid_s3};

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
        .valid_out (stage1_valid),
        .ready_in  (stage1_ready)
    );

    // Unpack output signals
    assign grad_h        = pipe_out_dout[PIPE_OUT_WIDTH-1 -: GRAD_WIDTH];
    assign grad_v        = pipe_out_dout[PIPE_OUT_WIDTH-1-GRAD_WIDTH -: GRAD_WIDTH];
    assign grad          = pipe_out_dout[PIPE_OUT_WIDTH-1-2*GRAD_WIDTH -: GRAD_WIDTH];
    assign win_size_clip = pipe_out_dout[PIPE_OUT_WIDTH-1-3*GRAD_WIDTH -: WIN_SIZE_WIDTH];
    assign pixel_x_out   = pipe_out_dout[LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1 +: LINE_ADDR_WIDTH];
    assign pixel_y_out   = pipe_out_dout[ROW_CNT_WIDTH + DATA_WIDTH + 1 +: ROW_CNT_WIDTH];
    assign center_pixel  = pipe_out_dout[DATA_WIDTH + 1 +: DATA_WIDTH];

endmodule