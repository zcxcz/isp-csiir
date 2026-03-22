//-----------------------------------------------------------------------------
// Module: stage2_directional_avg
// Purpose: Multi-scale directional averaging
// Author: rtl-impl
// Date: 2026-03-22
// Version: v2.0 - Added signed data conversion
//-----------------------------------------------------------------------------
// Description:
//   Implements Stage 2 of ISP-CSIIR pipeline:
//   - u10 to s11 conversion (window pixels)
//   - Kernel selection based on window size
//   - Weighted sum calculation for 5 directions (signed arithmetic)
//   - Division for average calculation
//   - Two scales: avg0 (smaller) and avg1 (larger)
//
// Data Format:
//   - Input window: u10 (10-bit unsigned, range 0-1023)
//   - Internal calculation: s11 (11-bit signed, range -512 to +511)
//   - Output avg: s11 (11-bit signed)
//
// Pipeline Structure (8 cycles):
//   Cycle 0-3: Window delay alignment
//   Cycle 4: Kernel selection + u10->s11 conversion
//   Cycle 5: Weighted sum (first stage)
//   Cycle 6: Weighted sum (second stage)
//   Cycle 7: Division output
//-----------------------------------------------------------------------------

module stage2_directional_avg #(
    parameter DATA_WIDTH     = 10,
    parameter SIGNED_WIDTH   = 11,   // Signed data width
    parameter GRAD_WIDTH     = 14,
    parameter WIN_SIZE_WIDTH = 6,
    parameter ACC_WIDTH      = 20,
    parameter LINE_ADDR_WIDTH = 14,
    parameter ROW_CNT_WIDTH  = 13
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // 5x5 Window input (u10 format, delayed from Stage 1)
    input  wire [DATA_WIDTH-1:0]       window_0_0, window_0_1, window_0_2, window_0_3, window_0_4,
    input  wire [DATA_WIDTH-1:0]       window_1_0, window_1_1, window_1_2, window_1_3, window_1_4,
    input  wire [DATA_WIDTH-1:0]       window_2_0, window_2_1, window_2_2, window_2_3, window_2_4,
    input  wire [DATA_WIDTH-1:0]       window_3_0, window_3_1, window_3_2, window_3_3, window_3_4,
    input  wire [DATA_WIDTH-1:0]       window_4_0, window_4_1, window_4_2, window_4_3, window_4_4,

    // Stage 1 outputs
    input  wire [GRAD_WIDTH-1:0]       grad_h,
    input  wire [GRAD_WIDTH-1:0]       grad_v,
    input  wire [GRAD_WIDTH-1:0]       grad,
    input  wire [WIN_SIZE_WIDTH-1:0]   win_size_clip,
    input  wire                        stage1_valid,
    input  wire [DATA_WIDTH-1:0]       center_pixel,

    // Configuration
    input  wire [15:0]                 win_size_thresh0,
    input  wire [15:0]                 win_size_thresh1,
    input  wire [15:0]                 win_size_thresh2,
    input  wire [15:0]                 win_size_thresh3,

    // Output (s11 signed format)
    output reg  signed [SIGNED_WIDTH-1:0] avg0_c, avg0_u, avg0_d, avg0_l, avg0_r,
    output reg  signed [SIGNED_WIDTH-1:0] avg1_c, avg1_u, avg1_d, avg1_l, avg1_r,
    output reg                         stage2_valid,

    // Pass through signals
    input  wire [LINE_ADDR_WIDTH-1:0]  pixel_x,
    input  wire [ROW_CNT_WIDTH-1:0]    pixel_y,
    output reg  [LINE_ADDR_WIDTH-1:0]  pixel_x_out,
    output reg  [ROW_CNT_WIDTH-1:0]    pixel_y_out,
    output reg  [GRAD_WIDTH-1:0]       grad_out,
    output reg  [WIN_SIZE_WIDTH-1:0]   win_size_clip_out,
    output reg  [DATA_WIDTH-1:0]       center_pixel_out
);

    //=========================================================================
    // Cycle 0-3: Window and Pipeline Signal Delay
    //=========================================================================
    // Delay line for window signals (4 cycles to align with Stage 1 output)
    reg [DATA_WIDTH-1:0] window_dly [0:3][0:4][0:4];
    reg [GRAD_WIDTH-1:0] grad_dly [0:3];
    reg [WIN_SIZE_WIDTH-1:0] win_size_dly [0:3];
    reg valid_dly [0:3];
    reg [DATA_WIDTH-1:0] center_dly [0:3];
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_dly [0:3];
    reg [ROW_CNT_WIDTH-1:0] pixel_y_dly [0:3];

    integer i, r, c;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 4; i = i + 1) begin
                for (r = 0; r < 5; r = r + 1) begin
                    for (c = 0; c < 5; c = c + 1) begin
                        window_dly[i][r][c] <= {DATA_WIDTH{1'b0}};
                    end
                end
                grad_dly[i]     <= {GRAD_WIDTH{1'b0}};
                win_size_dly[i] <= {WIN_SIZE_WIDTH{1'b0}};
                valid_dly[i]    <= 1'b0;
                center_dly[i]   <= {DATA_WIDTH{1'b0}};
                pixel_x_dly[i]  <= {LINE_ADDR_WIDTH{1'b0}};
                pixel_y_dly[i]  <= {ROW_CNT_WIDTH{1'b0}};
            end
        end else if (enable) begin
            // Shift delay chain
            for (i = 3; i > 0; i = i - 1) begin
                for (r = 0; r < 5; r = r + 1) begin
                    for (c = 0; c < 5; c = c + 1) begin
                        window_dly[i][r][c] <= window_dly[i-1][r][c];
                    end
                end
                grad_dly[i]     <= grad_dly[i-1];
                win_size_dly[i] <= win_size_dly[i-1];
                valid_dly[i]    <= valid_dly[i-1];
                center_dly[i]   <= center_dly[i-1];
                pixel_x_dly[i]  <= pixel_x_dly[i-1];
                pixel_y_dly[i]  <= pixel_y_dly[i-1];
            end
            // First stage from inputs
            window_dly[0][0][0] <= window_0_0; window_dly[0][0][1] <= window_0_1;
            window_dly[0][0][2] <= window_0_2; window_dly[0][0][3] <= window_0_3;
            window_dly[0][0][4] <= window_0_4;
            window_dly[0][1][0] <= window_1_0; window_dly[0][1][1] <= window_1_1;
            window_dly[0][1][2] <= window_1_2; window_dly[0][1][3] <= window_1_3;
            window_dly[0][1][4] <= window_1_4;
            window_dly[0][2][0] <= window_2_0; window_dly[0][2][1] <= window_2_1;
            window_dly[0][2][2] <= window_2_2; window_dly[0][2][3] <= window_2_3;
            window_dly[0][2][4] <= window_2_4;
            window_dly[0][3][0] <= window_3_0; window_dly[0][3][1] <= window_3_1;
            window_dly[0][3][2] <= window_3_2; window_dly[0][3][3] <= window_3_3;
            window_dly[0][3][4] <= window_3_4;
            window_dly[0][4][0] <= window_4_0; window_dly[0][4][1] <= window_4_1;
            window_dly[0][4][2] <= window_4_2; window_dly[0][4][3] <= window_4_3;
            window_dly[0][4][4] <= window_4_4;
            grad_dly[0]     <= grad;
            win_size_dly[0] <= win_size_clip;
            valid_dly[0]    <= stage1_valid;
            center_dly[0]   <= center_pixel;
            pixel_x_dly[0]  <= pixel_x;
            pixel_y_dly[0]  <= pixel_y;
        end
    end

    //=========================================================================
    // Cycle 4: Kernel Selection + u10 to s11 Conversion
    //=========================================================================
    // Kernel selection based on window size thresholds
    wire [2:0] kernel_select_comb;
    assign kernel_select_comb = (win_size_dly[3] < win_size_thresh0[WIN_SIZE_WIDTH-1:0]) ? 3'd0 :  // 2x2 kernel
                                (win_size_dly[3] < win_size_thresh1[WIN_SIZE_WIDTH-1:0]) ? 3'd1 :  // 2x2 + 3x3
                                (win_size_dly[3] < win_size_thresh2[WIN_SIZE_WIDTH-1:0]) ? 3'd2 :  // 3x3 + 4x4
                                (win_size_dly[3] < win_size_thresh3[WIN_SIZE_WIDTH-1:0]) ? 3'd3 :  // 4x4 + 5x5
                                3'd4;  // 5x5 only

    //=========================================================================
    // u10 to s11 Conversion (Combinational)
    //=========================================================================
    // Convert all 25 window pixels from u10 to s11
    // s11 = u10 - 512 (shift zero point from 0 to 512)
    wire signed [SIGNED_WIDTH-1:0] window_s11 [0:4][0:4];

    genvar gr, gc;
    generate
        for (gr = 0; gr < 5; gr = gr + 1) begin : gen_row_conv
            for (gc = 0; gc < 5; gc = gc + 1) begin : gen_col_conv
                // s11 = {1'b0, u10} - 512
                assign window_s11[gr][gc] = $signed({1'b0, window_dly[3][gr][gc]}) - $signed(11'sd512);
            end
        end
    endgenerate

    // Pipeline registers
    reg [2:0] kernel_select_s4;
    reg signed [SIGNED_WIDTH-1:0] win_s4 [0:4][0:4];  // Signed window
    reg                  valid_s4;
    reg [DATA_WIDTH-1:0] center_s4;
    reg [WIN_SIZE_WIDTH-1:0] win_size_s4;
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_s4;
    reg [ROW_CNT_WIDTH-1:0] pixel_y_s4;
    reg [GRAD_WIDTH-1:0] grad_s4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            kernel_select_s4 <= 3'd0;
            valid_s4         <= 1'b0;
            center_s4        <= {DATA_WIDTH{1'b0}};
            win_size_s4      <= {WIN_SIZE_WIDTH{1'b0}};
            pixel_x_s4       <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s4       <= {ROW_CNT_WIDTH{1'b0}};
            grad_s4          <= {GRAD_WIDTH{1'b0}};
            for (r = 0; r < 5; r = r + 1) begin
                for (c = 0; c < 5; c = c + 1) begin
                    win_s4[r][c] <= {SIGNED_WIDTH{1'b0}};
                end
            end
        end else if (enable) begin
            kernel_select_s4 <= kernel_select_comb;
            valid_s4         <= valid_dly[3];
            center_s4        <= center_dly[3];
            win_size_s4      <= win_size_dly[3];
            pixel_x_s4       <= pixel_x_dly[3];
            pixel_y_s4       <= pixel_y_dly[3];
            grad_s4          <= grad_dly[3];
            // Store signed window values
            for (r = 0; r < 5; r = r + 1) begin
                for (c = 0; c < 5; c = c + 1) begin
                    win_s4[r][c] <= window_s11[r][c];
                end
            end
        end
    end

    //=========================================================================
    // Cycle 5: Weighted Sum (First Stage) - Signed Arithmetic
    //=========================================================================
    // Calculate sums for each direction (5x5 window, signed)
    // Center (C): sum of all 25 pixels
    wire signed [ACC_WIDTH-1:0] sum_center_comb = win_s4[0][0] + win_s4[0][1] + win_s4[0][2] + win_s4[0][3] + win_s4[0][4] +
                                                 win_s4[1][0] + win_s4[1][1] + win_s4[1][2] + win_s4[1][3] + win_s4[1][4] +
                                                 win_s4[2][0] + win_s4[2][1] + win_s4[2][2] + win_s4[2][3] + win_s4[2][4] +
                                                 win_s4[3][0] + win_s4[3][1] + win_s4[3][2] + win_s4[3][3] + win_s4[3][4] +
                                                 win_s4[4][0] + win_s4[4][1] + win_s4[4][2] + win_s4[4][3] + win_s4[4][4];

    // Up (U): sum of top 3 rows
    wire signed [ACC_WIDTH-1:0] sum_up_comb = win_s4[0][0] + win_s4[0][1] + win_s4[0][2] + win_s4[0][3] + win_s4[0][4] +
                                              win_s4[1][0] + win_s4[1][1] + win_s4[1][2] + win_s4[1][3] + win_s4[1][4] +
                                              win_s4[2][0] + win_s4[2][1] + win_s4[2][2] + win_s4[2][3] + win_s4[2][4];

    // Down (D): sum of bottom 3 rows
    wire signed [ACC_WIDTH-1:0] sum_down_comb = win_s4[2][0] + win_s4[2][1] + win_s4[2][2] + win_s4[2][3] + win_s4[2][4] +
                                                win_s4[3][0] + win_s4[3][1] + win_s4[3][2] + win_s4[3][3] + win_s4[3][4] +
                                                win_s4[4][0] + win_s4[4][1] + win_s4[4][2] + win_s4[4][3] + win_s4[4][4];

    // Left (L): sum of left 3 columns
    wire signed [ACC_WIDTH-1:0] sum_left_comb = win_s4[0][0] + win_s4[0][1] + win_s4[0][2] +
                                                win_s4[1][0] + win_s4[1][1] + win_s4[1][2] +
                                                win_s4[2][0] + win_s4[2][1] + win_s4[2][2] +
                                                win_s4[3][0] + win_s4[3][1] + win_s4[3][2] +
                                                win_s4[4][0] + win_s4[4][1] + win_s4[4][2];

    // Right (R): sum of right 3 columns
    wire signed [ACC_WIDTH-1:0] sum_right_comb = win_s4[0][2] + win_s4[0][3] + win_s4[0][4] +
                                                 win_s4[1][2] + win_s4[1][3] + win_s4[1][4] +
                                                 win_s4[2][2] + win_s4[2][3] + win_s4[2][4] +
                                                 win_s4[3][2] + win_s4[3][3] + win_s4[3][4] +
                                                 win_s4[4][2] + win_s4[4][3] + win_s4[4][4];

    // Pipeline registers for Cycle 5
    reg signed [ACC_WIDTH-1:0] sum_center_s5, sum_up_s5, sum_down_s5, sum_left_s5, sum_right_s5;
    reg                 valid_s5;
    reg [2:0]           kernel_s5;
    reg [DATA_WIDTH-1:0] center_s5;
    reg [WIN_SIZE_WIDTH-1:0] win_size_s5;
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_s5;
    reg [ROW_CNT_WIDTH-1:0] pixel_y_s5;
    reg [GRAD_WIDTH-1:0] grad_s5;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_center_s5 <= {ACC_WIDTH{1'b0}};
            sum_up_s5     <= {ACC_WIDTH{1'b0}};
            sum_down_s5   <= {ACC_WIDTH{1'b0}};
            sum_left_s5   <= {ACC_WIDTH{1'b0}};
            sum_right_s5  <= {ACC_WIDTH{1'b0}};
            valid_s5      <= 1'b0;
            kernel_s5     <= 3'd0;
            center_s5     <= {DATA_WIDTH{1'b0}};
            win_size_s5   <= {WIN_SIZE_WIDTH{1'b0}};
            pixel_x_s5    <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s5    <= {ROW_CNT_WIDTH{1'b0}};
            grad_s5       <= {GRAD_WIDTH{1'b0}};
        end else if (enable) begin
            sum_center_s5 <= sum_center_comb;
            sum_up_s5     <= sum_up_comb;
            sum_down_s5   <= sum_down_comb;
            sum_left_s5   <= sum_left_comb;
            sum_right_s5  <= sum_right_comb;
            valid_s5      <= valid_s4;
            kernel_s5     <= kernel_select_s4;
            center_s5     <= center_s4;
            win_size_s5   <= win_size_s4;
            pixel_x_s5    <= pixel_x_s4;
            pixel_y_s5    <= pixel_y_s4;
            grad_s5       <= grad_s4;
        end
    end

    //=========================================================================
    // Cycle 6: Weight Normalization
    //=========================================================================
    // Weights for division
    wire [7:0] weight_center = 8'd25;  // 5x5 = 25
    wire [7:0] weight_15     = 8'd15;  // 3x5 = 15
    wire [7:0] weight_15_col = 8'd15;  // 5x3 = 15

    // Pipeline registers for Cycle 6
    reg signed [ACC_WIDTH-1:0] sum_c_s6, sum_u_s6, sum_d_s6, sum_l_s6, sum_r_s6;
    reg [7:0]           w_c_s6, w_u_s6, w_d_s6, w_l_s6, w_r_s6;
    reg                 valid_s6;
    reg [DATA_WIDTH-1:0] center_s6;
    reg [WIN_SIZE_WIDTH-1:0] win_size_s6;
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_s6;
    reg [ROW_CNT_WIDTH-1:0] pixel_y_s6;
    reg [GRAD_WIDTH-1:0] grad_s6;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_c_s6 <= {ACC_WIDTH{1'b0}};
            sum_u_s6 <= {ACC_WIDTH{1'b0}};
            sum_d_s6 <= {ACC_WIDTH{1'b0}};
            sum_l_s6 <= {ACC_WIDTH{1'b0}};
            sum_r_s6 <= {ACC_WIDTH{1'b0}};
            w_c_s6   <= 8'd25;
            w_u_s6   <= 8'd15;
            w_d_s6   <= 8'd15;
            w_l_s6   <= 8'd15;
            w_r_s6   <= 8'd15;
            valid_s6 <= 1'b0;
            center_s6 <= {DATA_WIDTH{1'b0}};
            win_size_s6 <= {WIN_SIZE_WIDTH{1'b0}};
            pixel_x_s6 <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s6 <= {ROW_CNT_WIDTH{1'b0}};
            grad_s6 <= {GRAD_WIDTH{1'b0}};
        end else if (enable) begin
            sum_c_s6 <= sum_center_s5;
            sum_u_s6 <= sum_up_s5;
            sum_d_s6 <= sum_down_s5;
            sum_l_s6 <= sum_left_s5;
            sum_r_s6 <= sum_right_s5;
            w_c_s6   <= weight_center;
            w_u_s6   <= weight_15;
            w_d_s6   <= weight_15;
            w_l_s6   <= weight_15_col;
            w_r_s6   <= weight_15_col;
            valid_s6 <= valid_s5;
            center_s6 <= center_s5;
            win_size_s6 <= win_size_s5;
            pixel_x_s6 <= pixel_x_s5;
            pixel_y_s6 <= pixel_y_s5;
            grad_s6 <= grad_s5;
        end
    end

    //=========================================================================
    // Cycle 7: Division Output (Signed)
    //=========================================================================
    // Integer division for averages (signed result)
    // For avg0: use same calculation as avg1 (simplified for this implementation)
    wire signed [SIGNED_WIDTH-1:0] avg0_c_comb = (w_c_s6 != 0) ? (sum_c_s6 / $signed({1'b0, w_c_s6})) : {SIGNED_WIDTH{1'b0}};
    wire signed [SIGNED_WIDTH-1:0] avg0_u_comb = (w_u_s6 != 0) ? (sum_u_s6 / $signed({1'b0, w_u_s6})) : {SIGNED_WIDTH{1'b0}};
    wire signed [SIGNED_WIDTH-1:0] avg0_d_comb = (w_d_s6 != 0) ? (sum_d_s6 / $signed({1'b0, w_d_s6})) : {SIGNED_WIDTH{1'b0}};
    wire signed [SIGNED_WIDTH-1:0] avg0_l_comb = (w_l_s6 != 0) ? (sum_l_s6 / $signed({1'b0, w_l_s6})) : {SIGNED_WIDTH{1'b0}};
    wire signed [SIGNED_WIDTH-1:0] avg0_r_comb = (w_r_s6 != 0) ? (sum_r_s6 / $signed({1'b0, w_r_s6})) : {SIGNED_WIDTH{1'b0}};

    // avg1 uses same calculation (for this simplified implementation)
    wire signed [SIGNED_WIDTH-1:0] avg1_c_comb = avg0_c_comb;
    wire signed [SIGNED_WIDTH-1:0] avg1_u_comb = avg0_u_comb;
    wire signed [SIGNED_WIDTH-1:0] avg1_d_comb = avg0_d_comb;
    wire signed [SIGNED_WIDTH-1:0] avg1_l_comb = avg0_l_comb;
    wire signed [SIGNED_WIDTH-1:0] avg1_r_comb = avg0_r_comb;

    // Output registers
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            avg0_c          <= {SIGNED_WIDTH{1'b0}};
            avg0_u          <= {SIGNED_WIDTH{1'b0}};
            avg0_d          <= {SIGNED_WIDTH{1'b0}};
            avg0_l          <= {SIGNED_WIDTH{1'b0}};
            avg0_r          <= {SIGNED_WIDTH{1'b0}};
            avg1_c          <= {SIGNED_WIDTH{1'b0}};
            avg1_u          <= {SIGNED_WIDTH{1'b0}};
            avg1_d          <= {SIGNED_WIDTH{1'b0}};
            avg1_l          <= {SIGNED_WIDTH{1'b0}};
            avg1_r          <= {SIGNED_WIDTH{1'b0}};
            stage2_valid    <= 1'b0;
            pixel_x_out     <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_out     <= {ROW_CNT_WIDTH{1'b0}};
            grad_out        <= {GRAD_WIDTH{1'b0}};
            win_size_clip_out <= {WIN_SIZE_WIDTH{1'b0}};
            center_pixel_out <= {DATA_WIDTH{1'b0}};
        end else if (enable) begin
            avg0_c          <= avg0_c_comb;
            avg0_u          <= avg0_u_comb;
            avg0_d          <= avg0_d_comb;
            avg0_l          <= avg0_l_comb;
            avg0_r          <= avg0_r_comb;
            avg1_c          <= avg1_c_comb;
            avg1_u          <= avg1_u_comb;
            avg1_d          <= avg1_d_comb;
            avg1_l          <= avg1_l_comb;
            avg1_r          <= avg1_r_comb;
            stage2_valid    <= valid_s6;
            pixel_x_out     <= pixel_x_s6;
            pixel_y_out     <= pixel_y_s6;
            grad_out        <= grad_s6;
            win_size_clip_out <= win_size_s6;
            center_pixel_out <= center_s6;
        end
    end

endmodule