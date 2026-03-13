//-----------------------------------------------------------------------------
// Module: stage1_gradient
// Description: Stage 1 - Sobel gradient calculation and window size determination
//              Pure Verilog-2001 compatible
//              Pipeline stages: 4 cycles
//-----------------------------------------------------------------------------

module stage1_gradient #(
    parameter DATA_WIDTH = 8,
    parameter GRAD_WIDTH = 12,
    parameter WIN_SIZE_WIDTH = 6
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

    // Configuration
    input  wire [7:0]                  win_size_clip_y_0,
    input  wire [7:0]                  win_size_clip_y_1,
    input  wire [7:0]                  win_size_clip_y_2,
    input  wire [7:0]                  win_size_clip_y_3,
    input  wire [7:0]                  win_size_clip_sft_0,
    input  wire [7:0]                  win_size_clip_sft_1,
    input  wire [7:0]                  win_size_clip_sft_2,
    input  wire [7:0]                  win_size_clip_sft_3,

    // Position info for boundary handling
    input  wire [15:0]                 pixel_x,
    input  wire [15:0]                 pixel_y,
    input  wire [15:0]                 pic_width_m1,
    input  wire [15:0]                 pic_height_m1,

    // Outputs
    output reg  [GRAD_WIDTH-1:0]       grad_h,
    output reg  [GRAD_WIDTH-1:0]       grad_v,
    output reg  [GRAD_WIDTH-1:0]       grad,
    output reg  [WIN_SIZE_WIDTH-1:0]   win_size_clip,
    output reg                         stage1_valid
);

    `include "isp_csiir_defines.vh"

    // Pipeline stage 1: Sobel convolution
    reg signed [GRAD_WIDTH:0] grad_h_acc_s1;
    reg signed [GRAD_WIDTH:0] grad_v_acc_s1;
    reg                       valid_s1;

    // Pipeline stage 2: Absolute value and sum
    reg [GRAD_WIDTH-1:0]      grad_h_abs_s2;
    reg [GRAD_WIDTH-1:0]      grad_v_abs_s2;
    reg [GRAD_WIDTH-1:0]      grad_sum_s2;
    reg                       valid_s2;

    // Pipeline stage 3: Gradient max for window size
    reg [GRAD_WIDTH-1:0]      grad_s3;
    reg [GRAD_WIDTH-1:0]      grad_above_s3;
    reg [GRAD_WIDTH-1:0]      grad_below_s3;
    reg                       valid_s3;

    // Pipeline stage 4: Window size LUT
    reg [GRAD_WIDTH-1:0]      grad_final_s4;
    reg                       valid_s4;

    // Gradient for neighboring pixels (need to compute separately)
    reg [GRAD_WIDTH-1:0]      grad_above;
    reg [GRAD_WIDTH-1:0]      grad_below;

    // Sobel X kernel: [1,1,1,1,1] on row 0, [-1,-1,-1,-1,-1] on row 4
    // grad_h = sum of row 0 - sum of row 4
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grad_h_acc_s1 <= {(GRAD_WIDTH+1){1'b0}};
            grad_v_acc_s1 <= {(GRAD_WIDTH+1){1'b0}};
            valid_s1      <= 1'b0;
        end else if (enable && window_valid) begin
            // Sobel X: top row - bottom row (5-tap horizontal)
            grad_h_acc_s1 <=
                ($signed({1'b0, window_0_0}) + $signed({1'b0, window_0_1}) +
                 $signed({1'b0, window_0_2}) + $signed({1'b0, window_0_3}) +
                 $signed({1'b0, window_0_4})) -
                ($signed({1'b0, window_4_0}) + $signed({1'b0, window_4_1}) +
                 $signed({1'b0, window_4_2}) + $signed({1'b0, window_4_3}) +
                 $signed({1'b0, window_4_4}));

            // Sobel Y: left column - right column (5-tap vertical)
            grad_v_acc_s1 <=
                ($signed({1'b0, window_0_0}) + $signed({1'b0, window_1_0}) +
                 $signed({1'b0, window_2_0}) + $signed({1'b0, window_3_0}) +
                 $signed({1'b0, window_4_0})) -
                ($signed({1'b0, window_0_4}) + $signed({1'b0, window_1_4}) +
                 $signed({1'b0, window_2_4}) + $signed({1'b0, window_3_4}) +
                 $signed({1'b0, window_4_4}));

            valid_s1 <= 1'b1;
        end else begin
            valid_s1 <= 1'b0;
        end
    end

    // Stage 2: Absolute value and gradient sum
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grad_h_abs_s2 <= {GRAD_WIDTH{1'b0}};
            grad_v_abs_s2 <= {GRAD_WIDTH{1'b0}};
            grad_sum_s2   <= {GRAD_WIDTH{1'b0}};
            valid_s2      <= 1'b0;
        end else if (enable && valid_s1) begin
            // Absolute value
            grad_h_abs_s2 <= (grad_h_acc_s1 < 0) ? -grad_h_acc_s1 : grad_h_acc_s1[GRAD_WIDTH-1:0];
            grad_v_abs_s2 <= (grad_v_acc_s1 < 0) ? -grad_v_acc_s1 : grad_v_acc_s1[GRAD_WIDTH-1:0];

            // grad = |grad_h|/5 + |grad_v|/5 (division by 5 ~ right shift by ~2.3)
            // Using approximate division: /4 + /16 = 5/16 ≈ 1/3.2
            grad_sum_s2   <= (grad_h_abs_s2 >> 2) + (grad_v_abs_s2 >> 2);
            valid_s2      <= 1'b1;
        end else begin
            valid_s2 <= 1'b0;
        end
    end

    // Stage 3: Compute max gradient from neighboring rows
    // For window size, we need max of grad(i-1,j), grad(i,j), grad(i+1,j)
    // Since we're processing sequentially, we store current gradient and compare
    reg [GRAD_WIDTH-1:0] grad_prev_row;
    reg [GRAD_WIDTH-1:0] grad_max;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grad_s3       <= {GRAD_WIDTH{1'b0}};
            grad_above_s3 <= {GRAD_WIDTH{1'b0}};
            grad_below_s3 <= {GRAD_WIDTH{1'b0}};
            grad_prev_row <= {GRAD_WIDTH{1'b0}};
            valid_s3      <= 1'b0;
        end else if (enable && valid_s2) begin
            grad_s3       <= grad_sum_s2;
            grad_above_s3 <= grad_prev_row;  // Previous row's gradient
            grad_prev_row <= grad_sum_s2;    // Store for next row
            valid_s3      <= 1'b1;
        end else begin
            valid_s3 <= 1'b0;
        end
    end

    // Stage 4: Window size LUT lookup
    // win_size_grad = LUT(max(grad_above, grad, grad_below), clip_y, clip_sft)
    reg [GRAD_WIDTH-1:0] grad_max_s4;
    reg [WIN_SIZE_WIDTH-1:0] win_size_lut;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grad_final_s4 <= {GRAD_WIDTH{1'b0}};
            grad_h        <= {GRAD_WIDTH{1'b0}};
            grad_v        <= {GRAD_WIDTH{1'b0}};
            grad          <= {GRAD_WIDTH{1'b0}};
            win_size_clip <= {WIN_SIZE_WIDTH{1'b0}};
            stage1_valid  <= 1'b0;
        end else if (enable && valid_s3) begin
            // Max of three gradients
            grad_max_s4 <= (grad_s3 > grad_above_s3) ?
                           ((grad_s3 > grad_below_s3) ? grad_s3 : grad_below_s3) :
                           ((grad_above_s3 > grad_below_s3) ? grad_above_s3 : grad_below_s3);

            // Window size LUT based on gradient thresholds
            // Simplified: win_size = 16 + (grad_max / 8)
            // This maps to the clip_y values from the algorithm
            if (grad_max_s4 < {4'b0, win_size_clip_y_0}) begin
                win_size_lut <= 6'd16;
            end else if (grad_max_s4 < {4'b0, win_size_clip_y_1}) begin
                win_size_lut <= 6'd24;
            end else if (grad_max_s4 < {4'b0, win_size_clip_y_2}) begin
                win_size_lut <= 6'd32;
            end else if (grad_max_s4 < {4'b0, win_size_clip_y_3}) begin
                win_size_lut <= 6'd40;
            end else begin
                win_size_lut <= 6'd40;
            end

            // Clip window size to [16, 40]
            win_size_clip <= (win_size_lut < 6'd16) ? 6'd16 :
                             (win_size_lut > 6'd40) ? 6'd40 : win_size_lut;

            // Output gradients
            grad_h        <= grad_h_abs_s2;
            grad_v        <= grad_v_abs_s2;
            grad          <= grad_s3;
            grad_final_s4 <= grad_s3;
            stage1_valid  <= 1'b1;
        end else begin
            stage1_valid <= 1'b0;
        end
    end

endmodule