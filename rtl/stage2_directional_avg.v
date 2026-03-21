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
    output reg                         stage2_valid,
    // Pipelined center pixel and win_size (aligned with avg outputs)
    output reg  [DATA_WIDTH-1:0]       center_pixel_out,
    output reg  [WIN_SIZE_WIDTH-1:0]   win_size_out,
    // Position tracking (pipelined to align with outputs)
    input  wire [13:0]                 pixel_x_in,
    input  wire [12:0]                 pixel_y_in,
    output reg  [13:0]                 pixel_x_out,
    output reg  [12:0]                 pixel_y_out
);

    `include "isp_csiir_defines.vh"

    // Window pipeline registers - delay window by 4 cycles to align with stage1_valid
    // Stage 1 has 4 cycles latency, so window must be delayed 4 cycles
    reg [DATA_WIDTH-1:0] win_s1_0_0, win_s1_0_1, win_s1_0_2, win_s1_0_3, win_s1_0_4;
    reg [DATA_WIDTH-1:0] win_s1_1_0, win_s1_1_1, win_s1_1_2, win_s1_1_3, win_s1_1_4;
    reg [DATA_WIDTH-1:0] win_s1_2_0, win_s1_2_1, win_s1_2_2, win_s1_2_3, win_s1_2_4;
    reg [DATA_WIDTH-1:0] win_s1_3_0, win_s1_3_1, win_s1_3_2, win_s1_3_3, win_s1_3_4;
    reg [DATA_WIDTH-1:0] win_s1_4_0, win_s1_4_1, win_s1_4_2, win_s1_4_3, win_s1_4_4;
    reg                       win_valid_s1;

    reg [DATA_WIDTH-1:0] win_s2_0_0, win_s2_0_1, win_s2_0_2, win_s2_0_3, win_s2_0_4;
    reg [DATA_WIDTH-1:0] win_s2_1_0, win_s2_1_1, win_s2_1_2, win_s2_1_3, win_s2_1_4;
    reg [DATA_WIDTH-1:0] win_s2_2_0, win_s2_2_1, win_s2_2_2, win_s2_2_3, win_s2_2_4;
    reg [DATA_WIDTH-1:0] win_s2_3_0, win_s2_3_1, win_s2_3_2, win_s2_3_3, win_s2_3_4;
    reg [DATA_WIDTH-1:0] win_s2_4_0, win_s2_4_1, win_s2_4_2, win_s2_4_3, win_s2_4_4;
    reg                       win_valid_s2;

    reg [DATA_WIDTH-1:0] win_s3_0_0, win_s3_0_1, win_s3_0_2, win_s3_0_3, win_s3_0_4;
    reg [DATA_WIDTH-1:0] win_s3_1_0, win_s3_1_1, win_s3_1_2, win_s3_1_3, win_s3_1_4;
    reg [DATA_WIDTH-1:0] win_s3_2_0, win_s3_2_1, win_s3_2_2, win_s3_2_3, win_s3_2_4;
    reg [DATA_WIDTH-1:0] win_s3_3_0, win_s3_3_1, win_s3_3_2, win_s3_3_3, win_s3_3_4;
    reg [DATA_WIDTH-1:0] win_s3_4_0, win_s3_4_1, win_s3_4_2, win_s3_4_3, win_s3_4_4;
    reg                       win_valid_s3;

    reg [DATA_WIDTH-1:0] win_s4_0_0, win_s4_0_1, win_s4_0_2, win_s4_0_3, win_s4_0_4;
    reg [DATA_WIDTH-1:0] win_s4_1_0, win_s4_1_1, win_s4_1_2, win_s4_1_3, win_s4_1_4;
    reg [DATA_WIDTH-1:0] win_s4_2_0, win_s4_2_1, win_s4_2_2, win_s4_2_3, win_s4_2_4;
    reg [DATA_WIDTH-1:0] win_s4_3_0, win_s4_3_1, win_s4_3_2, win_s4_3_3, win_s4_3_4;
    reg [DATA_WIDTH-1:0] win_s4_4_0, win_s4_4_1, win_s4_4_2, win_s4_4_3, win_s4_4_4;
    reg                       win_valid_s4;

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
    reg [2:0]                 kernel_select_s1, kernel_select_s2, kernel_select_s3;
    reg                       valid_s1, valid_s2, valid_s3, valid_s4, valid_s5;

    // Stage 1: 4-cycle window pipeline delay to align with stage1_valid from Stage 1
    // Stage 1 has 4 cycles latency, so we need 4 cycles of window delay
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Stage 1 delay
            win_s1_0_0 <= 0; win_s1_0_1 <= 0; win_s1_0_2 <= 0; win_s1_0_3 <= 0; win_s1_0_4 <= 0;
            win_s1_1_0 <= 0; win_s1_1_1 <= 0; win_s1_1_2 <= 0; win_s1_1_3 <= 0; win_s1_1_4 <= 0;
            win_s1_2_0 <= 0; win_s1_2_1 <= 0; win_s1_2_2 <= 0; win_s1_2_3 <= 0; win_s1_2_4 <= 0;
            win_s1_3_0 <= 0; win_s1_3_1 <= 0; win_s1_3_2 <= 0; win_s1_3_3 <= 0; win_s1_3_4 <= 0;
            win_s1_4_0 <= 0; win_s1_4_1 <= 0; win_s1_4_2 <= 0; win_s1_4_3 <= 0; win_s1_4_4 <= 0;
            win_valid_s1 <= 1'b0;
            // Stage 2 delay
            win_s2_0_0 <= 0; win_s2_0_1 <= 0; win_s2_0_2 <= 0; win_s2_0_3 <= 0; win_s2_0_4 <= 0;
            win_s2_1_0 <= 0; win_s2_1_1 <= 0; win_s2_1_2 <= 0; win_s2_1_3 <= 0; win_s2_1_4 <= 0;
            win_s2_2_0 <= 0; win_s2_2_1 <= 0; win_s2_2_2 <= 0; win_s2_2_3 <= 0; win_s2_2_4 <= 0;
            win_s2_3_0 <= 0; win_s2_3_1 <= 0; win_s2_3_2 <= 0; win_s2_3_3 <= 0; win_s2_3_4 <= 0;
            win_s2_4_0 <= 0; win_s2_4_1 <= 0; win_s2_4_2 <= 0; win_s2_4_3 <= 0; win_s2_4_4 <= 0;
            win_valid_s2 <= 1'b0;
            // Stage 3 delay
            win_s3_0_0 <= 0; win_s3_0_1 <= 0; win_s3_0_2 <= 0; win_s3_0_3 <= 0; win_s3_0_4 <= 0;
            win_s3_1_0 <= 0; win_s3_1_1 <= 0; win_s3_1_2 <= 0; win_s3_1_3 <= 0; win_s3_1_4 <= 0;
            win_s3_2_0 <= 0; win_s3_2_1 <= 0; win_s3_2_2 <= 0; win_s3_2_3 <= 0; win_s3_2_4 <= 0;
            win_s3_3_0 <= 0; win_s3_3_1 <= 0; win_s3_3_2 <= 0; win_s3_3_3 <= 0; win_s3_3_4 <= 0;
            win_s3_4_0 <= 0; win_s3_4_1 <= 0; win_s3_4_2 <= 0; win_s3_4_3 <= 0; win_s3_4_4 <= 0;
            win_valid_s3 <= 1'b0;
            // Stage 4 delay (aligned with stage1_valid)
            win_s4_0_0 <= 0; win_s4_0_1 <= 0; win_s4_0_2 <= 0; win_s4_0_3 <= 0; win_s4_0_4 <= 0;
            win_s4_1_0 <= 0; win_s4_1_1 <= 0; win_s4_1_2 <= 0; win_s4_1_3 <= 0; win_s4_1_4 <= 0;
            win_s4_2_0 <= 0; win_s4_2_1 <= 0; win_s4_2_2 <= 0; win_s4_2_3 <= 0; win_s4_2_4 <= 0;
            win_s4_3_0 <= 0; win_s4_3_1 <= 0; win_s4_3_2 <= 0; win_s4_3_3 <= 0; win_s4_3_4 <= 0;
            win_s4_4_0 <= 0; win_s4_4_1 <= 0; win_s4_4_2 <= 0; win_s4_4_3 <= 0; win_s4_4_4 <= 0;
            win_valid_s4 <= 1'b0;
            kernel_select <= 3'd0;
            win_size_s1   <= {WIN_SIZE_WIDTH{1'b0}};
            valid_s1      <= 1'b0;
        end else if (enable && window_valid) begin
            // Stage 1: Capture current window
            win_s1_0_0 <= window_0_0; win_s1_0_1 <= window_0_1; win_s1_0_2 <= window_0_2; win_s1_0_3 <= window_0_3; win_s1_0_4 <= window_0_4;
            win_s1_1_0 <= window_1_0; win_s1_1_1 <= window_1_1; win_s1_1_2 <= window_1_2; win_s1_1_3 <= window_1_3; win_s1_1_4 <= window_1_4;
            win_s1_2_0 <= window_2_0; win_s1_2_1 <= window_2_1; win_s1_2_2 <= window_2_2; win_s1_2_3 <= window_2_3; win_s1_2_4 <= window_2_4;
            win_s1_3_0 <= window_3_0; win_s1_3_1 <= window_3_1; win_s1_3_2 <= window_3_2; win_s1_3_3 <= window_3_3; win_s1_3_4 <= window_3_4;
            win_s1_4_0 <= window_4_0; win_s1_4_1 <= window_4_1; win_s1_4_2 <= window_4_2; win_s1_4_3 <= window_4_3; win_s1_4_4 <= window_4_4;
            win_valid_s1 <= 1'b1;

            // Stage 2: Shift from stage 1
            win_s2_0_0 <= win_s1_0_0; win_s2_0_1 <= win_s1_0_1; win_s2_0_2 <= win_s1_0_2; win_s2_0_3 <= win_s1_0_3; win_s2_0_4 <= win_s1_0_4;
            win_s2_1_0 <= win_s1_1_0; win_s2_1_1 <= win_s1_1_1; win_s2_1_2 <= win_s1_1_2; win_s2_1_3 <= win_s1_1_3; win_s2_1_4 <= win_s1_1_4;
            win_s2_2_0 <= win_s1_2_0; win_s2_2_1 <= win_s1_2_1; win_s2_2_2 <= win_s1_2_2; win_s2_2_3 <= win_s1_2_3; win_s2_2_4 <= win_s1_2_4;
            win_s2_3_0 <= win_s1_3_0; win_s2_3_1 <= win_s1_3_1; win_s2_3_2 <= win_s1_3_2; win_s2_3_3 <= win_s1_3_3; win_s2_3_4 <= win_s1_3_4;
            win_s2_4_0 <= win_s1_4_0; win_s2_4_1 <= win_s1_4_1; win_s2_4_2 <= win_s1_4_2; win_s2_4_3 <= win_s1_4_3; win_s2_4_4 <= win_s1_4_4;
            win_valid_s2 <= win_valid_s1;

            // Stage 3: Shift from stage 2
            win_s3_0_0 <= win_s2_0_0; win_s3_0_1 <= win_s2_0_1; win_s3_0_2 <= win_s2_0_2; win_s3_0_3 <= win_s2_0_3; win_s3_0_4 <= win_s2_0_4;
            win_s3_1_0 <= win_s2_1_0; win_s3_1_1 <= win_s2_1_1; win_s3_1_2 <= win_s2_1_2; win_s3_1_3 <= win_s2_1_3; win_s3_1_4 <= win_s2_1_4;
            win_s3_2_0 <= win_s2_2_0; win_s3_2_1 <= win_s2_2_1; win_s3_2_2 <= win_s2_2_2; win_s3_2_3 <= win_s2_2_3; win_s3_2_4 <= win_s2_2_4;
            win_s3_3_0 <= win_s2_3_0; win_s3_3_1 <= win_s2_3_1; win_s3_3_2 <= win_s2_3_2; win_s3_3_3 <= win_s2_3_3; win_s3_3_4 <= win_s2_3_4;
            win_s3_4_0 <= win_s2_4_0; win_s3_4_1 <= win_s2_4_1; win_s3_4_2 <= win_s2_4_2; win_s3_4_3 <= win_s2_4_3; win_s3_4_4 <= win_s2_4_4;
            win_valid_s3 <= win_valid_s2;

            // Stage 4: Shift from stage 3 (this is aligned with stage1_valid)
            win_s4_0_0 <= win_s3_0_0; win_s4_0_1 <= win_s3_0_1; win_s4_0_2 <= win_s3_0_2; win_s4_0_3 <= win_s3_0_3; win_s4_0_4 <= win_s3_0_4;
            win_s4_1_0 <= win_s3_1_0; win_s4_1_1 <= win_s3_1_1; win_s4_1_2 <= win_s3_1_2; win_s4_1_3 <= win_s3_1_3; win_s4_1_4 <= win_s3_1_4;
            win_s4_2_0 <= win_s3_2_0; win_s4_2_1 <= win_s3_2_1; win_s4_2_2 <= win_s3_2_2; win_s4_2_3 <= win_s3_2_3; win_s4_2_4 <= win_s3_2_4;
            win_s4_3_0 <= win_s3_3_0; win_s4_3_1 <= win_s3_3_1; win_s4_3_2 <= win_s3_3_2; win_s4_3_3 <= win_s3_3_3; win_s4_3_4 <= win_s3_3_4;
            win_s4_4_0 <= win_s3_4_0; win_s4_4_1 <= win_s3_4_1; win_s4_4_2 <= win_s3_4_2; win_s4_4_3 <= win_s3_4_3; win_s4_4_4 <= win_s3_4_4;
            win_valid_s4 <= win_valid_s3;

            valid_s1 <= 1'b1;
        end else begin
            win_valid_s1 <= 1'b0;
            win_valid_s2 <= 1'b0;
            win_valid_s3 <= 1'b0;
            win_valid_s4 <= 1'b0;
            valid_s1 <= 1'b0;
        end
    end

    // Combinational kernel_select based on win_size_clip from Stage 1
    // This is used when stage1_valid fires along with win_s4 window
    wire [2:0] kernel_select_comb;
    assign kernel_select_comb = (win_size_clip < win_size_thresh0[5:0]) ? 3'd0 :
                                (win_size_clip < win_size_thresh1[5:0]) ? 3'd1 :
                                (win_size_clip < win_size_thresh2[5:0]) ? 3'd2 :
                                (win_size_clip < win_size_thresh3[5:0]) ? 3'd3 : 3'd4;

    // Pipeline win_size_clip along with window data
    // Stage 1 has 4 cycles latency, so when stage1_valid fires, win_s4 has the right window
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            win_size_s1 <= {WIN_SIZE_WIDTH{1'b0}};
            win_size_s2 <= {WIN_SIZE_WIDTH{1'b0}};
            win_size_s3 <= {WIN_SIZE_WIDTH{1'b0}};
            kernel_select <= 3'd0;
        end else if (enable && stage1_valid) begin
            // Pipeline win_size_clip from Stage 1
            win_size_s1 <= win_size_clip;
            win_size_s2 <= win_size_s1;
            win_size_s3 <= win_size_s2;
            // Register kernel_select for output
            kernel_select <= kernel_select_comb;
        end
    end

    // Stage 2-3: Compute weighted sums for each direction
    // Use delayed window (win_s4_*) which is aligned with stage1_valid
    // Use kernel_select_comb (combinational) for correct timing
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
            valid_s2 <= 1'b0;
        end else if (enable && stage1_valid) begin
            // Use kernel_select_comb for correct timing with win_s4_*
            case (kernel_select_comb)
                3'd0: begin
                    // avg0 = zeros (all zero), avg1 = 2x2 kernel
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

                // avg1 = 2x2 kernel - use delayed window values
                sum1_c <= (win_s4_1_1 * 1 + win_s4_1_2 * 2 + win_s4_1_3 * 1 +
                           win_s4_2_1 * 2 + win_s4_2_2 * 4 + win_s4_2_3 * 2 +
                           win_s4_3_1 * 1 + win_s4_3_2 * 2 + win_s4_3_3 * 1);
                weight1_c <= 8'd16;

                sum1_u <= (win_s4_0_1 * 1 + win_s4_0_2 * 2 + win_s4_0_3 * 1 +
                           win_s4_1_1 * 1 + win_s4_1_2 * 2 + win_s4_1_3 * 1 +
                           win_s4_2_1 * 1 + win_s4_2_2 * 2 + win_s4_2_3 * 1);
                weight1_u <= 8'd12;

                sum1_d <= (win_s4_2_1 * 1 + win_s4_2_2 * 2 + win_s4_2_3 * 1 +
                           win_s4_3_1 * 1 + win_s4_3_2 * 2 + win_s4_3_3 * 1 +
                           win_s4_4_1 * 1 + win_s4_4_2 * 2 + win_s4_4_3 * 1);
                weight1_d <= 8'd12;

                sum1_l <= (win_s4_1_0 * 1 + win_s4_1_1 * 2 + win_s4_1_2 * 1 +
                           win_s4_2_0 * 2 + win_s4_2_1 * 4 + win_s4_2_2 * 2 +
                           win_s4_3_0 * 1 + win_s4_3_1 * 2 + win_s4_3_2 * 1);
                weight1_l <= 8'd16;

                sum1_r <= (win_s4_1_2 * 1 + win_s4_1_3 * 2 + win_s4_1_4 * 1 +
                           win_s4_2_2 * 2 + win_s4_2_3 * 4 + win_s4_2_4 * 2 +
                           win_s4_3_2 * 1 + win_s4_3_3 * 2 + win_s4_3_4 * 1);
                weight1_r <= 8'd16;

                end
                3'd1: begin
                    // avg0 = 2x2 kernel
                sum0_c <= (win_s4_1_1 * 1 + win_s4_1_2 * 2 + win_s4_1_3 * 1 +
                           win_s4_2_1 * 2 + win_s4_2_2 * 4 + win_s4_2_3 * 2 +
                           win_s4_3_1 * 1 + win_s4_3_2 * 2 + win_s4_3_3 * 1);
                weight0_c <= 8'd16;

                sum0_u <= (win_s4_0_1 * 1 + win_s4_0_2 * 2 + win_s4_0_3 * 1 +
                           win_s4_1_1 * 1 + win_s4_1_2 * 2 + win_s4_1_3 * 1 +
                           win_s4_2_1 * 1 + win_s4_2_2 * 2 + win_s4_2_3 * 1);
                weight0_u <= 8'd12;

                sum0_d <= (win_s4_2_1 * 1 + win_s4_2_2 * 2 + win_s4_2_3 * 1 +
                           win_s4_3_1 * 1 + win_s4_3_2 * 2 + win_s4_3_3 * 1 +
                           win_s4_4_1 * 1 + win_s4_4_2 * 2 + win_s4_4_3 * 1);
                weight0_d <= 8'd12;

                sum0_l <= (win_s4_1_0 * 1 + win_s4_1_1 * 2 + win_s4_1_2 * 1 +
                           win_s4_2_0 * 2 + win_s4_2_1 * 4 + win_s4_2_2 * 2 +
                           win_s4_3_0 * 1 + win_s4_3_1 * 2 + win_s4_3_2 * 1);
                weight0_l <= 8'd16;

                sum0_r <= (win_s4_1_2 * 1 + win_s4_1_3 * 2 + win_s4_1_4 * 1 +
                           win_s4_2_2 * 2 + win_s4_2_3 * 4 + win_s4_2_4 * 2 +
                           win_s4_3_2 * 1 + win_s4_3_3 * 2 + win_s4_3_4 * 1);
                weight0_r <= 8'd16;

                // avg1 = 3x3 uniform
                sum1_c <= (win_s4_1_1 + win_s4_1_2 + win_s4_1_3 +
                           win_s4_2_1 + win_s4_2_2 + win_s4_2_3 +
                           win_s4_3_1 + win_s4_3_2 + win_s4_3_3);
                weight1_c <= 8'd9;

                sum1_u <= (win_s4_0_1 + win_s4_0_2 + win_s4_0_3 +
                           win_s4_1_1 + win_s4_1_2 + win_s4_1_3 +
                           win_s4_2_1 + win_s4_2_2 + win_s4_2_3);
                weight1_u <= 8'd9;

                sum1_d <= (win_s4_2_1 + win_s4_2_2 + win_s4_2_3 +
                           win_s4_3_1 + win_s4_3_2 + win_s4_3_3 +
                           win_s4_4_1 + win_s4_4_2 + win_s4_4_3);
                weight1_d <= 8'd9;

                sum1_l <= (win_s4_1_0 + win_s4_1_1 + win_s4_1_2 +
                           win_s4_2_0 + win_s4_2_1 + win_s4_2_2 +
                           win_s4_3_0 + win_s4_3_1 + win_s4_3_2);
                weight1_l <= 8'd9;

                sum1_r <= (win_s4_1_2 + win_s4_1_3 + win_s4_1_4 +
                           win_s4_2_2 + win_s4_2_3 + win_s4_2_4 +
                           win_s4_3_2 + win_s4_3_3 + win_s4_3_4);
                weight1_r <= 8'd9;

                end
                3'd2: begin
                    // avg0 = 3x3 uniform
                sum0_c <= (win_s4_1_1 + win_s4_1_2 + win_s4_1_3 +
                           win_s4_2_1 + win_s4_2_2 + win_s4_2_3 +
                           win_s4_3_1 + win_s4_3_2 + win_s4_3_3);
                weight0_c <= 8'd9;

                sum0_u <= (win_s4_0_1 + win_s4_0_2 + win_s4_0_3 +
                           win_s4_1_1 + win_s4_1_2 + win_s4_1_3 +
                           win_s4_2_1 + win_s4_2_2 + win_s4_2_3);
                weight0_u <= 8'd9;

                sum0_d <= (win_s4_2_1 + win_s4_2_2 + win_s4_2_3 +
                           win_s4_3_1 + win_s4_3_2 + win_s4_3_3 +
                           win_s4_4_1 + win_s4_4_2 + win_s4_4_3);
                weight0_d <= 8'd9;

                sum0_l <= (win_s4_1_0 + win_s4_1_1 + win_s4_1_2 +
                           win_s4_2_0 + win_s4_2_1 + win_s4_2_2 +
                           win_s4_3_0 + win_s4_3_1 + win_s4_3_2);
                weight0_l <= 8'd9;

                sum0_r <= (win_s4_1_2 + win_s4_1_3 + win_s4_1_4 +
                           win_s4_2_2 + win_s4_2_3 + win_s4_2_4 +
                           win_s4_3_2 + win_s4_3_3 + win_s4_3_4);
                weight0_r <= 8'd9;

                // avg1 = 4x4 kernel
                sum1_c <= (win_s4_0_0 + win_s4_0_1 + win_s4_0_2*2 + win_s4_0_3 + win_s4_0_4 +
                           win_s4_1_0 + win_s4_1_1*2 + win_s4_1_2*4 + win_s4_1_3*2 + win_s4_1_4 +
                           win_s4_2_0*2 + win_s4_2_1*4 + win_s4_2_2*8 + win_s4_2_3*4 + win_s4_2_4*2 +
                           win_s4_3_0 + win_s4_3_1*2 + win_s4_3_2*4 + win_s4_3_3*2 + win_s4_3_4 +
                           win_s4_4_0 + win_s4_4_1 + win_s4_4_2*2 + win_s4_4_3 + win_s4_4_4);
                weight1_c <= 8'd44;

                sum1_u <= (win_s4_0_0 + win_s4_0_1 + win_s4_0_2*2 + win_s4_0_3 + win_s4_0_4 +
                           win_s4_1_0 + win_s4_1_1*2 + win_s4_1_2*4 + win_s4_1_3*2 + win_s4_1_4 +
                           win_s4_2_0*2 + win_s4_2_1*4 + win_s4_2_2*8 + win_s4_2_3*4 + win_s4_2_4*2);
                weight1_u <= 8'd36;

                sum1_d <= (win_s4_2_0*2 + win_s4_2_1*4 + win_s4_2_2*8 + win_s4_2_3*4 + win_s4_2_4*2 +
                           win_s4_3_0 + win_s4_3_1*2 + win_s4_3_2*4 + win_s4_3_3*2 + win_s4_3_4 +
                           win_s4_4_0 + win_s4_4_1 + win_s4_4_2*2 + win_s4_4_3 + win_s4_4_4);
                weight1_d <= 8'd36;

                sum1_l <= (win_s4_0_0 + win_s4_0_1 + win_s4_0_2*2 +
                           win_s4_1_0 + win_s4_1_1*2 + win_s4_1_2*4 +
                           win_s4_2_0*2 + win_s4_2_1*4 + win_s4_2_2*8 +
                           win_s4_3_0 + win_s4_3_1*2 + win_s4_3_2*4 +
                           win_s4_4_0 + win_s4_4_1 + win_s4_4_2*2);
                weight1_l <= 8'd36;

                sum1_r <= (win_s4_0_2*2 + win_s4_0_3 + win_s4_0_4 +
                           win_s4_1_2*4 + win_s4_1_3*2 + win_s4_1_4 +
                           win_s4_2_2*8 + win_s4_2_3*4 + win_s4_2_4*2 +
                           win_s4_3_2*4 + win_s4_3_3*2 + win_s4_3_4 +
                           win_s4_4_2*2 + win_s4_4_3 + win_s4_4_4);
                weight1_r <= 8'd36;

                end
                3'd3: begin
                    // avg0 = 4x4 kernel
                sum0_c <= (win_s4_0_0 + win_s4_0_1 + win_s4_0_2*2 + win_s4_0_3 + win_s4_0_4 +
                           win_s4_1_0 + win_s4_1_1*2 + win_s4_1_2*4 + win_s4_1_3*2 + win_s4_1_4 +
                           win_s4_2_0*2 + win_s4_2_1*4 + win_s4_2_2*8 + win_s4_2_3*4 + win_s4_2_4*2 +
                           win_s4_3_0 + win_s4_3_1*2 + win_s4_3_2*4 + win_s4_3_3*2 + win_s4_3_4 +
                           win_s4_4_0 + win_s4_4_1 + win_s4_4_2*2 + win_s4_4_3 + win_s4_4_4);
                weight0_c <= 8'd44;

                sum0_u <= (win_s4_0_0 + win_s4_0_1 + win_s4_0_2*2 + win_s4_0_3 + win_s4_0_4 +
                           win_s4_1_0 + win_s4_1_1*2 + win_s4_1_2*4 + win_s4_1_3*2 + win_s4_1_4 +
                           win_s4_2_0*2 + win_s4_2_1*4 + win_s4_2_2*8 + win_s4_2_3*4 + win_s4_2_4*2);
                weight0_u <= 8'd36;

                sum0_d <= (win_s4_2_0*2 + win_s4_2_1*4 + win_s4_2_2*8 + win_s4_2_3*4 + win_s4_2_4*2 +
                           win_s4_3_0 + win_s4_3_1*2 + win_s4_3_2*4 + win_s4_3_3*2 + win_s4_3_4 +
                           win_s4_4_0 + win_s4_4_1 + win_s4_4_2*2 + win_s4_4_3 + win_s4_4_4);
                weight0_d <= 8'd36;

                sum0_l <= (win_s4_0_0 + win_s4_0_1 + win_s4_0_2*2 +
                           win_s4_1_0 + win_s4_1_1*2 + win_s4_1_2*4 +
                           win_s4_2_0*2 + win_s4_2_1*4 + win_s4_2_2*8 +
                           win_s4_3_0 + win_s4_3_1*2 + win_s4_3_2*4 +
                           win_s4_4_0 + win_s4_4_1 + win_s4_4_2*2);
                weight0_l <= 8'd36;

                sum0_r <= (win_s4_0_2*2 + win_s4_0_3 + win_s4_0_4 +
                           win_s4_1_2*4 + win_s4_1_3*2 + win_s4_1_4 +
                           win_s4_2_2*8 + win_s4_2_3*4 + win_s4_2_4*2 +
                           win_s4_3_2*4 + win_s4_3_3*2 + win_s4_3_4 +
                           win_s4_4_2*2 + win_s4_4_3 + win_s4_4_4);
                weight0_r <= 8'd36;

                // avg1 = 5x5 uniform
                sum1_c <= (win_s4_0_0 + win_s4_0_1 + win_s4_0_2 + win_s4_0_3 + win_s4_0_4 +
                           win_s4_1_0 + win_s4_1_1 + win_s4_1_2 + win_s4_1_3 + win_s4_1_4 +
                           win_s4_2_0 + win_s4_2_1 + win_s4_2_2 + win_s4_2_3 + win_s4_2_4 +
                           win_s4_3_0 + win_s4_3_1 + win_s4_3_2 + win_s4_3_3 + win_s4_3_4 +
                           win_s4_4_0 + win_s4_4_1 + win_s4_4_2 + win_s4_4_3 + win_s4_4_4);
                weight1_c <= 8'd25;

                sum1_u <= (win_s4_0_0 + win_s4_0_1 + win_s4_0_2 + win_s4_0_3 + win_s4_0_4 +
                           win_s4_1_0 + win_s4_1_1 + win_s4_1_2 + win_s4_1_3 + win_s4_1_4 +
                           win_s4_2_0 + win_s4_2_1 + win_s4_2_2 + win_s4_2_3 + win_s4_2_4);
                weight1_u <= 8'd15;

                sum1_d <= (win_s4_2_0 + win_s4_2_1 + win_s4_2_2 + win_s4_2_3 + win_s4_2_4 +
                           win_s4_3_0 + win_s4_3_1 + win_s4_3_2 + win_s4_3_3 + win_s4_3_4 +
                           win_s4_4_0 + win_s4_4_1 + win_s4_4_2 + win_s4_4_3 + win_s4_4_4);
                weight1_d <= 8'd15;

                sum1_l <= (win_s4_0_0 + win_s4_0_1 + win_s4_0_2 +
                           win_s4_1_0 + win_s4_1_1 + win_s4_1_2 +
                           win_s4_2_0 + win_s4_2_1 + win_s4_2_2 +
                           win_s4_3_0 + win_s4_3_1 + win_s4_3_2 +
                           win_s4_4_0 + win_s4_4_1 + win_s4_4_2);
                weight1_l <= 8'd15;

                sum1_r <= (win_s4_0_2 + win_s4_0_3 + win_s4_0_4 +
                           win_s4_1_2 + win_s4_1_3 + win_s4_1_4 +
                           win_s4_2_2 + win_s4_2_3 + win_s4_2_4 +
                           win_s4_3_2 + win_s4_3_3 + win_s4_3_4 +
                           win_s4_4_2 + win_s4_4_3 + win_s4_4_4);
                weight1_r <= 8'd15;

                end
                default: begin
                    // avg0 = 5x5 uniform, avg1 = zeros
                sum0_c <= (win_s4_0_0 + win_s4_0_1 + win_s4_0_2 + win_s4_0_3 + win_s4_0_4 +
                           win_s4_1_0 + win_s4_1_1 + win_s4_1_2 + win_s4_1_3 + win_s4_1_4 +
                           win_s4_2_0 + win_s4_2_1 + win_s4_2_2 + win_s4_2_3 + win_s4_2_4 +
                           win_s4_3_0 + win_s4_3_1 + win_s4_3_2 + win_s4_3_3 + win_s4_3_4 +
                           win_s4_4_0 + win_s4_4_1 + win_s4_4_2 + win_s4_4_3 + win_s4_4_4);
                weight0_c <= 8'd25;

                sum0_u <= (win_s4_0_0 + win_s4_0_1 + win_s4_0_2 + win_s4_0_3 + win_s4_0_4 +
                           win_s4_1_0 + win_s4_1_1 + win_s4_1_2 + win_s4_1_3 + win_s4_1_4 +
                           win_s4_2_0 + win_s4_2_1 + win_s4_2_2 + win_s4_2_3 + win_s4_2_4);
                weight0_u <= 8'd15;

                sum0_d <= (win_s4_2_0 + win_s4_2_1 + win_s4_2_2 + win_s4_2_3 + win_s4_2_4 +
                           win_s4_3_0 + win_s4_3_1 + win_s4_3_2 + win_s4_3_3 + win_s4_3_4 +
                           win_s4_4_0 + win_s4_4_1 + win_s4_4_2 + win_s4_4_3 + win_s4_4_4);
                weight0_d <= 8'd15;

                sum0_l <= (win_s4_0_0 + win_s4_0_1 + win_s4_0_2 +
                           win_s4_1_0 + win_s4_1_1 + win_s4_1_2 +
                           win_s4_2_0 + win_s4_2_1 + win_s4_2_2 +
                           win_s4_3_0 + win_s4_3_1 + win_s4_3_2 +
                           win_s4_4_0 + win_s4_4_1 + win_s4_4_2);
                weight0_l <= 8'd15;

                sum0_r <= (win_s4_0_2 + win_s4_0_3 + win_s4_0_4 +
                           win_s4_1_2 + win_s4_1_3 + win_s4_1_4 +
                           win_s4_2_2 + win_s4_2_3 + win_s4_2_4 +
                           win_s4_3_2 + win_s4_3_3 + win_s4_3_4 +
                           win_s4_4_2 + win_s4_4_3 + win_s4_4_4);
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

    // Stage 3-5: Pipeline the sums and weights for division
    // Need to pipeline through s3, s4, s5 to match valid signal timing
    reg [ACC_WIDTH-1:0] sum0_c_s3, sum0_u_s3, sum0_d_s3, sum0_l_s3, sum0_r_s3;
    reg [ACC_WIDTH-1:0] sum1_c_s3, sum1_u_s3, sum1_d_s3, sum1_l_s3, sum1_r_s3;
    reg [7:0] w0_c_s3, w0_u_s3, w0_d_s3, w0_l_s3, w0_r_s3;
    reg [7:0] w1_c_s3, w1_u_s3, w1_d_s3, w1_l_s3, w1_r_s3;
    // s4 pipeline registers
    reg [ACC_WIDTH-1:0] sum0_c_s4, sum0_u_s4, sum0_d_s4, sum0_l_s4, sum0_r_s4;
    reg [ACC_WIDTH-1:0] sum1_c_s4, sum1_u_s4, sum1_d_s4, sum1_l_s4, sum1_r_s4;
    reg [7:0] w0_c_s4, w0_u_s4, w0_d_s4, w0_l_s4, w0_r_s4;
    reg [7:0] w1_c_s4, w1_u_s4, w1_d_s4, w1_l_s4, w1_r_s4;
    // s5 pipeline registers (used for division)
    reg [ACC_WIDTH-1:0] sum0_c_s5, sum0_u_s5, sum0_d_s5, sum0_l_s5, sum0_r_s5;
    reg [ACC_WIDTH-1:0] sum1_c_s5, sum1_u_s5, sum1_d_s5, sum1_l_s5, sum1_r_s5;
    reg [7:0] w0_c_s5, w0_u_s5, w0_d_s5, w0_l_s5, w0_r_s5;
    reg [7:0] w1_c_s5, w1_u_s5, w1_d_s5, w1_l_s5, w1_r_s5;

    // Center pixel pipeline - track win_s4_2_2 through the pipeline
    // center_s2 captures when stage1_valid fires (same time as sum computation)
    // Then it's pipelined through s3, s4, s5 along with the sums
    reg [DATA_WIDTH-1:0] center_s2, center_s3, center_s4, center_s5;
    reg [WIN_SIZE_WIDTH-1:0] win_size_s4_pipe, win_size_s5_pipe;

    // Position pipeline - track pixel_x/y through the pipeline
    reg [13:0] pixel_x_s2, pixel_x_s3, pixel_x_s4, pixel_x_s5;
    reg [12:0] pixel_y_s2, pixel_y_s3, pixel_y_s4, pixel_y_s5;

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
            sum0_c_s4 <= {ACC_WIDTH{1'b0}};
            sum0_u_s4 <= {ACC_WIDTH{1'b0}};
            sum0_d_s4 <= {ACC_WIDTH{1'b0}};
            sum0_l_s4 <= {ACC_WIDTH{1'b0}};
            sum0_r_s4 <= {ACC_WIDTH{1'b0}};
            sum1_c_s4 <= {ACC_WIDTH{1'b0}};
            sum1_u_s4 <= {ACC_WIDTH{1'b0}};
            sum1_d_s4 <= {ACC_WIDTH{1'b0}};
            sum1_l_s4 <= {ACC_WIDTH{1'b0}};
            sum1_r_s4 <= {ACC_WIDTH{1'b0}};
            w0_c_s4 <= 8'd0;
            w0_u_s4 <= 8'd0;
            w0_d_s4 <= 8'd0;
            w0_l_s4 <= 8'd0;
            w0_r_s4 <= 8'd0;
            w1_c_s4 <= 8'd0;
            w1_u_s4 <= 8'd0;
            w1_d_s4 <= 8'd0;
            w1_l_s4 <= 8'd0;
            w1_r_s4 <= 8'd0;
            sum0_c_s5 <= {ACC_WIDTH{1'b0}};
            sum0_u_s5 <= {ACC_WIDTH{1'b0}};
            sum0_d_s5 <= {ACC_WIDTH{1'b0}};
            sum0_l_s5 <= {ACC_WIDTH{1'b0}};
            sum0_r_s5 <= {ACC_WIDTH{1'b0}};
            sum1_c_s5 <= {ACC_WIDTH{1'b0}};
            sum1_u_s5 <= {ACC_WIDTH{1'b0}};
            sum1_d_s5 <= {ACC_WIDTH{1'b0}};
            sum1_l_s5 <= {ACC_WIDTH{1'b0}};
            sum1_r_s5 <= {ACC_WIDTH{1'b0}};
            w0_c_s5 <= 8'd0;
            w0_u_s5 <= 8'd0;
            w0_d_s5 <= 8'd0;
            w0_l_s5 <= 8'd0;
            w0_r_s5 <= 8'd0;
            w1_c_s5 <= 8'd0;
            w1_u_s5 <= 8'd0;
            w1_d_s5 <= 8'd0;
            w1_l_s5 <= 8'd0;
            w1_r_s5 <= 8'd0;
            center_s2 <= {DATA_WIDTH{1'b0}};
            center_s3 <= {DATA_WIDTH{1'b0}};
            center_s4 <= {DATA_WIDTH{1'b0}};
            center_s5 <= {DATA_WIDTH{1'b0}};
            win_size_s4_pipe <= {WIN_SIZE_WIDTH{1'b0}};
            win_size_s5_pipe <= {WIN_SIZE_WIDTH{1'b0}};
            pixel_x_s2 <= 14'd0;
            pixel_x_s3 <= 14'd0;
            pixel_x_s4 <= 14'd0;
            pixel_x_s5 <= 14'd0;
            pixel_y_s2 <= 13'd0;
            pixel_y_s3 <= 13'd0;
            pixel_y_s4 <= 13'd0;
            pixel_y_s5 <= 13'd0;
        end else if (enable) begin
            // Capture center pixel when stage1_valid fires (same time as sum computation)
            if (stage1_valid) begin
                center_s2 <= win_s4_2_2;
                pixel_x_s2 <= pixel_x_in;
                pixel_y_s2 <= pixel_y_in;
            end
            // s3: capture from sum/weight registers when valid_s2
            // But center pixel must be captured from the s2 register (center_s2)
            // which was captured when stage1_valid fired
            if (valid_s2) begin
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
                // Pipeline center pixel from center_s2 (captured when stage1_valid fired)
                // Use win_size_s2 which holds the win_size from when this pixel's stage1_valid fired
                // (not win_size_s1 which gets updated with the next pixel's value)
                center_s3 <= center_s2;
                win_size_s4_pipe <= win_size_s2;
                pixel_x_s3 <= pixel_x_s2;
                pixel_y_s3 <= pixel_y_s2;
            end
            // s4: pipeline from s3
            if (valid_s3) begin
                sum0_c_s4 <= sum0_c_s3;
                sum0_u_s4 <= sum0_u_s3;
                sum0_d_s4 <= sum0_d_s3;
                sum0_l_s4 <= sum0_l_s3;
                sum0_r_s4 <= sum0_r_s3;
                sum1_c_s4 <= sum1_c_s3;
                sum1_u_s4 <= sum1_u_s3;
                sum1_d_s4 <= sum1_d_s3;
                sum1_l_s4 <= sum1_l_s3;
                sum1_r_s4 <= sum1_r_s3;
                w0_c_s4 <= w0_c_s3;
                w0_u_s4 <= w0_u_s3;
                w0_d_s4 <= w0_d_s3;
                w0_l_s4 <= w0_l_s3;
                w0_r_s4 <= w0_r_s3;
                w1_c_s4 <= w1_c_s3;
                w1_u_s4 <= w1_u_s3;
                w1_d_s4 <= w1_d_s3;
                w1_l_s4 <= w1_l_s3;
                w1_r_s4 <= w1_r_s3;
                center_s4 <= center_s3;
                win_size_s5_pipe <= win_size_s4_pipe;
                pixel_x_s4 <= pixel_x_s3;
                pixel_y_s4 <= pixel_y_s3;
            end
            // s5: pipeline from s4
            if (valid_s4) begin
                sum0_c_s5 <= sum0_c_s4;
                sum0_u_s5 <= sum0_u_s4;
                sum0_d_s5 <= sum0_d_s4;
                sum0_l_s5 <= sum0_l_s4;
                sum0_r_s5 <= sum0_r_s4;
                sum1_c_s5 <= sum1_c_s4;
                sum1_u_s5 <= sum1_u_s4;
                sum1_d_s5 <= sum1_d_s4;
                sum1_l_s5 <= sum1_l_s4;
                sum1_r_s5 <= sum1_r_s4;
                w0_c_s5 <= w0_c_s4;
                w0_u_s5 <= w0_u_s4;
                w0_d_s5 <= w0_d_s4;
                w0_l_s5 <= w0_l_s4;
                w0_r_s5 <= w0_r_s4;
                w1_c_s5 <= w1_c_s4;
                w1_u_s5 <= w1_u_s4;
                w1_d_s5 <= w1_d_s4;
                w1_l_s5 <= w1_l_s4;
                w1_r_s5 <= w1_r_s4;
                center_s5 <= center_s4;
                win_size_s5_pipe <= win_size_s4_pipe;
                pixel_x_s5 <= pixel_x_s4;
                pixel_y_s5 <= pixel_y_s4;
            end
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
            center_pixel_out <= {DATA_WIDTH{1'b0}};
            win_size_out <= {WIN_SIZE_WIDTH{1'b0}};
            pixel_x_out <= 14'd0;
            pixel_y_out <= 13'd0;
        end else if (enable && valid_s5) begin
            // Division by weight (direct division of accumulated sum)
            // Use s5 registers which are properly pipelined with valid signals
            avg0_c <= (w0_c_s5 != 0) ? sum0_c_s5 / w0_c_s5 : {DATA_WIDTH{1'b0}};
            avg0_u <= (w0_u_s5 != 0) ? sum0_u_s5 / w0_u_s5 : {DATA_WIDTH{1'b0}};
            avg0_d <= (w0_d_s5 != 0) ? sum0_d_s5 / w0_d_s5 : {DATA_WIDTH{1'b0}};
            avg0_l <= (w0_l_s5 != 0) ? sum0_l_s5 / w0_l_s5 : {DATA_WIDTH{1'b0}};
            avg0_r <= (w0_r_s5 != 0) ? sum0_r_s5 / w0_r_s5 : {DATA_WIDTH{1'b0}};

            avg1_c <= (w1_c_s5 != 0) ? sum1_c_s5 / w1_c_s5 : {DATA_WIDTH{1'b0}};
            avg1_u <= (w1_u_s5 != 0) ? sum1_u_s5 / w1_u_s5 : {DATA_WIDTH{1'b0}};
            avg1_d <= (w1_d_s5 != 0) ? sum1_d_s5 / w1_d_s5 : {DATA_WIDTH{1'b0}};
            avg1_l <= (w1_l_s5 != 0) ? sum1_l_s5 / w1_l_s5 : {DATA_WIDTH{1'b0}};
            avg1_r <= (w1_r_s5 != 0) ? sum1_r_s5 / w1_r_s5 : {DATA_WIDTH{1'b0}};

            // Output pipelined center pixel and win_size
            center_pixel_out <= center_s5;
            win_size_out <= win_size_s5_pipe;
            pixel_x_out <= pixel_x_s5;
            pixel_y_out <= pixel_y_s5;
            win_size_out <= win_size_s5_pipe;

            stage2_valid <= 1'b1;
        end else begin
            stage2_valid <= 1'b0;
        end
    end

endmodule