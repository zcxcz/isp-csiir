//-----------------------------------------------------------------------------
// Module: stage2_directional_avg
// Description: Stage 2 - Multi-scale directional averaging
//              Pure Verilog-2001 compatible
//              Pipeline stages: 6 cycles
//              Fully parameterized for resolution and data width
//-----------------------------------------------------------------------------

module stage2_directional_avg #(
    parameter DATA_WIDTH     = 10,                      // Pixel data width
    parameter ACC_WIDTH      = 20,                      // Accumulator width
    parameter WIN_SIZE_WIDTH = 6                        // Window size parameter width
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

    // Stage 1 outputs
    input  wire [WIN_SIZE_WIDTH-1:0]   win_size_clip,
    input  wire                        stage1_valid,

    // Configuration thresholds
    input  wire [15:0]                 win_size_thresh0,
    input  wire [15:0]                 win_size_thresh1,
    input  wire [15:0]                 win_size_thresh2,
    input  wire [15:0]                 win_size_thresh3,

    // Outputs: 5 directions x 2 scales = 10 averages
    output reg  [DATA_WIDTH-1:0]       avg0_c, avg0_u, avg0_d, avg0_l, avg0_r,
    output reg  [DATA_WIDTH-1:0]       avg1_c, avg1_u, avg1_d, avg1_l, avg1_r,
    output reg                         stage2_valid
);

    `include "isp_csiir_defines.vh"

    // Kernel selection signals
    reg [2:0] kernel_select;
    wire kernel_2x2, kernel_3x3, kernel_4x4, kernel_5x5;

    // Accumulators for weighted sums
    reg [ACC_WIDTH-1:0] sum0_c, sum0_u, sum0_d, sum0_l, sum0_r;
    reg [ACC_WIDTH-1:0] sum1_c, sum1_u, sum1_d, sum1_l, sum1_r;
    reg [7:0] weight0_c, weight0_u, weight0_d, weight0_l, weight0_r;
    reg [7:0] weight1_c, weight1_u, weight1_d, weight1_l, weight1_r;

    // Pipeline registers
    reg [WIN_SIZE_WIDTH-1:0] win_size_s1, win_size_s2, win_size_s3;
    reg                       valid_s1, valid_s2, valid_s3, valid_s4, valid_s5;

    // Stage 1: Kernel selection based on window size
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            kernel_select <= 3'd0;
            win_size_s1   <= {WIN_SIZE_WIDTH{1'b0}};
            valid_s1      <= 1'b0;
        end else if (enable && stage1_valid) begin
            win_size_s1 <= win_size_clip;

            // Select kernel pair based on thresholds
            if (win_size_clip < win_size_thresh0[5:0]) begin
                kernel_select <= 3'd0;  // avg0=zeros, avg1=2x2
            end else if (win_size_clip < win_size_thresh1[5:0]) begin
                kernel_select <= 3'd1;  // avg0=2x2, avg1=3x3
            end else if (win_size_clip < win_size_thresh2[5:0]) begin
                kernel_select <= 3'd2;  // avg0=3x3, avg1=4x4
            end else if (win_size_clip < win_size_thresh3[5:0]) begin
                kernel_select <= 3'd3;  // avg0=4x4, avg1=5x5
            end else begin
                kernel_select <= 3'd4;  // avg0=5x5, avg1=zeros
            end
            valid_s1 <= 1'b1;
        end else begin
            valid_s1 <= 1'b0;
        end
    end

    // Stage 2-3: Compute weighted sums for each direction
    // avg_factor_c_2x2 pattern
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum0_c <= {ACC_WIDTH{1'b0}};
            sum0_u <= {ACC_WIDTH{1'b0}};
            sum0_d <= {ACC_WIDTH{1'b0}};
            sum0_l <= {ACC_WIDTH{1'b0}};
            sum0_r <= {ACC_WIDTH{1'b0}};
            sum1_c <= {ACC_WIDTH{1'b0}};
            sum1_u <= {ACC_WIDTH{1'b0}};
            sum1_d <= {ACC_WIDTH{1'b0}};
            sum1_l <= {ACC_WIDTH{1'b0}};
            sum1_r <= {ACC_WIDTH{1'b0}};
            weight0_c <= 8'd0;
            weight0_u <= 8'd0;
            weight0_d <= 8'd0;
            weight0_l <= 8'd0;
            weight0_r <= 8'd0;
            weight1_c <= 8'd0;
            weight1_u <= 8'd0;
            weight1_d <= 8'd0;
            weight1_l <= 8'd0;
            weight1_r <= 8'd0;
            win_size_s2 <= {WIN_SIZE_WIDTH{1'b0}};
            valid_s2 <= 1'b0;
        end else if (enable && valid_s1) begin
            win_size_s2 <= win_size_s1;

            case (kernel_select)
                // 2x2 kernel for avg1
                3'd0: begin
                    // avg0 = zeros (all zero)
                    sum0_c <= {ACC_WIDTH{1'b0}};
                    sum0_u <= {ACC_WIDTH{1'b0}};
                    sum0_d <= {ACC_WIDTH{1'b0}};
                    sum0_l <= {ACC_WIDTH{1'b0}};
                    sum0_r <= {ACC_WIDTH{1'b0}};
                    weight0_c <= 8'd0;
                    weight0_u <= 8'd0;
                    weight0_d <= 8'd0;
                    weight0_l <= 8'd0;
                    weight0_r <= 8'd0;

                    // avg1 = 2x2 kernel
                    // Center (2x2): weighted sum with 2x2 pattern
                    sum1_c <= (window_1_1 * 1 + window_1_2 * 2 + window_1_3 * 1 +
                               window_2_1 * 2 + window_2_2 * 4 + window_2_3 * 2 +
                               window_3_1 * 1 + window_3_2 * 2 + window_3_3 * 1);
                    weight1_c <= 8'd16;

                    // Up: mask upper 3 rows
                    sum1_u <= (window_0_1 * 1 + window_0_2 * 2 + window_0_3 * 1 +
                               window_1_1 * 1 + window_1_2 * 2 + window_1_3 * 1 +
                               window_2_1 * 1 + window_2_2 * 2 + window_2_3 * 1);
                    weight1_u <= 8'd12;

                    // Down: mask lower 3 rows
                    sum1_d <= (window_2_1 * 1 + window_2_2 * 2 + window_2_3 * 1 +
                               window_3_1 * 1 + window_3_2 * 2 + window_3_3 * 1 +
                               window_4_1 * 1 + window_4_2 * 2 + window_4_3 * 1);
                    weight1_d <= 8'd12;

                    // Left: mask left 3 columns
                    sum1_l <= (window_1_0 * 1 + window_1_1 * 2 + window_1_2 * 1 +
                               window_2_0 * 2 + window_2_1 * 4 + window_2_2 * 2 +
                               window_3_0 * 1 + window_3_1 * 2 + window_3_2 * 1);
                    weight1_l <= 8'd16;

                    // Right: mask right 3 columns
                    sum1_r <= (window_1_2 * 1 + window_1_3 * 2 + window_1_4 * 1 +
                               window_2_2 * 2 + window_2_3 * 4 + window_2_4 * 2 +
                               window_3_2 * 1 + window_3_3 * 2 + window_3_4 * 1);
                    weight1_r <= 8'd16;
                end

                // 2x2 for avg0, 3x3 for avg1
                3'd1: begin
                    // avg0 = 2x2 (same as above for sum0)
                    sum0_c <= (window_1_1 * 1 + window_1_2 * 2 + window_1_3 * 1 +
                               window_2_1 * 2 + window_2_2 * 4 + window_2_3 * 2 +
                               window_3_1 * 1 + window_3_2 * 2 + window_3_3 * 1);
                    weight0_c <= 8'd16;

                    sum0_u <= (window_0_1 * 1 + window_0_2 * 2 + window_0_3 * 1 +
                               window_1_1 * 1 + window_1_2 * 2 + window_1_3 * 1 +
                               window_2_1 * 1 + window_2_2 * 2 + window_2_3 * 1);
                    weight0_u <= 8'd12;

                    sum0_d <= (window_2_1 * 1 + window_2_2 * 2 + window_2_3 * 1 +
                               window_3_1 * 1 + window_3_2 * 2 + window_3_3 * 1 +
                               window_4_1 * 1 + window_4_2 * 2 + window_4_3 * 1);
                    weight0_d <= 8'd12;

                    sum0_l <= (window_1_0 * 1 + window_1_1 * 2 + window_1_2 * 1 +
                               window_2_0 * 2 + window_2_1 * 4 + window_2_2 * 2 +
                               window_3_0 * 1 + window_3_1 * 2 + window_3_2 * 1);
                    weight0_l <= 8'd16;

                    sum0_r <= (window_1_2 * 1 + window_1_3 * 2 + window_1_4 * 1 +
                               window_2_2 * 2 + window_2_3 * 4 + window_2_4 * 2 +
                               window_3_2 * 1 + window_3_3 * 2 + window_3_4 * 1);
                    weight0_r <= 8'd16;

                    // avg1 = 3x3
                    sum1_c <= (window_1_1 + window_1_2 + window_1_3 +
                               window_2_1 + window_2_2 + window_2_3 +
                               window_3_1 + window_3_2 + window_3_3);
                    weight1_c <= 8'd9;

                    sum1_u <= (window_0_1 + window_0_2 + window_0_3 +
                               window_1_1 + window_1_2 + window_1_3 +
                               window_2_1 + window_2_2 + window_2_3);
                    weight1_u <= 8'd9;

                    sum1_d <= (window_2_1 + window_2_2 + window_2_3 +
                               window_3_1 + window_3_2 + window_3_3 +
                               window_4_1 + window_4_2 + window_4_3);
                    weight1_d <= 8'd9;

                    sum1_l <= (window_1_0 + window_1_1 + window_1_2 +
                               window_2_0 + window_2_1 + window_2_2 +
                               window_3_0 + window_3_1 + window_3_2);
                    weight1_l <= 8'd9;

                    sum1_r <= (window_1_2 + window_1_3 + window_1_4 +
                               window_2_2 + window_2_3 + window_2_4 +
                               window_3_2 + window_3_3 + window_3_4);
                    weight1_r <= 8'd9;
                end

                // 3x3 for avg0, 4x4 for avg1
                3'd2: begin
                    sum0_c <= (window_1_1 + window_1_2 + window_1_3 +
                               window_2_1 + window_2_2 + window_2_3 +
                               window_3_1 + window_3_2 + window_3_3);
                    weight0_c <= 8'd9;

                    sum0_u <= (window_0_1 + window_0_2 + window_0_3 +
                               window_1_1 + window_1_2 + window_1_3 +
                               window_2_1 + window_2_2 + window_2_3);
                    weight0_u <= 8'd9;

                    sum0_d <= (window_2_1 + window_2_2 + window_2_3 +
                               window_3_1 + window_3_2 + window_3_3 +
                               window_4_1 + window_4_2 + window_4_3);
                    weight0_d <= 8'd9;

                    sum0_l <= (window_1_0 + window_1_1 + window_1_2 +
                               window_2_0 + window_2_1 + window_2_2 +
                               window_3_0 + window_3_1 + window_3_2);
                    weight0_l <= 8'd9;

                    sum0_r <= (window_1_2 + window_1_3 + window_1_4 +
                               window_2_2 + window_2_3 + window_2_4 +
                               window_3_2 + window_3_3 + window_3_4);
                    weight0_r <= 8'd9;

                    // 4x4 kernel
                    sum1_c <= (window_0_0 + window_0_1 + window_0_2*2 + window_0_3 + window_0_4 +
                               window_1_0 + window_1_1*2 + window_1_2*4 + window_1_3*2 + window_1_4 +
                               window_2_0*2 + window_2_1*4 + window_2_2*8 + window_2_3*4 + window_2_4*2 +
                               window_3_0 + window_3_1*2 + window_3_2*4 + window_3_3*2 + window_3_4 +
                               window_4_0 + window_4_1 + window_4_2*2 + window_4_3 + window_4_4);
                    weight1_c <= 8'd44;

                    sum1_u <= (window_0_0 + window_0_1 + window_0_2*2 + window_0_3 + window_0_4 +
                               window_1_0 + window_1_1*2 + window_1_2*4 + window_1_3*2 + window_1_4 +
                               window_2_0*2 + window_2_1*4 + window_2_2*8 + window_2_3*4 + window_2_4*2);
                    weight1_u <= 8'd36;

                    sum1_d <= (window_2_0*2 + window_2_1*4 + window_2_2*8 + window_2_3*4 + window_2_4*2 +
                               window_3_0 + window_3_1*2 + window_3_2*4 + window_3_3*2 + window_3_4 +
                               window_4_0 + window_4_1 + window_4_2*2 + window_4_3 + window_4_4);
                    weight1_d <= 8'd36;

                    sum1_l <= (window_0_0 + window_0_1 + window_0_2*2 +
                               window_1_0 + window_1_1*2 + window_1_2*4 +
                               window_2_0*2 + window_2_1*4 + window_2_2*8 +
                               window_3_0 + window_3_1*2 + window_3_2*4 +
                               window_4_0 + window_4_1 + window_4_2*2);
                    weight1_l <= 8'd36;

                    sum1_r <= (window_0_2*2 + window_0_3 + window_0_4 +
                               window_1_2*4 + window_1_3*2 + window_1_4 +
                               window_2_2*8 + window_2_3*4 + window_2_4*2 +
                               window_3_2*4 + window_3_3*2 + window_3_4 +
                               window_4_2*2 + window_4_3 + window_4_4);
                    weight1_r <= 8'd36;
                end

                // 4x4 for avg0, 5x5 for avg1
                3'd3: begin
                    sum0_c <= (window_0_0 + window_0_1 + window_0_2*2 + window_0_3 + window_0_4 +
                               window_1_0 + window_1_1*2 + window_1_2*4 + window_1_3*2 + window_1_4 +
                               window_2_0*2 + window_2_1*4 + window_2_2*8 + window_2_3*4 + window_2_4*2 +
                               window_3_0 + window_3_1*2 + window_3_2*4 + window_3_3*2 + window_3_4 +
                               window_4_0 + window_4_1 + window_4_2*2 + window_4_3 + window_4_4);
                    weight0_c <= 8'd44;

                    sum0_u <= (window_0_0 + window_0_1 + window_0_2*2 + window_0_3 + window_0_4 +
                               window_1_0 + window_1_1*2 + window_1_2*4 + window_1_3*2 + window_1_4 +
                               window_2_0*2 + window_2_1*4 + window_2_2*8 + window_2_3*4 + window_2_4*2);
                    weight0_u <= 8'd36;

                    sum0_d <= (window_2_0*2 + window_2_1*4 + window_2_2*8 + window_2_3*4 + window_2_4*2 +
                               window_3_0 + window_3_1*2 + window_3_2*4 + window_3_3*2 + window_3_4 +
                               window_4_0 + window_4_1 + window_4_2*2 + window_4_3 + window_4_4);
                    weight0_d <= 8'd36;

                    sum0_l <= (window_0_0 + window_0_1 + window_0_2*2 +
                               window_1_0 + window_1_1*2 + window_1_2*4 +
                               window_2_0*2 + window_2_1*4 + window_2_2*8 +
                               window_3_0 + window_3_1*2 + window_3_2*4 +
                               window_4_0 + window_4_1 + window_4_2*2);
                    weight0_l <= 8'd36;

                    sum0_r <= (window_0_2*2 + window_0_3 + window_0_4 +
                               window_1_2*4 + window_1_3*2 + window_1_4 +
                               window_2_2*8 + window_2_3*4 + window_2_4*2 +
                               window_3_2*4 + window_3_3*2 + window_3_4 +
                               window_4_2*2 + window_4_3 + window_4_4);
                    weight0_r <= 8'd36;

                    // 5x5 uniform
                    sum1_c <= (window_0_0 + window_0_1 + window_0_2 + window_0_3 + window_0_4 +
                               window_1_0 + window_1_1 + window_1_2 + window_1_3 + window_1_4 +
                               window_2_0 + window_2_1 + window_2_2 + window_2_3 + window_2_4 +
                               window_3_0 + window_3_1 + window_3_2 + window_3_3 + window_3_4 +
                               window_4_0 + window_4_1 + window_4_2 + window_4_3 + window_4_4);
                    weight1_c <= 8'd25;

                    sum1_u <= (window_0_0 + window_0_1 + window_0_2 + window_0_3 + window_0_4 +
                               window_1_0 + window_1_1 + window_1_2 + window_1_3 + window_1_4 +
                               window_2_0 + window_2_1 + window_2_2 + window_2_3 + window_2_4);
                    weight1_u <= 8'd15;

                    sum1_d <= (window_2_0 + window_2_1 + window_2_2 + window_2_3 + window_2_4 +
                               window_3_0 + window_3_1 + window_3_2 + window_3_3 + window_3_4 +
                               window_4_0 + window_4_1 + window_4_2 + window_4_3 + window_4_4);
                    weight1_d <= 8'd15;

                    sum1_l <= (window_0_0 + window_0_1 + window_0_2 +
                               window_1_0 + window_1_1 + window_1_2 +
                               window_2_0 + window_2_1 + window_2_2 +
                               window_3_0 + window_3_1 + window_3_2 +
                               window_4_0 + window_4_1 + window_4_2);
                    weight1_l <= 8'd15;

                    sum1_r <= (window_0_2 + window_0_3 + window_0_4 +
                               window_1_2 + window_1_3 + window_1_4 +
                               window_2_2 + window_2_3 + window_2_4 +
                               window_3_2 + window_3_3 + window_3_4 +
                               window_4_2 + window_4_3 + window_4_4);
                    weight1_r <= 8'd15;
                end

                // 5x5 for avg0, zeros for avg1
                default: begin
                    sum0_c <= (window_0_0 + window_0_1 + window_0_2 + window_0_3 + window_0_4 +
                               window_1_0 + window_1_1 + window_1_2 + window_1_3 + window_1_4 +
                               window_2_0 + window_2_1 + window_2_2 + window_2_3 + window_2_4 +
                               window_3_0 + window_3_1 + window_3_2 + window_3_3 + window_3_4 +
                               window_4_0 + window_4_1 + window_4_2 + window_4_3 + window_4_4);
                    weight0_c <= 8'd25;

                    sum0_u <= (window_0_0 + window_0_1 + window_0_2 + window_0_3 + window_0_4 +
                               window_1_0 + window_1_1 + window_1_2 + window_1_3 + window_1_4 +
                               window_2_0 + window_2_1 + window_2_2 + window_2_3 + window_2_4);
                    weight0_u <= 8'd15;

                    sum0_d <= (window_2_0 + window_2_1 + window_2_2 + window_2_3 + window_2_4 +
                               window_3_0 + window_3_1 + window_3_2 + window_3_3 + window_3_4 +
                               window_4_0 + window_4_1 + window_4_2 + window_4_3 + window_4_4);
                    weight0_d <= 8'd15;

                    sum0_l <= (window_0_0 + window_0_1 + window_0_2 +
                               window_1_0 + window_1_1 + window_1_2 +
                               window_2_0 + window_2_1 + window_2_2 +
                               window_3_0 + window_3_1 + window_3_2 +
                               window_4_0 + window_4_1 + window_4_2);
                    weight0_l <= 8'd15;

                    sum0_r <= (window_0_2 + window_0_3 + window_0_4 +
                               window_1_2 + window_1_3 + window_1_4 +
                               window_2_2 + window_2_3 + window_2_4 +
                               window_3_2 + window_3_3 + window_3_4 +
                               window_4_2 + window_4_3 + window_4_4);
                    weight0_r <= 8'd15;

                    sum1_c <= {ACC_WIDTH{1'b0}};
                    sum1_u <= {ACC_WIDTH{1'b0}};
                    sum1_d <= {ACC_WIDTH{1'b0}};
                    sum1_l <= {ACC_WIDTH{1'b0}};
                    sum1_r <= {ACC_WIDTH{1'b0}};
                    weight1_c <= 8'd0;
                    weight1_u <= 8'd0;
                    weight1_d <= 8'd0;
                    weight1_l <= 8'd0;
                    weight1_r <= 8'd0;
                end
            endcase

            valid_s2 <= 1'b1;
        end else begin
            valid_s2 <= 1'b0;
        end
    end

    // Stage 3-4: Pipeline the weights for division
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s3 <= 1'b0;
            valid_s4 <= 1'b0;
            valid_s5 <= 1'b0;
        end else if (enable) begin
            valid_s3 <= valid_s2;
            valid_s4 <= valid_s3;
            valid_s5 <= valid_s4;
        end
    end

    // Stage 5-6: Division (using approximate division or pre-computed)
    // For synthesis, we use a simpler approach: multiply by reciprocal
    // Here we implement integer division with pipelining
    reg [ACC_WIDTH-1:0] sum0_c_s3, sum0_u_s3, sum0_d_s3, sum0_l_s3, sum0_r_s3;
    reg [ACC_WIDTH-1:0] sum1_c_s3, sum1_u_s3, sum1_d_s3, sum1_l_s3, sum1_r_s3;
    reg [7:0] w0_c_s3, w0_u_s3, w0_d_s3, w0_l_s3, w0_r_s3;
    reg [7:0] w1_c_s3, w1_u_s3, w1_d_s3, w1_l_s3, w1_r_s3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum0_c_s3 <= {ACC_WIDTH{1'b0}};
            sum0_u_s3 <= {ACC_WIDTH{1'b0}};
            sum0_d_s3 <= {ACC_WIDTH{1'b0}};
            sum0_l_s3 <= {ACC_WIDTH{1'b0}};
            sum0_r_s3 <= {ACC_WIDTH{1'b0}};
            sum1_c_s3 <= {ACC_WIDTH{1'b0}};
            sum1_u_s3 <= {ACC_WIDTH{1'b0}};
            sum1_d_s3 <= {ACC_WIDTH{1'b0}};
            sum1_l_s3 <= {ACC_WIDTH{1'b0}};
            sum1_r_s3 <= {ACC_WIDTH{1'b0}};
            w0_c_s3 <= 8'd0;
            w0_u_s3 <= 8'd0;
            w0_d_s3 <= 8'd0;
            w0_l_s3 <= 8'd0;
            w0_r_s3 <= 8'd0;
            w1_c_s3 <= 8'd0;
            w1_u_s3 <= 8'd0;
            w1_d_s3 <= 8'd0;
            w1_l_s3 <= 8'd0;
            w1_r_s3 <= 8'd0;
        end else if (valid_s2) begin
            sum0_c_s3 <= sum0_c;
            sum0_u_s3 <= sum0_u;
            sum0_d_s3 <= sum0_d;
            sum0_l_s3 <= sum0_l;
            sum0_r_s3 <= sum0_r;
            sum1_c_s3 <= sum1_c;
            sum1_u_s3 <= sum1_u;
            sum1_d_s3 <= sum1_d;
            sum1_l_s3 <= sum1_l;
            sum1_r_s3 <= sum1_r;
            w0_c_s3 <= weight0_c;
            w0_u_s3 <= weight0_u;
            w0_d_s3 <= weight0_d;
            w0_l_s3 <= weight0_l;
            w0_r_s3 <= weight0_r;
            w1_c_s3 <= weight1_c;
            w1_u_s3 <= weight1_u;
            w1_d_s3 <= weight1_d;
            w1_l_s3 <= weight1_l;
            w1_r_s3 <= weight1_r;
        end
    end

    // Final division and output
    // Using integer division (can be optimized with DSP or LUT-based divider)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            avg0_c <= {DATA_WIDTH{1'b0}};
            avg0_u <= {DATA_WIDTH{1'b0}};
            avg0_d <= {DATA_WIDTH{1'b0}};
            avg0_l <= {DATA_WIDTH{1'b0}};
            avg0_r <= {DATA_WIDTH{1'b0}};
            avg1_c <= {DATA_WIDTH{1'b0}};
            avg1_u <= {DATA_WIDTH{1'b0}};
            avg1_d <= {DATA_WIDTH{1'b0}};
            avg1_l <= {DATA_WIDTH{1'b0}};
            avg1_r <= {DATA_WIDTH{1'b0}};
            stage2_valid <= 1'b0;
        end else if (enable && valid_s5) begin
            // Division by weight
            avg0_c <= (w0_c_s3 != 0) ? sum0_c_s3[DATA_WIDTH-1+8:8] / w0_c_s3 : {DATA_WIDTH{1'b0}};
            avg0_u <= (w0_u_s3 != 0) ? sum0_u_s3[DATA_WIDTH-1+8:8] / w0_u_s3 : {DATA_WIDTH{1'b0}};
            avg0_d <= (w0_d_s3 != 0) ? sum0_d_s3[DATA_WIDTH-1+8:8] / w0_d_s3 : {DATA_WIDTH{1'b0}};
            avg0_l <= (w0_l_s3 != 0) ? sum0_l_s3[DATA_WIDTH-1+8:8] / w0_l_s3 : {DATA_WIDTH{1'b0}};
            avg0_r <= (w0_r_s3 != 0) ? sum0_r_s3[DATA_WIDTH-1+8:8] / w0_r_s3 : {DATA_WIDTH{1'b0}};

            avg1_c <= (w1_c_s3 != 0) ? sum1_c_s3[DATA_WIDTH-1+8:8] / w1_c_s3 : {DATA_WIDTH{1'b0}};
            avg1_u <= (w1_u_s3 != 0) ? sum1_u_s3[DATA_WIDTH-1+8:8] / w1_u_s3 : {DATA_WIDTH{1'b0}};
            avg1_d <= (w1_d_s3 != 0) ? sum1_d_s3[DATA_WIDTH-1+8:8] / w1_d_s3 : {DATA_WIDTH{1'b0}};
            avg1_l <= (w1_l_s3 != 0) ? sum1_l_s3[DATA_WIDTH-1+8:8] / w1_l_s3 : {DATA_WIDTH{1'b0}};
            avg1_r <= (w1_r_s3 != 0) ? sum1_r_s3[DATA_WIDTH-1+8:8] / w1_r_s3 : {DATA_WIDTH{1'b0}};

            stage2_valid <= 1'b1;
        end else begin
            stage2_valid <= 1'b0;
        end
    end

endmodule