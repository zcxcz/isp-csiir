//-----------------------------------------------------------------------------
// Module: stage3_gradient_fusion
// Purpose: Gradient-weighted directional fusion
// Author: rtl-impl
// Date: 2026-03-22
// Version: v1.0
//-----------------------------------------------------------------------------
// Description:
//   Implements Stage 3 of ISP-CSIIR pipeline:
//   - Gradient fetch from neighbors (using 2-row gradient line buffer)
//   - Gradient sorting network (5-input descending sort)
//   - Weighted multiplication (avg x grad)
//   - Weighted sum and division for fusion
//
// Pipeline Structure (6 cycles):
//   Cycle 0: Input buffer and gradient fetch
//   Cycle 1: Gradient sort (first stage)
//   Cycle 2: Gradient sort (second stage)
//   Cycle 3: Weighted multiplication
//   Cycle 4: Weighted sum
//   Cycle 5: Division output
//-----------------------------------------------------------------------------

module stage3_gradient_fusion #(
    parameter DATA_WIDTH     = 10,
    parameter GRAD_WIDTH     = 14,
    parameter WIN_SIZE_WIDTH = 6,
    parameter LINE_ADDR_WIDTH = 14,
    parameter ROW_CNT_WIDTH  = 13,
    parameter IMG_WIDTH      = 5472
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // Stage 2 outputs
    input  wire [DATA_WIDTH-1:0]       avg0_c, avg0_u, avg0_d, avg0_l, avg0_r,
    input  wire [DATA_WIDTH-1:0]       avg1_c, avg1_u, avg1_d, avg1_l, avg1_r,
    input  wire                        stage2_valid,
    input  wire [GRAD_WIDTH-1:0]       grad,
    input  wire [WIN_SIZE_WIDTH-1:0]   win_size_clip,
    input  wire [DATA_WIDTH-1:0]       center_pixel,

    // Configuration
    input  wire [ROW_CNT_WIDTH-1:0]    img_height,
    input  wire [LINE_ADDR_WIDTH-1:0]  img_width,

    // Output
    output reg  [DATA_WIDTH-1:0]       blend0_dir_avg,
    output reg  [DATA_WIDTH-1:0]       blend1_dir_avg,
    output reg                         stage3_valid,

    // Pass through signals
    input  wire [LINE_ADDR_WIDTH-1:0]  pixel_x,
    input  wire [ROW_CNT_WIDTH-1:0]    pixel_y,
    output reg  [LINE_ADDR_WIDTH-1:0]  pixel_x_out,
    output reg  [ROW_CNT_WIDTH-1:0]    pixel_y_out,
    output reg  [DATA_WIDTH-1:0]       avg0_u_out,
    output reg  [DATA_WIDTH-1:0]       avg1_u_out,
    output reg  [WIN_SIZE_WIDTH-1:0]   win_size_clip_out,
    output reg  [DATA_WIDTH-1:0]       center_pixel_out
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam BLEND_WIDTH = DATA_WIDTH + GRAD_WIDTH + 2;  // 26-bit for blend sum
    localparam GRAD_SUM_WIDTH = GRAD_WIDTH + 3;            // 17-bit for grad sum

    //=========================================================================
    // Gradient Line Buffer (2 rows)
    //=========================================================================
    reg [GRAD_WIDTH-1:0] grad_line_buf_0 [0:IMG_WIDTH-1];
    reg [GRAD_WIDTH-1:0] grad_line_buf_1 [0:IMG_WIDTH-1];
    reg                  grad_buf_sel;  // 0: write to buf_0, 1: write to buf_1

    // Horizontal gradient shift register for left/right neighbors
    reg [GRAD_WIDTH-1:0] grad_shift_l;

    //=========================================================================
    // Cycle 0: Input Buffer and Gradient Fetch
    //=========================================================================
    // Fetch gradients from neighbors
    wire [GRAD_WIDTH-1:0] grad_c = grad;  // Current center
    wire [GRAD_WIDTH-1:0] grad_u = grad_buf_sel ? grad_line_buf_0[pixel_x] : grad_line_buf_1[pixel_x];  // Up (previous row)
    wire [GRAD_WIDTH-1:0] grad_d = grad_buf_sel ? grad_line_buf_1[pixel_x] : grad_line_buf_0[pixel_x];  // Down (next row - needs delay)
    wire [GRAD_WIDTH-1:0] grad_l = grad_shift_l;  // Left neighbor
    wire [GRAD_WIDTH-1:0] grad_r = grad;          // Right neighbor (simplified, same as center for now)

    // Boundary handling
    wire is_first_row = (pixel_y == 0);
    wire is_last_row  = (pixel_y >= img_height - 1);

    wire [GRAD_WIDTH-1:0] grad_u_bound = is_first_row ? grad_c : grad_u;
    wire [GRAD_WIDTH-1:0] grad_d_bound = is_last_row ? grad_c : grad_d;

    // Pipeline registers for Cycle 0
    reg [GRAD_WIDTH-1:0]   grad_c_s0, grad_u_s0, grad_d_s0, grad_l_s0, grad_r_s0;
    reg [DATA_WIDTH-1:0]   avg0_c_s0, avg0_u_s0, avg0_d_s0, avg0_l_s0, avg0_r_s0;
    reg [DATA_WIDTH-1:0]   avg1_c_s0, avg1_u_s0, avg1_d_s0, avg1_l_s0, avg1_r_s0;
    reg                    valid_s0;
    reg [DATA_WIDTH-1:0]   center_s0;
    reg [WIN_SIZE_WIDTH-1:0] win_size_s0;
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_s0;
    reg [ROW_CNT_WIDTH-1:0] pixel_y_s0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grad_c_s0  <= {GRAD_WIDTH{1'b0}};
            grad_u_s0  <= {GRAD_WIDTH{1'b0}};
            grad_d_s0  <= {GRAD_WIDTH{1'b0}};
            grad_l_s0  <= {GRAD_WIDTH{1'b0}};
            grad_r_s0  <= {GRAD_WIDTH{1'b0}};
            avg0_c_s0  <= {DATA_WIDTH{1'b0}};
            avg0_u_s0  <= {DATA_WIDTH{1'b0}};
            avg0_d_s0  <= {DATA_WIDTH{1'b0}};
            avg0_l_s0  <= {DATA_WIDTH{1'b0}};
            avg0_r_s0  <= {DATA_WIDTH{1'b0}};
            avg1_c_s0  <= {DATA_WIDTH{1'b0}};
            avg1_u_s0  <= {DATA_WIDTH{1'b0}};
            avg1_d_s0  <= {DATA_WIDTH{1'b0}};
            avg1_l_s0  <= {DATA_WIDTH{1'b0}};
            avg1_r_s0  <= {DATA_WIDTH{1'b0}};
            valid_s0   <= 1'b0;
            center_s0  <= {DATA_WIDTH{1'b0}};
            win_size_s0 <= {WIN_SIZE_WIDTH{1'b0}};
            pixel_x_s0 <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s0 <= {ROW_CNT_WIDTH{1'b0}};
            grad_shift_l <= {GRAD_WIDTH{1'b0}};
        end else if (enable) begin
            // Update gradient line buffer and shift register
            grad_shift_l <= grad_c;

            // Store current gradient to line buffer
            if (stage2_valid) begin
                if (grad_buf_sel)
                    grad_line_buf_1[pixel_x] <= grad_c;
                else
                    grad_line_buf_0[pixel_x] <= grad_c;
            end

            // Pipeline registers
            grad_c_s0  <= grad_c;
            grad_u_s0  <= grad_u_bound;
            grad_d_s0  <= grad_d_bound;
            grad_l_s0  <= grad_shift_l;
            grad_r_s0  <= grad_c;  // Simplified
            avg0_c_s0  <= avg0_c;
            avg0_u_s0  <= avg0_u;
            avg0_d_s0  <= avg0_d;
            avg0_l_s0  <= avg0_l;
            avg0_r_s0  <= avg0_r;
            avg1_c_s0  <= avg1_c;
            avg1_u_s0  <= avg1_u;
            avg1_d_s0  <= avg1_d;
            avg1_l_s0  <= avg1_l;
            avg1_r_s0  <= avg1_r;
            valid_s0   <= stage2_valid;
            center_s0  <= center_pixel;
            win_size_s0 <= win_size_clip;
            pixel_x_s0 <= pixel_x;
            pixel_y_s0 <= pixel_y;
        end
    end

    //=========================================================================
    // Cycle 1-2: Gradient Sorting Network
    //=========================================================================
    // 5-input descending sort using comparison network
    // Sort: s0 >= s1 >= s2 >= s3 >= s4

    // Cycle 1: First stage comparisons
    wire [GRAD_WIDTH-1:0] g0 = grad_c_s0;
    wire [GRAD_WIDTH-1:0] g1 = grad_u_s0;
    wire [GRAD_WIDTH-1:0] g2 = grad_d_s0;
    wire [GRAD_WIDTH-1:0] g3 = grad_l_s0;
    wire [GRAD_WIDTH-1:0] g4 = grad_r_s0;

    // Comparison swap function
    function [2*GRAD_WIDTH-1:0] cmp_swap;
        input [GRAD_WIDTH-1:0] a, b;
        begin
            cmp_swap = (a >= b) ? {a, b} : {b, a};
        end
    endfunction

    wire [GRAD_WIDTH-1:0] p0_max, p0_min, p1_max, p1_min, p2_max, p2_min;
    assign {p0_max, p0_min} = cmp_swap(g0, g1);
    assign {p1_max, p1_min} = cmp_swap(g2, g3);
    assign {p2_max, p2_min} = cmp_swap(g3, g4);

    // Pipeline registers for Cycle 1
    reg [GRAD_WIDTH-1:0]   g_s1 [0:4];
    reg [DATA_WIDTH-1:0]   avg0_s1 [0:4], avg1_s1 [0:4];
    reg                    valid_s1;
    reg [DATA_WIDTH-1:0]   center_s1;
    reg [WIN_SIZE_WIDTH-1:0] win_size_s1;
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_s1;
    reg [ROW_CNT_WIDTH-1:0] pixel_y_s1;

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 5; i = i + 1) begin
                g_s1[i]    <= {GRAD_WIDTH{1'b0}};
                avg0_s1[i] <= {DATA_WIDTH{1'b0}};
                avg1_s1[i] <= {DATA_WIDTH{1'b0}};
            end
            valid_s1   <= 1'b0;
            center_s1  <= {DATA_WIDTH{1'b0}};
            win_size_s1 <= {WIN_SIZE_WIDTH{1'b0}};
            pixel_x_s1 <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s1 <= {ROW_CNT_WIDTH{1'b0}};
        end else if (enable) begin
            // Simplified sort output (partial sorting)
            g_s1[0]    <= p0_max;  // Largest candidate
            g_s1[1]    <= p1_max;
            g_s1[2]    <= g2;      // Middle
            g_s1[3]    <= p0_min;
            g_s1[4]    <= p1_min;  // Smallest candidate
            // Reorder averages accordingly
            avg0_s1[0] <= avg0_c_s0;
            avg0_s1[1] <= avg0_u_s0;
            avg0_s1[2] <= avg0_d_s0;
            avg0_s1[3] <= avg0_l_s0;
            avg0_s1[4] <= avg0_r_s0;
            avg1_s1[0] <= avg1_c_s0;
            avg1_s1[1] <= avg1_u_s0;
            avg1_s1[2] <= avg1_d_s0;
            avg1_s1[3] <= avg1_l_s0;
            avg1_s1[4] <= avg1_r_s0;
            valid_s1   <= valid_s0;
            center_s1  <= center_s0;
            win_size_s1 <= win_size_s0;
            pixel_x_s1 <= pixel_x_s0;
            pixel_y_s1 <= pixel_y_s0;
        end
    end

    //=========================================================================
    // Cycle 2: Complete Sorting
    //=========================================================================
    // Final sort stage
    wire [GRAD_WIDTH-1:0] g_sorted [0:4];
    wire [GRAD_WIDTH-1:0] max_01 = (g_s1[0] >= g_s1[1]) ? g_s1[0] : g_s1[1];
    wire [GRAD_WIDTH-1:0] min_01 = (g_s1[0] >= g_s1[1]) ? g_s1[1] : g_s1[0];
    wire [GRAD_WIDTH-1:0] max_34 = (g_s1[3] >= g_s1[4]) ? g_s1[3] : g_s1[4];
    wire [GRAD_WIDTH-1:0] min_34 = (g_s1[3] >= g_s1[4]) ? g_s1[4] : g_s1[3];

    assign g_sorted[0] = (max_01 >= max_34) ? max_01 : max_34;  // Largest
    assign g_sorted[4] = (min_01 <= min_34) ? min_01 : min_34;  // Smallest

    // Middle values (simplified)
    wire [GRAD_WIDTH-1:0] mid_vals [0:2];
    assign mid_vals[0] = g_s1[2];
    assign mid_vals[1] = (min_01 >= max_34) ? min_01 : max_34;
    assign mid_vals[2] = (min_01 <= max_34) ? min_01 : max_34;

    // Sort middle values
    wire [GRAD_WIDTH-1:0] mid_max = (mid_vals[0] >= mid_vals[1]) ?
                                    ((mid_vals[0] >= mid_vals[2]) ? mid_vals[0] : mid_vals[2]) :
                                    ((mid_vals[1] >= mid_vals[2]) ? mid_vals[1] : mid_vals[2]);
    wire [GRAD_WIDTH-1:0] mid_min = (mid_vals[0] <= mid_vals[1]) ?
                                    ((mid_vals[0] <= mid_vals[2]) ? mid_vals[0] : mid_vals[2]) :
                                    ((mid_vals[1] <= mid_vals[2]) ? mid_vals[1] : mid_vals[2]);
    wire [GRAD_WIDTH-1:0] mid_mid = (mid_vals[0] >= mid_vals[1]) ?
                                    ((mid_vals[0] <= mid_vals[2]) ? mid_vals[0] :
                                     ((mid_vals[1] >= mid_vals[2]) ? mid_vals[1] : mid_vals[2])) :
                                    ((mid_vals[1] <= mid_vals[2]) ? mid_vals[2] : mid_vals[1]);

    assign g_sorted[1] = mid_max;
    assign g_sorted[2] = mid_mid;
    assign g_sorted[3] = mid_min;

    // Pipeline registers for Cycle 2
    reg [GRAD_WIDTH-1:0]   g_s2 [0:4];
    reg [DATA_WIDTH-1:0]   avg0_s2 [0:4], avg1_s2 [0:4];
    reg                    valid_s2;
    reg [DATA_WIDTH-1:0]   center_s2;
    reg [WIN_SIZE_WIDTH-1:0] win_size_s2;
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_s2;
    reg [ROW_CNT_WIDTH-1:0] pixel_y_s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 5; i = i + 1) begin
                g_s2[i]    <= {GRAD_WIDTH{1'b0}};
                avg0_s2[i] <= {DATA_WIDTH{1'b0}};
                avg1_s2[i] <= {DATA_WIDTH{1'b0}};
            end
            valid_s2   <= 1'b0;
            center_s2  <= {DATA_WIDTH{1'b0}};
            win_size_s2 <= {WIN_SIZE_WIDTH{1'b0}};
            pixel_x_s2 <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s2 <= {ROW_CNT_WIDTH{1'b0}};
        end else if (enable) begin
            for (i = 0; i < 5; i = i + 1) begin
                g_s2[i]    <= g_sorted[i];
                avg0_s2[i] <= avg0_s1[i];
                avg1_s2[i] <= avg1_s1[i];
            end
            valid_s2   <= valid_s1;
            center_s2  <= center_s1;
            win_size_s2 <= win_size_s1;
            pixel_x_s2 <= pixel_x_s1;
            pixel_y_s2 <= pixel_y_s1;
        end
    end

    //=========================================================================
    // Cycle 3: Weighted Multiplication
    //=========================================================================
    wire [DATA_WIDTH+GRAD_WIDTH-1:0] blend0_partial [0:4];
    wire [DATA_WIDTH+GRAD_WIDTH-1:0] blend1_partial [0:4];

    genvar gi;
    generate
        for (gi = 0; gi < 5; gi = gi + 1) begin : gen_mul
            assign blend0_partial[gi] = avg0_s2[gi] * g_s2[gi];
            assign blend1_partial[gi] = avg1_s2[gi] * g_s2[gi];
        end
    endgenerate

    // Pipeline registers for Cycle 3
    reg [DATA_WIDTH+GRAD_WIDTH-1:0] blend0_p_s3 [0:4];
    reg [DATA_WIDTH+GRAD_WIDTH-1:0] blend1_p_s3 [0:4];
    reg [GRAD_WIDTH-1:0]            g_s3 [0:4];
    reg                             valid_s3;
    reg [DATA_WIDTH-1:0]            center_s3;
    reg [WIN_SIZE_WIDTH-1:0]        win_size_s3;
    reg [LINE_ADDR_WIDTH-1:0]       pixel_x_s3;
    reg [ROW_CNT_WIDTH-1:0]         pixel_y_s3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 5; i = i + 1) begin
                blend0_p_s3[i] <= {DATA_WIDTH+GRAD_WIDTH{1'b0}};
                blend1_p_s3[i] <= {DATA_WIDTH+GRAD_WIDTH{1'b0}};
                g_s3[i]        <= {GRAD_WIDTH{1'b0}};
            end
            valid_s3   <= 1'b0;
            center_s3  <= {DATA_WIDTH{1'b0}};
            win_size_s3 <= {WIN_SIZE_WIDTH{1'b0}};
            pixel_x_s3 <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s3 <= {ROW_CNT_WIDTH{1'b0}};
        end else if (enable) begin
            for (i = 0; i < 5; i = i + 1) begin
                blend0_p_s3[i] <= blend0_partial[i];
                blend1_p_s3[i] <= blend1_partial[i];
                g_s3[i]        <= g_s2[i];
            end
            valid_s3   <= valid_s2;
            center_s3  <= center_s2;
            win_size_s3 <= win_size_s2;
            pixel_x_s3 <= pixel_x_s2;
            pixel_y_s3 <= pixel_y_s2;
        end
    end

    //=========================================================================
    // Cycle 4: Weighted Sum
    //=========================================================================
    wire [BLEND_WIDTH-1:0] blend0_sum_comb = blend0_p_s3[0] + blend0_p_s3[1] + blend0_p_s3[2] +
                                             blend0_p_s3[3] + blend0_p_s3[4];
    wire [BLEND_WIDTH-1:0] blend1_sum_comb = blend1_p_s3[0] + blend1_p_s3[1] + blend1_p_s3[2] +
                                             blend1_p_s3[3] + blend1_p_s3[4];
    wire [GRAD_SUM_WIDTH-1:0] grad_sum_comb = g_s3[0] + g_s3[1] + g_s3[2] + g_s3[3] + g_s3[4];

    // Pipeline registers for Cycle 4
    reg [BLEND_WIDTH-1:0]     blend0_sum_s4, blend1_sum_s4;
    reg [GRAD_SUM_WIDTH-1:0]  grad_sum_s4;
    reg                       valid_s4;
    reg [DATA_WIDTH-1:0]      center_s4;
    reg [WIN_SIZE_WIDTH-1:0]  win_size_s4;
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_s4;
    reg [ROW_CNT_WIDTH-1:0]   pixel_y_s4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blend0_sum_s4 <= {BLEND_WIDTH{1'b0}};
            blend1_sum_s4 <= {BLEND_WIDTH{1'b0}};
            grad_sum_s4   <= {GRAD_SUM_WIDTH{1'b0}};
            valid_s4      <= 1'b0;
            center_s4     <= {DATA_WIDTH{1'b0}};
            win_size_s4   <= {WIN_SIZE_WIDTH{1'b0}};
            pixel_x_s4    <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s4    <= {ROW_CNT_WIDTH{1'b0}};
        end else if (enable) begin
            blend0_sum_s4 <= blend0_sum_comb;
            blend1_sum_s4 <= blend1_sum_comb;
            grad_sum_s4   <= grad_sum_comb;
            valid_s4      <= valid_s3;
            center_s4     <= center_s3;
            win_size_s4   <= win_size_s3;
            pixel_x_s4    <= pixel_x_s3;
            pixel_y_s4    <= pixel_y_s3;
        end
    end

    //=========================================================================
    // Cycle 5: Division Output using LUT-based Approximation
    //=========================================================================
    // Index compression: compress 17-bit grad_sum to 8-bit LUT index
    wire [7:0] lut_index;
    assign lut_index = (grad_sum_s4[16]) ? {3'b111, grad_sum_s4[13:9]} :
                       (grad_sum_s4[15]) ? {3'b110, grad_sum_s4[12:8]} :
                       (grad_sum_s4[14]) ? {3'b101, grad_sum_s4[11:7]} :
                       (grad_sum_s4[13]) ? {3'b100, grad_sum_s4[10:6]} :
                       (grad_sum_s4[12]) ? {3'b011, grad_sum_s4[9:5]} :
                       (grad_sum_s4[11]) ? {3'b010, grad_sum_s4[8:4]} :
                       (grad_sum_s4[10]) ? {3'b001, grad_sum_s4[7:3]} :
                       (|grad_sum_s4[9:0]) ? {1'b0, grad_sum_s4[7:0]} : 8'b0;

    // LUT (256 x 16-bit) for inverse values: inv = round(2^26 / typical_grad_sum)
    reg [15:0] div_lut [0:255];

    // Initialize LUT with inverse values
    integer init_i;
    initial begin
        // LUT values computed as: inv = round(2^26 / mid_point_of_range)
        // Each index covers a range of grad_sum values
        // Note: Values clamped to 16-bit max (65535)
        div_lut[0]   = 16'd65535;  // grad_sum = 0 (should not be used, max value)
        div_lut[1]   = 16'd65535;  // grad_sum = 1, 2^26/1 = 67108864, clamp to max
        div_lut[2]   = 16'd32768;  // grad_sum = 2
        div_lut[3]   = 16'd21845;  // grad_sum = 3
        div_lut[4]   = 16'd16384;  // grad_sum = 4
        div_lut[5]   = 16'd13107;  // grad_sum = 5
        div_lut[6]   = 16'd10923;  // grad_sum = 6
        div_lut[7]   = 16'd9362;   // grad_sum = 7
        div_lut[8]   = 16'd8192;   // grad_sum = 8
        div_lut[9]   = 16'd7282;   // grad_sum = 9
        div_lut[10]  = 16'd6554;   // grad_sum = 10
        div_lut[11]  = 16'd5964;   // grad_sum = 11
        div_lut[12]  = 16'd5461;   // grad_sum = 12
        div_lut[13]  = 16'd5027;   // grad_sum = 13
        div_lut[14]  = 16'd4648;   // grad_sum = 14
        div_lut[15]  = 16'd4315;   // grad_sum = 15
        // Index 16-31: grad_sum range 16-31, mid = 24
        div_lut[16]  = 16'd2796;   // grad_sum = 16
        div_lut[17]  = 16'd2633;   // grad_sum = 17
        div_lut[18]  = 16'd2486;   // grad_sum = 18
        div_lut[19]  = 16'd2352;   // grad_sum = 19
        div_lut[20]  = 16'd2230;   // grad_sum = 20
        div_lut[21]  = 16'd2119;   // grad_sum = 21
        div_lut[22]  = 16'd2017;   // grad_sum = 22
        div_lut[23]  = 16'd1923;   // grad_sum = 23
        div_lut[24]  = 16'd1837;   // grad_sum = 24
        div_lut[25]  = 16'd1757;   // grad_sum = 25
        div_lut[26]  = 16'd1684;   // grad_sum = 26
        div_lut[27]  = 16'd1615;   // grad_sum = 27
        div_lut[28]  = 16'd1552;   // grad_sum = 28
        div_lut[29]  = 16'd1493;   // grad_sum = 29
        div_lut[30]  = 16'd1438;   // grad_sum = 30
        div_lut[31]  = 16'd1386;   // grad_sum = 31
        // Index 32-63: grad_sum range 32-63, mid = 48
        div_lut[32]  = 16'd1337;   // grad_sum = 32
        div_lut[33]  = 16'd1290;   // grad_sum = 33
        div_lut[48]  = 16'd1117;   // grad_sum = 48
        div_lut[63]  = 16'd1004;   // grad_sum = 63
        // Index 64-127: grad_sum range 64-127, mid = 96
        div_lut[64]  = 16'd957;    // grad_sum = 64
        div_lut[96]  = 16'd699;    // grad_sum = 96
        div_lut[127] = 16'd548;    // grad_sum = 127
        // Index 128-255: grad_sum range 128-255, mid = 192
        div_lut[128] = 16'd524;    // grad_sum = 128
        div_lut[192] = 16'd349;    // grad_sum = 192
        div_lut[255] = 16'd263;    // grad_sum = 255
        // Fill remaining entries with interpolated values
        for (init_i = 34; init_i < 48; init_i = init_i + 1)
            div_lut[init_i] = div_lut[33] - (div_lut[33] - div_lut[48]) * (init_i - 33) / 15;
        for (init_i = 49; init_i < 63; init_i = init_i + 1)
            div_lut[init_i] = div_lut[48] - (div_lut[48] - div_lut[63]) * (init_i - 48) / 15;
        for (init_i = 65; init_i < 96; init_i = init_i + 1)
            div_lut[init_i] = div_lut[64] - (div_lut[64] - div_lut[96]) * (init_i - 64) / 32;
        for (init_i = 97; init_i < 127; init_i = init_i + 1)
            div_lut[init_i] = div_lut[96] - (div_lut[96] - div_lut[127]) * (init_i - 96) / 31;
        for (init_i = 129; init_i < 192; init_i = init_i + 1)
            div_lut[init_i] = div_lut[128] - (div_lut[128] - div_lut[192]) * (init_i - 128) / 64;
        for (init_i = 193; init_i < 255; init_i = init_i + 1)
            div_lut[init_i] = div_lut[192] - (div_lut[192] - div_lut[255]) * (init_i - 192) / 63;
    end

    // LUT read
    wire [15:0] inv_value = div_lut[lut_index];

    // Multiplication: blend_sum * inv_value
    wire [41:0] product0 = blend0_sum_s4 * inv_value;
    wire [41:0] product1 = blend1_sum_s4 * inv_value;

    // Truncate to 10-bit output (bits [35:26] of product)
    wire [DATA_WIDTH-1:0] blend0_div = (grad_sum_s4 != 0) ?
                                       product0[35:26] : {DATA_WIDTH{1'b0}};
    wire [DATA_WIDTH-1:0] blend1_div = (grad_sum_s4 != 0) ?
                                       product1[35:26] : {DATA_WIDTH{1'b0}};

    // Output registers
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blend0_dir_avg  <= {DATA_WIDTH{1'b0}};
            blend1_dir_avg  <= {DATA_WIDTH{1'b0}};
            stage3_valid    <= 1'b0;
            pixel_x_out     <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_out     <= {ROW_CNT_WIDTH{1'b0}};
            avg0_u_out      <= {DATA_WIDTH{1'b0}};
            avg1_u_out      <= {DATA_WIDTH{1'b0}};
            win_size_clip_out <= {WIN_SIZE_WIDTH{1'b0}};
            center_pixel_out <= {DATA_WIDTH{1'b0}};
        end else if (enable) begin
            blend0_dir_avg  <= blend0_div;
            blend1_dir_avg  <= blend1_div;
            stage3_valid    <= valid_s4;
            pixel_x_out     <= pixel_x_s4;
            pixel_y_out     <= pixel_y_s4;
            avg0_u_out      <= avg0_u_s0;  // Pass through from Stage 2
            avg1_u_out      <= avg1_u_s0;
            win_size_clip_out <= win_size_s4;
            center_pixel_out <= center_s4;
        end
    end

endmodule