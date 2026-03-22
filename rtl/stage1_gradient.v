//-----------------------------------------------------------------------------
// Module: stage1_gradient
// Purpose: Gradient calculation and window size determination
// Author: rtl-impl
// Date: 2026-03-22
// Version: v1.0
//-----------------------------------------------------------------------------
// Description:
//   Implements Stage 1 of ISP-CSIIR pipeline:
//   - Sobel convolution for horizontal/vertical gradients
//   - Gradient magnitude calculation
//   - Neighborhood gradient maximum finding
//   - Window size LUT lookup
//
// Pipeline Structure (5 cycles):
//   Cycle 0: Sobel row/column sum
//   Cycle 1: Gradient difference
//   Cycle 2: Absolute value and sum
//   Cycle 3: Gradient maximum
//   Cycle 4: Window size LUT
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

    // Configuration parameters
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_0,
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_1,
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_2,
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_3,

    // Output
    output reg  [GRAD_WIDTH-1:0]       grad_h,
    output reg  [GRAD_WIDTH-1:0]       grad_v,
    output reg  [GRAD_WIDTH-1:0]       grad,
    output reg  [WIN_SIZE_WIDTH-1:0]   win_size_clip,
    output reg                         stage1_valid,

    // Position info (passed through)
    input  wire [LINE_ADDR_WIDTH-1:0]  pixel_x,
    input  wire [ROW_CNT_WIDTH-1:0]    pixel_y,
    output reg  [LINE_ADDR_WIDTH-1:0]  pixel_x_out,
    output reg  [ROW_CNT_WIDTH-1:0]    pixel_y_out,

    // Center pixel (passed through for Stage 4)
    output reg  [DATA_WIDTH-1:0]       center_pixel
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam ROW_SUM_WIDTH = DATA_WIDTH + 3;  // 13-bit for 5 pixels sum

    //=========================================================================
    // Cycle 0: Sobel Row/Column Sum
    //=========================================================================
    // Row sums (5 pixels each)
    wire [ROW_SUM_WIDTH-1:0] row0_sum_comb = window_0_0 + window_0_1 + window_0_2 + window_0_3 + window_0_4;
    wire [ROW_SUM_WIDTH-1:0] row1_sum_comb = window_1_0 + window_1_1 + window_1_2 + window_1_3 + window_1_4;
    wire [ROW_SUM_WIDTH-1:0] row2_sum_comb = window_2_0 + window_2_1 + window_2_2 + window_2_3 + window_2_4;
    wire [ROW_SUM_WIDTH-1:0] row3_sum_comb = window_3_0 + window_3_1 + window_3_2 + window_3_3 + window_3_4;
    wire [ROW_SUM_WIDTH-1:0] row4_sum_comb = window_4_0 + window_4_1 + window_4_2 + window_4_3 + window_4_4;

    // Column sums (5 pixels each)
    wire [ROW_SUM_WIDTH-1:0] col0_sum_comb = window_0_0 + window_1_0 + window_2_0 + window_3_0 + window_4_0;
    wire [ROW_SUM_WIDTH-1:0] col1_sum_comb = window_0_1 + window_1_1 + window_2_1 + window_3_1 + window_4_1;
    wire [ROW_SUM_WIDTH-1:0] col2_sum_comb = window_0_2 + window_1_2 + window_2_2 + window_3_2 + window_4_2;
    wire [ROW_SUM_WIDTH-1:0] col3_sum_comb = window_0_3 + window_1_3 + window_2_3 + window_3_3 + window_4_3;
    wire [ROW_SUM_WIDTH-1:0] col4_sum_comb = window_0_4 + window_1_4 + window_2_4 + window_3_4 + window_4_4;

    // Pipeline registers for Cycle 0
    reg [ROW_SUM_WIDTH-1:0] row0_sum_s0, row4_sum_s0;
    reg [ROW_SUM_WIDTH-1:0] col0_sum_s0, col4_sum_s0;
    reg                     valid_s0;
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_s0;
    reg [ROW_CNT_WIDTH-1:0]   pixel_y_s0;
    reg [DATA_WIDTH-1:0]      center_s0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row0_sum_s0 <= {ROW_SUM_WIDTH{1'b0}};
            row4_sum_s0 <= {ROW_SUM_WIDTH{1'b0}};
            col0_sum_s0 <= {ROW_SUM_WIDTH{1'b0}};
            col4_sum_s0 <= {ROW_SUM_WIDTH{1'b0}};
            valid_s0    <= 1'b0;
            pixel_x_s0  <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s0  <= {ROW_CNT_WIDTH{1'b0}};
            center_s0   <= {DATA_WIDTH{1'b0}};
        end else if (enable) begin
            row0_sum_s0 <= row0_sum_comb;
            row4_sum_s0 <= row4_sum_comb;
            col0_sum_s0 <= col0_sum_comb;
            col4_sum_s0 <= col4_sum_comb;
            valid_s0    <= window_valid;
            pixel_x_s0  <= pixel_x;
            pixel_y_s0  <= pixel_y;
            center_s0   <= window_2_2;  // Center pixel
        end
    end

    //=========================================================================
    // Cycle 1: Gradient Difference
    //=========================================================================
    wire signed [GRAD_WIDTH-1:0] grad_h_raw_comb = $signed({1'b0, row0_sum_s0}) - $signed({1'b0, row4_sum_s0});
    wire signed [GRAD_WIDTH-1:0] grad_v_raw_comb = $signed({1'b0, col0_sum_s0}) - $signed({1'b0, col4_sum_s0});

    // Pipeline registers for Cycle 1
    reg signed [GRAD_WIDTH-1:0] grad_h_raw_s1, grad_v_raw_s1;
    reg                         valid_s1;
    reg [LINE_ADDR_WIDTH-1:0]   pixel_x_s1;
    reg [ROW_CNT_WIDTH-1:0]     pixel_y_s1;
    reg [DATA_WIDTH-1:0]        center_s1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grad_h_raw_s1 <= {GRAD_WIDTH{1'b0}};
            grad_v_raw_s1 <= {GRAD_WIDTH{1'b0}};
            valid_s1      <= 1'b0;
            pixel_x_s1    <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s1    <= {ROW_CNT_WIDTH{1'b0}};
            center_s1     <= {DATA_WIDTH{1'b0}};
        end else if (enable) begin
            grad_h_raw_s1 <= grad_h_raw_comb;
            grad_v_raw_s1 <= grad_v_raw_comb;
            valid_s1      <= valid_s0;
            pixel_x_s1    <= pixel_x_s0;
            pixel_y_s1    <= pixel_y_s0;
            center_s1     <= center_s0;
        end
    end

    //=========================================================================
    // Cycle 2: Absolute Value and Gradient Sum
    //=========================================================================
    wire [GRAD_WIDTH-1:0] grad_h_abs_comb = (grad_h_raw_s1[GRAD_WIDTH-1]) ?
                                            ~grad_h_raw_s1 + 1'b1 : grad_h_raw_s1;
    wire [GRAD_WIDTH-1:0] grad_v_abs_comb = (grad_v_raw_s1[GRAD_WIDTH-1]) ?
                                            ~grad_v_raw_s1 + 1'b1 : grad_v_raw_s1;

    // Gradient sum using multiply approximation for /5
    // grad = (grad_h + grad_v) * 205 >> 10 (approximates /5)
    // Step 1: Sum of absolute gradients
    wire [GRAD_WIDTH:0] grad_sum_raw = grad_h_abs_comb + grad_v_abs_comb;

    // Step 2: Multiply by 205 (9-bit constant)
    wire [GRAD_WIDTH+9:0] grad_full = grad_sum_raw * 9'd205;

    // Step 3: Right shift by 10 with saturation to GRAD_WIDTH
    wire [GRAD_WIDTH-1:0] grad_sum_comb = (|grad_full[GRAD_WIDTH+9:GRAD_WIDTH]) ?
                                          {GRAD_WIDTH{1'b1}} : grad_full[GRAD_WIDTH-1:0];

    // Pipeline registers for Cycle 2
    reg [GRAD_WIDTH-1:0]       grad_h_abs_s2, grad_v_abs_s2;
    reg [GRAD_WIDTH-1:0]       grad_sum_s2;
    reg                        valid_s2;
    reg [LINE_ADDR_WIDTH-1:0]  pixel_x_s2;
    reg [ROW_CNT_WIDTH-1:0]    pixel_y_s2;
    reg [DATA_WIDTH-1:0]       center_s2;

    // Need neighbor gradients for maximum finding
    reg [GRAD_WIDTH-1:0] grad_l_s2, grad_r_s2;  // Left/right neighbors from shift register

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grad_h_abs_s2 <= {GRAD_WIDTH{1'b0}};
            grad_v_abs_s2 <= {GRAD_WIDTH{1'b0}};
            grad_sum_s2   <= {GRAD_WIDTH{1'b0}};
            grad_l_s2     <= {GRAD_WIDTH{1'b0}};
            grad_r_s2     <= {GRAD_WIDTH{1'b0}};
            valid_s2      <= 1'b0;
            pixel_x_s2    <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s2    <= {ROW_CNT_WIDTH{1'b0}};
            center_s2     <= {DATA_WIDTH{1'b0}};
        end else if (enable) begin
            grad_h_abs_s2 <= grad_h_abs_comb;
            grad_v_abs_s2 <= grad_v_abs_comb;
            grad_sum_s2   <= grad_sum_comb;
            // Shift for neighbor gradients
            grad_r_s2     <= grad_l_s2;
            grad_l_s2     <= grad_sum_comb;
            valid_s2      <= valid_s1;
            pixel_x_s2    <= pixel_x_s1;
            pixel_y_s2    <= pixel_y_s1;
            center_s2     <= center_s1;
        end
    end

    //=========================================================================
    // Cycle 3: Gradient Maximum
    //=========================================================================
    // Find maximum of 3 horizontal neighbors (left, center, right)
    wire [GRAD_WIDTH-1:0] max_0_1 = (grad_l_s2 >= grad_sum_s2) ? grad_l_s2 : grad_sum_s2;
    wire [GRAD_WIDTH-1:0] grad_max_comb = (max_0_1 >= grad_r_s2) ? max_0_1 : grad_r_s2;

    // Pipeline registers for Cycle 3
    reg [GRAD_WIDTH-1:0]       grad_max_s3;
    reg [GRAD_WIDTH-1:0]       grad_sum_s3;
    reg [GRAD_WIDTH-1:0]       grad_h_abs_s3, grad_v_abs_s3;
    reg                        valid_s3;
    reg [LINE_ADDR_WIDTH-1:0]  pixel_x_s3;
    reg [ROW_CNT_WIDTH-1:0]    pixel_y_s3;
    reg [DATA_WIDTH-1:0]       center_s3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grad_max_s3   <= {GRAD_WIDTH{1'b0}};
            grad_sum_s3   <= {GRAD_WIDTH{1'b0}};
            grad_h_abs_s3 <= {GRAD_WIDTH{1'b0}};
            grad_v_abs_s3 <= {GRAD_WIDTH{1'b0}};
            valid_s3      <= 1'b0;
            pixel_x_s3    <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s3    <= {ROW_CNT_WIDTH{1'b0}};
            center_s3     <= {DATA_WIDTH{1'b0}};
        end else if (enable) begin
            grad_max_s3   <= grad_max_comb;
            grad_sum_s3   <= grad_sum_s2;
            grad_h_abs_s3 <= grad_h_abs_s2;
            grad_v_abs_s3 <= grad_v_abs_s2;
            valid_s3      <= valid_s2;
            pixel_x_s3    <= pixel_x_s2;
            pixel_y_s3    <= pixel_y_s2;
            center_s3     <= center_s2;
        end
    end

    //=========================================================================
    // Cycle 4: Window Size LUT
    //=========================================================================
    // Determine window size based on gradient maximum
    wire [WIN_SIZE_WIDTH-1:0] win_size_comb;
    wire [GRAD_WIDTH-1:0] grad_max_truncated = grad_max_s3[WIN_SIZE_WIDTH-1:0];

    assign win_size_comb = (grad_max_s3 < {3'b0, win_size_clip_y_0}) ? 6'd16 :
                           (grad_max_s3 < {3'b0, win_size_clip_y_1}) ? 6'd24 :
                           (grad_max_s3 < {3'b0, win_size_clip_y_2}) ? 6'd32 :
                           (grad_max_s3 < {3'b0, win_size_clip_y_3}) ? 6'd40 : 6'd40;

    // Pipeline registers for Cycle 4 (output)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grad_h        <= {GRAD_WIDTH{1'b0}};
            grad_v        <= {GRAD_WIDTH{1'b0}};
            grad          <= {GRAD_WIDTH{1'b0}};
            win_size_clip <= {WIN_SIZE_WIDTH{1'b0}};
            stage1_valid  <= 1'b0;
            pixel_x_out   <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_out   <= {ROW_CNT_WIDTH{1'b0}};
            center_pixel  <= {DATA_WIDTH{1'b0}};
        end else if (enable) begin
            grad_h        <= grad_h_abs_s3;
            grad_v        <= grad_v_abs_s3;
            grad          <= grad_sum_s3;
            win_size_clip <= win_size_comb;
            stage1_valid  <= valid_s3;
            pixel_x_out   <= pixel_x_s3;
            pixel_y_out   <= pixel_y_s3;
            center_pixel  <= center_s3;
        end
    end

endmodule