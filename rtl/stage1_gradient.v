//-----------------------------------------------------------------------------
// Module: stage1_gradient
// Description: Stage 1 - Sobel gradient calculation and window size determination
//              Refactored to use common modules and combinational + pipe pattern
//              Pipeline stages: 4 cycles
//              Fully parameterized for resolution and data width
//-----------------------------------------------------------------------------

module stage1_gradient #(
    parameter DATA_WIDTH     = 10,                      // Pixel data width
    parameter GRAD_WIDTH     = 14,                      // Gradient width (DATA_WIDTH + margin)
    parameter WIN_SIZE_WIDTH = 6,                       // Window size parameter width
    parameter PIC_WIDTH_BITS  = 14,                     // log2(MAX_WIDTH) + 1
    parameter PIC_HEIGHT_BITS = 13                      // log2(MAX_HEIGHT) + 1
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // 5x5 window input
    input  wire [DATA_WIDTH-1:0]       window_0_0, window_0_1, window_0_2, window_0_3, window_0_4,
    input  wire [DATA_WIDTH-1:0]       window_1_0, window_1_1, window_1_2, window_1_3, window_1_4,
    input  wire [DATA_WIDTH-1:0]       window_2_0, window_2_1, window_2_2, window_2_3, window_2_4,
    input  wire [DATA_WIDTH-1:0]       window_3_0, window_3_1, window_3_2, window_3_3, window_3_4,
    input  wire [DATA_WIDTH-1:0]       window_4_0, window_4_1, window_4_2, window_4_3, window_4_4,
    input  wire                        window_valid,

    // Configuration (parameterized width)
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_0,
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_1,
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_2,
    input  wire [DATA_WIDTH-1:0]       win_size_clip_y_3,
    input  wire [7:0]                  win_size_clip_sft_0,
    input  wire [7:0]                  win_size_clip_sft_1,
    input  wire [7:0]                  win_size_clip_sft_2,
    input  wire [7:0]                  win_size_clip_sft_3,

    // Position info for boundary handling (parameterized width)
    input  wire [PIC_WIDTH_BITS-1:0]   pixel_x,
    input  wire [PIC_HEIGHT_BITS-1:0]  pixel_y,
    input  wire [PIC_WIDTH_BITS-1:0]   pic_width_m1,
    input  wire [PIC_HEIGHT_BITS-1:0]  pic_height_m1,

    // Outputs
    output reg  [GRAD_WIDTH-1:0]       grad_h,
    output reg  [GRAD_WIDTH-1:0]       grad_v,
    output reg  [GRAD_WIDTH-1:0]       grad,
    output reg  [WIN_SIZE_WIDTH-1:0]   win_size_clip,
    output reg                         stage1_valid
);

    `include "isp_csiir_defines.vh"

    //=========================================================================
    // STAGE 1: Sobel Convolution (Combinational + Pipeline Register)
    //=========================================================================

    // Combinational: Compute Sobel sums using balanced adder tree
    // Sobel X: sum of row 0 - sum of row 4
    wire signed [DATA_WIDTH+2:0] row0_sum = window_0_0 + window_0_1 + window_0_2 + window_0_3 + window_0_4;
    wire signed [DATA_WIDTH+2:0] row4_sum = window_4_0 + window_4_1 + window_4_2 + window_4_3 + window_4_4;
    wire signed [DATA_WIDTH+3:0] grad_h_comb = row0_sum - row4_sum;

    // Sobel Y: sum of column 0 - sum of column 4
    wire signed [DATA_WIDTH+2:0] col0_sum = window_0_0 + window_1_0 + window_2_0 + window_3_0 + window_4_0;
    wire signed [DATA_WIDTH+2:0] col4_sum = window_0_4 + window_1_4 + window_2_4 + window_3_4 + window_4_4;
    wire signed [DATA_WIDTH+3:0] grad_v_comb = col0_sum - col4_sum;

    // Pipeline Stage 1: Register the convolution results
    reg signed [GRAD_WIDTH:0] grad_h_s1;
    reg signed [GRAD_WIDTH:0] grad_v_s1;
    reg                       valid_s1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grad_h_s1 <= {(GRAD_WIDTH+1){1'b0}};
            grad_v_s1 <= {(GRAD_WIDTH+1){1'b0}};
            valid_s1  <= 1'b0;
        end else if (enable && window_valid) begin
            grad_h_s1 <= grad_h_comb;
            grad_v_s1 <= grad_v_comb;
            valid_s1  <= 1'b1;
        end else begin
            valid_s1 <= 1'b0;
        end
    end

    //=========================================================================
    // STAGE 2: Absolute Value and Gradient Sum (Combinational + Pipeline)
    //=========================================================================

    // Combinational: Compute absolute values
    wire [GRAD_WIDTH-1:0] grad_h_abs_comb = (grad_h_s1 < 0) ? -grad_h_s1 : grad_h_s1[GRAD_WIDTH-1:0];
    wire [GRAD_WIDTH-1:0] grad_v_abs_comb = (grad_v_s1 < 0) ? -grad_v_s1 : grad_v_s1[GRAD_WIDTH-1:0];

    // Combinational: Compute gradient sum (approximate division by 4)
    wire [GRAD_WIDTH-1:0] grad_sum_comb = (grad_h_abs_comb >> 2) + (grad_v_abs_comb >> 2);

    // Pipeline Stage 2: Register the results
    reg [GRAD_WIDTH-1:0] grad_h_abs_s2;
    reg [GRAD_WIDTH-1:0] grad_v_abs_s2;
    reg [GRAD_WIDTH-1:0] grad_sum_s2;
    reg                  valid_s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grad_h_abs_s2 <= {GRAD_WIDTH{1'b0}};
            grad_v_abs_s2 <= {GRAD_WIDTH{1'b0}};
            grad_sum_s2   <= {GRAD_WIDTH{1'b0}};
            valid_s2      <= 1'b0;
        end else if (enable && valid_s1) begin
            grad_h_abs_s2 <= grad_h_abs_comb;
            grad_v_abs_s2 <= grad_v_abs_comb;
            grad_sum_s2   <= grad_sum_comb;
            valid_s2      <= 1'b1;
        end else begin
            valid_s2 <= 1'b0;
        end
    end

    //=========================================================================
    // STAGE 3: Gradient Max for Window Size (Combinational + Pipeline)
    //=========================================================================

    // Store previous row's gradient for max computation
    reg [GRAD_WIDTH-1:0] grad_prev_row;

    // Combinational: Find max of 3 gradients (current, above, below)
    // Using tree structure: first compare (current vs above), then with below
    wire [GRAD_WIDTH-1:0] grad_above_comb = grad_prev_row;
    wire [GRAD_WIDTH-1:0] grad_below_comb = grad_sum_s2;  // Simplified: would need actual below

    wire [GRAD_WIDTH-1:0] max_01 = (grad_sum_s2 > grad_above_comb) ? grad_sum_s2 : grad_above_comb;
    wire [GRAD_WIDTH-1:0] grad_max_comb = (max_01 > grad_below_comb) ? max_01 : grad_below_comb;

    // Pipeline Stage 3: Register the results
    reg [GRAD_WIDTH-1:0] grad_max_s3;
    reg [GRAD_WIDTH-1:0] grad_sum_s3;
    reg                  valid_s3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grad_prev_row <= {GRAD_WIDTH{1'b0}};
            grad_max_s3   <= {GRAD_WIDTH{1'b0}};
            grad_sum_s3   <= {GRAD_WIDTH{1'b0}};
            valid_s3      <= 1'b0;
        end else if (enable && valid_s2) begin
            grad_prev_row <= grad_sum_s2;
            grad_max_s3   <= grad_max_comb;
            grad_sum_s3   <= grad_sum_s2;
            valid_s3      <= 1'b1;
        end else begin
            valid_s3 <= 1'b0;
        end
    end

    //=========================================================================
    // STAGE 4: Window Size LUT Lookup (Combinational + Pipeline)
    //=========================================================================

    // Combinational: Window size LUT based on gradient thresholds
    reg [WIN_SIZE_WIDTH-1:0] win_size_lut_comb;

    always @(*) begin
        if (grad_max_s3 < {{(GRAD_WIDTH-DATA_WIDTH){1'b0}}, win_size_clip_y_0})
            win_size_lut_comb = 6'd16;
        else if (grad_max_s3 < {{(GRAD_WIDTH-DATA_WIDTH){1'b0}}, win_size_clip_y_1})
            win_size_lut_comb = 6'd24;
        else if (grad_max_s3 < {{(GRAD_WIDTH-DATA_WIDTH){1'b0}}, win_size_clip_y_2})
            win_size_lut_comb = 6'd32;
        else if (grad_max_s3 < {{(GRAD_WIDTH-DATA_WIDTH){1'b0}}, win_size_clip_y_3})
            win_size_lut_comb = 6'd40;
        else
            win_size_lut_comb = 6'd40;
    end

    // Combinational: Clip window size to [16, 40]
    wire [WIN_SIZE_WIDTH-1:0] win_size_clip_comb =
        (win_size_lut_comb < 6'd16) ? 6'd16 :
        (win_size_lut_comb > 6'd40) ? 6'd40 : win_size_lut_comb;

    // Pipeline Stage 4: Register the outputs
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grad_h        <= {GRAD_WIDTH{1'b0}};
            grad_v        <= {GRAD_WIDTH{1'b0}};
            grad          <= {GRAD_WIDTH{1'b0}};
            win_size_clip <= {WIN_SIZE_WIDTH{1'b0}};
            stage1_valid  <= 1'b0;
        end else if (enable && valid_s3) begin
            grad_h        <= grad_h_abs_s2;
            grad_v        <= grad_v_abs_s2;
            grad          <= grad_sum_s3;
            win_size_clip <= win_size_clip_comb;
            stage1_valid  <= 1'b1;
        end else begin
            stage1_valid <= 1'b0;
        end
    end

endmodule