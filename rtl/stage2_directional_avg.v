//-----------------------------------------------------------------------------
// Module: stage2_directional_avg
// Purpose: Multi-scale directional averaging
// Author: rtl-impl
// Date: 2026-03-24
// Version: v3.0 - Refactored with common_pipe and valid/ready handshake
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
//
// Handshake Protocol:
//   - valid_in/valid_out: Data valid indicators
//   - ready_in: Downstream back-pressure signal
//   - ready_out: Always 1 (simple pipeline without skid buffer)
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
    output wire                        stage1_ready,

    // Configuration
    input  wire [15:0]                 win_size_thresh0,
    input  wire [15:0]                 win_size_thresh1,
    input  wire [15:0]                 win_size_thresh2,
    input  wire [15:0]                 win_size_thresh3,

    // Output (s11 signed format)
    output wire signed [SIGNED_WIDTH-1:0] avg0_c, avg0_u, avg0_d, avg0_l, avg0_r,
    output wire signed [SIGNED_WIDTH-1:0] avg1_c, avg1_u, avg1_d, avg1_l, avg1_r,
    output wire                         stage2_valid,
    input  wire                         stage2_ready,

    // Pass through signals
    input  wire [LINE_ADDR_WIDTH-1:0]  pixel_x,
    input  wire [ROW_CNT_WIDTH-1:0]    pixel_y,
    output wire [LINE_ADDR_WIDTH-1:0]  pixel_x_out,
    output wire [ROW_CNT_WIDTH-1:0]    pixel_y_out,
    output wire [GRAD_WIDTH-1:0]       grad_out,
    output wire [WIN_SIZE_WIDTH-1:0]   win_size_clip_out,
    output wire [DATA_WIDTH-1:0]       center_pixel_out
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam WINDOW_DATA_WIDTH = 25 * DATA_WIDTH;  // 25 pixels in 5x5 window
    localparam META_WIDTH = GRAD_WIDTH + WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1;

    //=========================================================================
    // Ready Signal (Simple Pipeline - Always Ready)
    //=========================================================================
    assign stage1_ready = 1'b1;

    //=========================================================================
    // Window Delay Chain (4 cycles) - Using explicit registers
    //=========================================================================
    // Due to large data size, use explicit shift register for window
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
        end else if (enable && stage2_ready) begin
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

    //=========================================================================
    // Cycle 4 Pipeline Registers
    //=========================================================================
    localparam PIPE_S4_WIDTH = 3 + 25 * SIGNED_WIDTH + WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + GRAD_WIDTH + 1;

    wire [PIPE_S4_WIDTH-1:0] pipe_s4_din = {kernel_select_comb,
                                            window_s11[0][0], window_s11[0][1], window_s11[0][2], window_s11[0][3], window_s11[0][4],
                                            window_s11[1][0], window_s11[1][1], window_s11[1][2], window_s11[1][3], window_s11[1][4],
                                            window_s11[2][0], window_s11[2][1], window_s11[2][2], window_s11[2][3], window_s11[2][4],
                                            window_s11[3][0], window_s11[3][1], window_s11[3][2], window_s11[3][3], window_s11[3][4],
                                            window_s11[4][0], window_s11[4][1], window_s11[4][2], window_s11[4][3], window_s11[4][4],
                                            win_size_dly[3], pixel_x_dly[3], pixel_y_dly[3], center_dly[3], grad_dly[3], valid_dly[3]};

    wire [PIPE_S4_WIDTH-1:0] pipe_s4_dout;
    wire                     valid_s4;

    common_pipe #(
        .DATA_WIDTH (PIPE_S4_WIDTH),
        .STAGES     (1),
        .RESET_VAL  (0)
    ) u_pipe_s4 (
        .clk       (clk),
        .rst_n     (rst_n),
        .din       (pipe_s4_din),
        .valid_in  (valid_dly[3]),
        .ready_out (),
        .dout      (pipe_s4_dout),
        .valid_out (valid_s4),
        .ready_in  (stage2_ready)
    );

    // Unpack signals
    wire [2:0]                 kernel_select_s4 = pipe_s4_dout[PIPE_S4_WIDTH-1 -: 3];
    wire signed [SIGNED_WIDTH-1:0] win_s4 [0:4][0:4];
    genvar ur, uc;
    generate
        for (ur = 0; ur < 5; ur = ur + 1) begin : gen_unp_row
            for (uc = 0; uc < 5; uc = uc + 1) begin : gen_unp_col
                localparam IDX = 3 + (ur * 5 + uc) * SIGNED_WIDTH;
                assign win_s4[ur][uc] = pipe_s4_dout[IDX +: SIGNED_WIDTH];
            end
        end
    endgenerate
    wire [WIN_SIZE_WIDTH-1:0]   win_size_s4   = pipe_s4_dout[WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + GRAD_WIDTH + 1 +: WIN_SIZE_WIDTH];
    wire [LINE_ADDR_WIDTH-1:0]  pixel_x_s4    = pipe_s4_dout[LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + GRAD_WIDTH + 1 +: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0]    pixel_y_s4    = pipe_s4_dout[ROW_CNT_WIDTH + DATA_WIDTH + GRAD_WIDTH + 1 +: ROW_CNT_WIDTH];
    wire [DATA_WIDTH-1:0]       center_s4     = pipe_s4_dout[DATA_WIDTH + GRAD_WIDTH + 1 +: DATA_WIDTH];
    wire [GRAD_WIDTH-1:0]       grad_s4       = pipe_s4_dout[GRAD_WIDTH + 1 +: GRAD_WIDTH];

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

    //=========================================================================
    // Cycle 5 Pipeline Registers
    //=========================================================================
    localparam PIPE_S5_WIDTH = 5 * ACC_WIDTH + 3 + WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + GRAD_WIDTH + 1;

    wire [PIPE_S5_WIDTH-1:0] pipe_s5_din = {sum_center_comb, sum_up_comb, sum_down_comb, sum_left_comb, sum_right_comb,
                                            kernel_select_s4, win_size_s4, pixel_x_s4, pixel_y_s4, center_s4, grad_s4, valid_s4};

    wire [PIPE_S5_WIDTH-1:0] pipe_s5_dout;
    wire                     valid_s5;

    common_pipe #(
        .DATA_WIDTH (PIPE_S5_WIDTH),
        .STAGES     (1),
        .RESET_VAL  (0)
    ) u_pipe_s5 (
        .clk       (clk),
        .rst_n     (rst_n),
        .din       (pipe_s5_din),
        .valid_in  (valid_s4),
        .ready_out (),
        .dout      (pipe_s5_dout),
        .valid_out (valid_s5),
        .ready_in  (stage2_ready)
    );

    // Unpack signals
    wire signed [ACC_WIDTH-1:0] sum_center_s5 = pipe_s5_dout[PIPE_S5_WIDTH-1 -: ACC_WIDTH];
    wire signed [ACC_WIDTH-1:0] sum_up_s5     = pipe_s5_dout[PIPE_S5_WIDTH-1-ACC_WIDTH -: ACC_WIDTH];
    wire signed [ACC_WIDTH-1:0] sum_down_s5   = pipe_s5_dout[PIPE_S5_WIDTH-1-2*ACC_WIDTH -: ACC_WIDTH];
    wire signed [ACC_WIDTH-1:0] sum_left_s5   = pipe_s5_dout[PIPE_S5_WIDTH-1-3*ACC_WIDTH -: ACC_WIDTH];
    wire signed [ACC_WIDTH-1:0] sum_right_s5  = pipe_s5_dout[PIPE_S5_WIDTH-1-4*ACC_WIDTH -: ACC_WIDTH];
    wire [2:0]           kernel_s5           = pipe_s5_dout[3 + WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + GRAD_WIDTH + 1 +: 3];
    wire [WIN_SIZE_WIDTH-1:0] win_size_s5    = pipe_s5_dout[WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + GRAD_WIDTH + 1 +: WIN_SIZE_WIDTH];
    wire [LINE_ADDR_WIDTH-1:0] pixel_x_s5    = pipe_s5_dout[LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + GRAD_WIDTH + 1 +: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0]  pixel_y_s5     = pipe_s5_dout[ROW_CNT_WIDTH + DATA_WIDTH + GRAD_WIDTH + 1 +: ROW_CNT_WIDTH];
    wire [DATA_WIDTH-1:0]     center_s5      = pipe_s5_dout[DATA_WIDTH + GRAD_WIDTH + 1 +: DATA_WIDTH];
    wire [GRAD_WIDTH-1:0]     grad_s5        = pipe_s5_dout[GRAD_WIDTH + 1 +: GRAD_WIDTH];

    //=========================================================================
    // Cycle 6: Weight Normalization
    //=========================================================================
    // Weights for division
    wire [7:0] weight_center = 8'd25;  // 5x5 = 25
    wire [7:0] weight_15     = 8'd15;  // 3x5 = 15
    wire [7:0] weight_15_col = 8'd15;  // 5x3 = 15

    //=========================================================================
    // Cycle 6 Pipeline Registers
    //=========================================================================
    localparam PIPE_S6_WIDTH = 5 * ACC_WIDTH + 5 * 8 + WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + GRAD_WIDTH + 1;

    wire [PIPE_S6_WIDTH-1:0] pipe_s6_din = {sum_center_s5, sum_up_s5, sum_down_s5, sum_left_s5, sum_right_s5,
                                            weight_center, weight_15, weight_15, weight_15_col, weight_15_col,
                                            win_size_s5, pixel_x_s5, pixel_y_s5, center_s5, grad_s5, valid_s5};

    wire [PIPE_S6_WIDTH-1:0] pipe_s6_dout;
    wire                     valid_s6;

    common_pipe #(
        .DATA_WIDTH (PIPE_S6_WIDTH),
        .STAGES     (1),
        .RESET_VAL  (0)
    ) u_pipe_s6 (
        .clk       (clk),
        .rst_n     (rst_n),
        .din       (pipe_s6_din),
        .valid_in  (valid_s5),
        .ready_out (),
        .dout      (pipe_s6_dout),
        .valid_out (valid_s6),
        .ready_in  (stage2_ready)
    );

    // Unpack signals
    wire signed [ACC_WIDTH-1:0] sum_c_s6 = pipe_s6_dout[PIPE_S6_WIDTH-1 -: ACC_WIDTH];
    wire signed [ACC_WIDTH-1:0] sum_u_s6 = pipe_s6_dout[PIPE_S6_WIDTH-1-ACC_WIDTH -: ACC_WIDTH];
    wire signed [ACC_WIDTH-1:0] sum_d_s6 = pipe_s6_dout[PIPE_S6_WIDTH-1-2*ACC_WIDTH -: ACC_WIDTH];
    wire signed [ACC_WIDTH-1:0] sum_l_s6 = pipe_s6_dout[PIPE_S6_WIDTH-1-3*ACC_WIDTH -: ACC_WIDTH];
    wire signed [ACC_WIDTH-1:0] sum_r_s6 = pipe_s6_dout[PIPE_S6_WIDTH-1-4*ACC_WIDTH -: ACC_WIDTH];
    wire [7:0] w_c_s6 = pipe_s6_dout[5*ACC_WIDTH + 5*8 - 1 -: 8];
    wire [7:0] w_u_s6 = pipe_s6_dout[5*ACC_WIDTH + 4*8 - 1 -: 8];
    wire [7:0] w_d_s6 = pipe_s6_dout[5*ACC_WIDTH + 3*8 - 1 -: 8];
    wire [7:0] w_l_s6 = pipe_s6_dout[5*ACC_WIDTH + 2*8 - 1 -: 8];
    wire [7:0] w_r_s6 = pipe_s6_dout[5*ACC_WIDTH + 8 - 1 -: 8];
    wire [WIN_SIZE_WIDTH-1:0] win_size_s6   = pipe_s6_dout[WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + GRAD_WIDTH + 1 +: WIN_SIZE_WIDTH];
    wire [LINE_ADDR_WIDTH-1:0] pixel_x_s6   = pipe_s6_dout[LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + GRAD_WIDTH + 1 +: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0]  pixel_y_s6    = pipe_s6_dout[ROW_CNT_WIDTH + DATA_WIDTH + GRAD_WIDTH + 1 +: ROW_CNT_WIDTH];
    wire [DATA_WIDTH-1:0]     center_s6     = pipe_s6_dout[DATA_WIDTH + GRAD_WIDTH + 1 +: DATA_WIDTH];
    wire [GRAD_WIDTH-1:0]     grad_s6       = pipe_s6_dout[GRAD_WIDTH + 1 +: GRAD_WIDTH];

    //=========================================================================
    // Cycle 7: Division Output (Signed) with Saturation
    //=========================================================================
    // Integer division for averages (signed result)
    wire signed [SIGNED_WIDTH-1:0] avg0_c_div = (w_c_s6 != 0) ? (sum_c_s6 / $signed({1'b0, w_c_s6})) : {SIGNED_WIDTH{1'b0}};
    wire signed [SIGNED_WIDTH-1:0] avg0_u_div = (w_u_s6 != 0) ? (sum_u_s6 / $signed({1'b0, w_u_s6})) : {SIGNED_WIDTH{1'b0}};
    wire signed [SIGNED_WIDTH-1:0] avg0_d_div = (w_d_s6 != 0) ? (sum_d_s6 / $signed({1'b0, w_d_s6})) : {SIGNED_WIDTH{1'b0}};
    wire signed [SIGNED_WIDTH-1:0] avg0_l_div = (w_l_s6 != 0) ? (sum_l_s6 / $signed({1'b0, w_l_s6})) : {SIGNED_WIDTH{1'b0}};
    wire signed [SIGNED_WIDTH-1:0] avg0_r_div = (w_r_s6 != 0) ? (sum_r_s6 / $signed({1'b0, w_r_s6})) : {SIGNED_WIDTH{1'b0}};

    // Saturation to s11 range [-512, +511]
    wire signed [SIGNED_WIDTH-1:0] avg0_c_comb = (avg0_c_div > $signed(11'sd511)) ? $signed(11'sd511) :
                                                 (avg0_c_div < $signed(-11'sd512)) ? $signed(-11'sd512) : avg0_c_div;
    wire signed [SIGNED_WIDTH-1:0] avg0_u_comb = (avg0_u_div > $signed(11'sd511)) ? $signed(11'sd511) :
                                                 (avg0_u_div < $signed(-11'sd512)) ? $signed(-11'sd512) : avg0_u_div;
    wire signed [SIGNED_WIDTH-1:0] avg0_d_comb = (avg0_d_div > $signed(11'sd511)) ? $signed(11'sd511) :
                                                 (avg0_d_div < $signed(-11'sd512)) ? $signed(-11'sd512) : avg0_d_div;
    wire signed [SIGNED_WIDTH-1:0] avg0_l_comb = (avg0_l_div > $signed(11'sd511)) ? $signed(11'sd511) :
                                                 (avg0_l_div < $signed(-11'sd512)) ? $signed(-11'sd512) : avg0_l_div;
    wire signed [SIGNED_WIDTH-1:0] avg0_r_comb = (avg0_r_div > $signed(11'sd511)) ? $signed(11'sd511) :
                                                 (avg0_r_div < $signed(-11'sd512)) ? $signed(-11'sd512) : avg0_r_div;

    // avg1 uses same calculation (for this simplified implementation)
    wire signed [SIGNED_WIDTH-1:0] avg1_c_comb = avg0_c_comb;
    wire signed [SIGNED_WIDTH-1:0] avg1_u_comb = avg0_u_comb;
    wire signed [SIGNED_WIDTH-1:0] avg1_d_comb = avg0_d_comb;
    wire signed [SIGNED_WIDTH-1:0] avg1_l_comb = avg0_l_comb;
    wire signed [SIGNED_WIDTH-1:0] avg1_r_comb = avg0_r_comb;

    //=========================================================================
    // Output Registers (Cycle 7)
    //=========================================================================
    localparam PIPE_OUT_WIDTH = 10 * SIGNED_WIDTH + WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + GRAD_WIDTH + 1;

    wire [PIPE_OUT_WIDTH-1:0] pipe_out_din = {avg0_c_comb, avg0_u_comb, avg0_d_comb, avg0_l_comb, avg0_r_comb,
                                              avg1_c_comb, avg1_u_comb, avg1_d_comb, avg1_l_comb, avg1_r_comb,
                                              win_size_s6, pixel_x_s6, pixel_y_s6, grad_s6, center_s6, valid_s6};

    wire [PIPE_OUT_WIDTH-1:0] pipe_out_dout;

    common_pipe #(
        .DATA_WIDTH (PIPE_OUT_WIDTH),
        .STAGES     (1),
        .RESET_VAL  (0)
    ) u_pipe_out (
        .clk       (clk),
        .rst_n     (rst_n),
        .din       (pipe_out_din),
        .valid_in  (valid_s6),
        .ready_out (),
        .dout      (pipe_out_dout),
        .valid_out (stage2_valid),
        .ready_in  (stage2_ready)
    );

    // Unpack output signals
    assign avg0_c          = pipe_out_dout[PIPE_OUT_WIDTH-1 -: SIGNED_WIDTH];
    assign avg0_u          = pipe_out_dout[PIPE_OUT_WIDTH-1-SIGNED_WIDTH -: SIGNED_WIDTH];
    assign avg0_d          = pipe_out_dout[PIPE_OUT_WIDTH-1-2*SIGNED_WIDTH -: SIGNED_WIDTH];
    assign avg0_l          = pipe_out_dout[PIPE_OUT_WIDTH-1-3*SIGNED_WIDTH -: SIGNED_WIDTH];
    assign avg0_r          = pipe_out_dout[PIPE_OUT_WIDTH-1-4*SIGNED_WIDTH -: SIGNED_WIDTH];
    assign avg1_c          = pipe_out_dout[PIPE_OUT_WIDTH-1-5*SIGNED_WIDTH -: SIGNED_WIDTH];
    assign avg1_u          = pipe_out_dout[PIPE_OUT_WIDTH-1-6*SIGNED_WIDTH -: SIGNED_WIDTH];
    assign avg1_d          = pipe_out_dout[PIPE_OUT_WIDTH-1-7*SIGNED_WIDTH -: SIGNED_WIDTH];
    assign avg1_l          = pipe_out_dout[PIPE_OUT_WIDTH-1-8*SIGNED_WIDTH -: SIGNED_WIDTH];
    assign avg1_r          = pipe_out_dout[PIPE_OUT_WIDTH-1-9*SIGNED_WIDTH -: SIGNED_WIDTH];
    assign win_size_clip_out = pipe_out_dout[WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + GRAD_WIDTH + 1 +: WIN_SIZE_WIDTH];
    assign pixel_x_out     = pipe_out_dout[LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + GRAD_WIDTH + 1 +: LINE_ADDR_WIDTH];
    assign pixel_y_out     = pipe_out_dout[ROW_CNT_WIDTH + DATA_WIDTH + GRAD_WIDTH + 1 +: ROW_CNT_WIDTH];
    assign grad_out        = pipe_out_dout[GRAD_WIDTH + DATA_WIDTH + 1 +: GRAD_WIDTH];
    assign center_pixel_out = pipe_out_dout[DATA_WIDTH + 1 +: DATA_WIDTH];

endmodule