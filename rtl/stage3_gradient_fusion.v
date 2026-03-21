//-----------------------------------------------------------------------------
// Module: stage3_gradient_fusion
// Description: Stage 3 - Gradient sorting and weighted directional fusion
//              Refactored to use combinational + pipe pattern
//              Pipeline stages: 4 cycles
//              Fully parameterized for resolution and data width
//-----------------------------------------------------------------------------

module stage3_gradient_fusion #(
    parameter DATA_WIDTH      = 10,                      // Pixel data width
    parameter GRAD_WIDTH      = 14,                      // Gradient width
    parameter PIC_WIDTH_BITS  = 14,                      // log2(MAX_WIDTH) + 1
    parameter PIC_HEIGHT_BITS = 13                       // log2(MAX_HEIGHT) + 1
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // Stage 2 outputs
    input  wire [DATA_WIDTH-1:0]       avg0_c, avg0_u, avg0_d, avg0_l, avg0_r,
    input  wire [DATA_WIDTH-1:0]       avg1_c, avg1_u, avg1_d, avg1_l, avg1_r,
    input  wire                        stage2_valid,

    // Gradients from Stage 1 (delayed to match stage2 timing)
    input  wire [GRAD_WIDTH-1:0]       grad,
    input  wire [GRAD_WIDTH-1:0]       grad_h, grad_v,

    // Position info for boundary handling (delayed to match stage2 timing)
    input  wire [PIC_WIDTH_BITS-1:0]   pixel_x,
    input  wire [PIC_HEIGHT_BITS-1:0]  pixel_y,
    input  wire [PIC_WIDTH_BITS-1:0]   pic_width_m1,
    input  wire [PIC_HEIGHT_BITS-1:0]  pic_height_m1,

    // Instantaneous signals for line buffer write (not delayed)
    input  wire [GRAD_WIDTH-1:0]       grad_instant,
    input  wire [PIC_WIDTH_BITS-1:0]   pixel_x_instant,
    input  wire [PIC_HEIGHT_BITS-1:0]  pixel_y_instant,
    input  wire                        stage1_valid,

    // Center pixel and win_size for Stage 4 (to be pipelined)
    input  wire [DATA_WIDTH-1:0]       center_pixel_in,
    input  wire [5:0]                  win_size_clip_in,

    // Outputs
    output reg  [DATA_WIDTH-1:0]       blend0_dir_avg,
    output reg  [DATA_WIDTH-1:0]       blend1_dir_avg,
    output reg                         stage3_valid,

    // Position outputs (pipelined to align with outputs)
    output reg  [PIC_WIDTH_BITS-1:0]   pixel_x_out,
    output reg  [PIC_HEIGHT_BITS-1:0]  pixel_y_out,

    // avg0_u and avg1_u outputs (pipelined for Stage 4 IIR)
    output reg  [DATA_WIDTH-1:0]       avg0_u_out,
    output reg  [DATA_WIDTH-1:0]       avg1_u_out,
    // Center pixel and win_size outputs (pipelined for Stage 4)
    output reg  [DATA_WIDTH-1:0]       center_pixel_out,
    output reg  [5:0]                  win_size_clip_out
);

    `include "isp_csiir_defines.vh"

    //=========================================================================
    // STAGE 1: Buffer Inputs and Compute Directional Gradients (Pipe)
    //=========================================================================

    // Pipeline registers for inputs
    reg [DATA_WIDTH-1:0] avg0_c_s1, avg0_u_s1, avg0_d_s1, avg0_l_s1, avg0_r_s1;
    reg [DATA_WIDTH-1:0] avg1_c_s1, avg1_u_s1, avg1_d_s1, avg1_l_s1, avg1_r_s1;
    reg [GRAD_WIDTH-1:0] grad_c_s1, grad_u_s1, grad_d_s1, grad_l_s1, grad_r_s1;
    reg                  valid_s1;
    // Position pipeline
    reg [PIC_WIDTH_BITS-1:0]  pixel_x_s1;
    reg [PIC_HEIGHT_BITS-1:0] pixel_y_s1;
    // Center pixel and win_size pipeline
    reg [DATA_WIDTH-1:0] center_pixel_s1;
    reg [5:0]            win_size_clip_s1;

    // Line buffer for storing previous row's gradient
    // This allows us to get grad_u (gradient from row above)
    reg [GRAD_WIDTH-1:0] grad_line_buf [0:4095];  // Support up to 4K width
    integer i;

    // Column buffer for left neighbor gradient
    reg [GRAD_WIDTH-1:0] grad_left_buf;

    // Boundary detection signals
    // NOTE: pixel_y is the window center position, which starts at 2 for valid outputs
    // (not 0 as in image coordinates). So "top row" in output context is pixel_y == 2.
    wire is_top_row    = (pixel_y <= 2);  // First output row has no valid grad_u
    wire is_bottom_row = (pixel_y == pic_height_m1);
    // For left column: pixel_x=3 means left neighbor is at x=2 which is valid
    // So is_left_col should only be true for pixel_x < 3 (but outputs start at 3)
    wire is_left_col   = (pixel_x < 3);  // Only true if no valid left neighbor
    wire is_right_col  = (pixel_x == pic_width_m1);

    // Get directional gradients with boundary handling
    // Python model: grad_u = grad_line_buf[pixel_x] (returns 0 if empty)
    // RTL: match Python - just read from buffer (which is 0 if not written yet)
    wire [GRAD_WIDTH-1:0] grad_u_comb = is_top_row ? grad : grad_line_buf[pixel_x];

    // For grad_l, we need the previous pixel's gradient (pixel_x - 1).
    // The grad_left_buf is updated when stage1_valid fires (5 cycles before stage2_valid).
    // We need a 5-stage delay chain (matching grad_delay in top module) to get the correct previous gradient.
    reg [GRAD_WIDTH-1:0] grad_left_delayed [0:4];
    wire [GRAD_WIDTH-1:0] grad_l_comb = is_left_col ? grad : grad_left_delayed[4];

    // For grad_d and grad_r, we approximate with current (would need future pixel data)
    wire [GRAD_WIDTH-1:0] grad_d_comb = is_bottom_row ? grad : grad;
    wire [GRAD_WIDTH-1:0] grad_r_comb = is_right_col  ? grad : grad;

    // Delay chain for grad_left to align with stage2_valid
    // IMPORTANT: Shift every cycle to allow valid data to propagate through
    integer m;  // Loop variable
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (m = 0; m < 5; m = m + 1) begin
                grad_left_delayed[m] <= {GRAD_WIDTH{1'b0}};
            end
        end else if (enable) begin
            // Shift every cycle, input new data when stage1_valid fires
            grad_left_delayed[0] <= stage1_valid ? grad_left_buf : {GRAD_WIDTH{1'b0}};
            grad_left_delayed[1] <= grad_left_delayed[0];
            grad_left_delayed[2] <= grad_left_delayed[1];
            grad_left_delayed[3] <= grad_left_delayed[2];
            grad_left_delayed[4] <= grad_left_delayed[3];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            avg0_c_s1 <= {DATA_WIDTH{1'b0}};
            avg0_u_s1 <= {DATA_WIDTH{1'b0}};
            avg0_d_s1 <= {DATA_WIDTH{1'b0}};
            avg0_l_s1 <= {DATA_WIDTH{1'b0}};
            avg0_r_s1 <= {DATA_WIDTH{1'b0}};
            avg1_c_s1 <= {DATA_WIDTH{1'b0}};
            avg1_u_s1 <= {DATA_WIDTH{1'b0}};
            avg1_d_s1 <= {DATA_WIDTH{1'b0}};
            avg1_l_s1 <= {DATA_WIDTH{1'b0}};
            avg1_r_s1 <= {DATA_WIDTH{1'b0}};
            grad_c_s1 <= {GRAD_WIDTH{1'b0}};
            grad_u_s1 <= {GRAD_WIDTH{1'b0}};
            grad_d_s1 <= {GRAD_WIDTH{1'b0}};
            grad_l_s1 <= {GRAD_WIDTH{1'b0}};
            grad_r_s1 <= {GRAD_WIDTH{1'b0}};
            valid_s1  <= 1'b0;
            pixel_x_s1 <= {PIC_WIDTH_BITS{1'b0}};
            pixel_y_s1 <= {PIC_HEIGHT_BITS{1'b0}};
            center_pixel_s1 <= {DATA_WIDTH{1'b0}};
            win_size_clip_s1 <= 6'd0;
        end else if (enable && stage2_valid) begin
            // Pass through averages
            avg0_c_s1 <= avg0_c;
            avg0_u_s1 <= avg0_u;
            avg0_d_s1 <= avg0_d;
            avg0_l_s1 <= avg0_l;
            avg0_r_s1 <= avg0_r;
            avg1_c_s1 <= avg1_c;
            avg1_u_s1 <= avg1_u;
            avg1_d_s1 <= avg1_d;
            avg1_l_s1 <= avg1_l;
            avg1_r_s1 <= avg1_r;

            // Center gradient
            grad_c_s1 <= grad;

            // Directional gradients with boundary handling
            grad_u_s1 <= grad_u_comb;
            grad_d_s1 <= grad_d_comb;
            grad_l_s1 <= grad_l_comb;
            grad_r_s1 <= grad_r_comb;

            // Pipeline position
            pixel_x_s1 <= pixel_x;
            pixel_y_s1 <= pixel_y;

            // Pipeline center pixel and win_size
            center_pixel_s1 <= center_pixel_in;
            win_size_clip_s1 <= win_size_clip_in;

            valid_s1 <= 1'b1;
        end else begin
            valid_s1 <= 1'b0;
        end
    end

    //=========================================================================
    // Line Buffer Write (happens when stage1_valid fires from top module)
    // grad_left_buf: Updated every pixel to hold the previous pixel's gradient
    // grad_line_buf: Updated at row transition to make previous row available
    //=========================================================================
    reg [PIC_HEIGHT_BITS-1:0] last_pixel_y_instant;  // Track previous row for boundary detection
    reg [GRAD_WIDTH-1:0] grad_shadow_buf [0:4095];  // Shadow buffer for current row

    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            grad_left_buf <= {GRAD_WIDTH{1'b0}};
            last_pixel_y_instant <= {PIC_HEIGHT_BITS{1'b0}};
            for (i = 0; i < 4096; i = i + 1) begin
                grad_line_buf[i] <= {GRAD_WIDTH{1'b0}};
                grad_shadow_buf[i] <= {GRAD_WIDTH{1'b0}};
            end
        end else if (enable && stage1_valid) begin
            // Update grad_left_buf every pixel to hold previous pixel's gradient
            // This is used for grad_l in the next pixel
            grad_left_buf <= grad_instant;

            // Write current gradient to shadow buffer for row storage
            grad_shadow_buf[pixel_x_instant] <= grad_instant;

            // Detect row transition in the instant position
            // When pixel_y_instant changes, copy shadow to main buffer
            if (pixel_y_instant != last_pixel_y_instant) begin
                // New row started - copy shadow buffer to line buffer
                for (j = 0; j < 4096; j = j + 1) begin
                    grad_line_buf[j] <= grad_shadow_buf[j];
                end
            end

            last_pixel_y_instant <= pixel_y_instant;
        end
    end

    //=========================================================================
    // STAGE 2: Sort Gradients (Combinational + Pipeline)
    //=========================================================================

    // Combinational: Sort 5 gradients using sorting network
    // Using bubble-sort style network with 7 compare stages
    wire [GRAD_WIDTH-1:0] s0 = grad_c_s1;
    wire [GRAD_WIDTH-1:0] s1 = grad_u_s1;
    wire [GRAD_WIDTH-1:0] s2 = grad_d_s1;
    wire [GRAD_WIDTH-1:0] s3 = grad_l_s1;
    wire [GRAD_WIDTH-1:0] s4 = grad_r_s1;

    // Pass 1: Compare adjacent pairs (indices 0-1, 2-3)
    wire [GRAD_WIDTH-1:0] p1_0 = (s0 < s1) ? s0 : s1;
    wire [GRAD_WIDTH-1:0] p1_1 = (s0 < s1) ? s1 : s0;
    wire [GRAD_WIDTH-1:0] p1_2 = (s2 < s3) ? s2 : s3;
    wire [GRAD_WIDTH-1:0] p1_3 = (s2 < s3) ? s3 : s2;
    wire [GRAD_WIDTH-1:0] p1_4 = s4;

    // Pass 2: Compare adjacent (indices 1-2, 3-4)
    wire [GRAD_WIDTH-1:0] p2_0 = p1_0;
    wire [GRAD_WIDTH-1:0] p2_1 = (p1_1 < p1_2) ? p1_1 : p1_2;
    wire [GRAD_WIDTH-1:0] p2_2 = (p1_1 < p1_2) ? p1_2 : p1_1;
    wire [GRAD_WIDTH-1:0] p2_3 = (p1_3 < p1_4) ? p1_3 : p1_4;
    wire [GRAD_WIDTH-1:0] p2_4 = (p1_3 < p1_4) ? p1_4 : p1_3;

    // Pass 3: Compare adjacent (indices 0-1, 2-3)
    wire [GRAD_WIDTH-1:0] p3_0 = (p2_0 < p2_1) ? p2_0 : p2_1;
    wire [GRAD_WIDTH-1:0] p3_1 = (p2_0 < p2_1) ? p2_1 : p2_0;
    wire [GRAD_WIDTH-1:0] p3_2 = (p2_2 < p2_3) ? p2_2 : p2_3;
    wire [GRAD_WIDTH-1:0] p3_3 = (p2_2 < p2_3) ? p2_3 : p2_2;
    wire [GRAD_WIDTH-1:0] p3_4 = p2_4;

    // Pass 4: Compare adjacent (indices 1-2, 3-4)
    wire [GRAD_WIDTH-1:0] p4_0 = p3_0;
    wire [GRAD_WIDTH-1:0] p4_1 = (p3_1 < p3_2) ? p3_1 : p3_2;
    wire [GRAD_WIDTH-1:0] p4_2 = (p3_1 < p3_2) ? p3_2 : p3_1;
    wire [GRAD_WIDTH-1:0] p4_3 = (p3_3 < p3_4) ? p3_3 : p3_4;
    wire [GRAD_WIDTH-1:0] p4_4 = (p3_3 < p3_4) ? p3_4 : p3_3;

    // Pass 5: Compare adjacent (indices 0-1, 2-3)
    wire [GRAD_WIDTH-1:0] p5_0 = (p4_0 < p4_1) ? p4_0 : p4_1;
    wire [GRAD_WIDTH-1:0] p5_1 = (p4_0 < p4_1) ? p4_1 : p4_0;
    wire [GRAD_WIDTH-1:0] p5_2 = (p4_2 < p4_3) ? p4_2 : p4_3;
    wire [GRAD_WIDTH-1:0] p5_3 = (p4_2 < p4_3) ? p4_3 : p4_2;
    wire [GRAD_WIDTH-1:0] p5_4 = p4_4;

    // Pass 6: Compare adjacent (indices 1-2, 3-4)
    wire [GRAD_WIDTH-1:0] p6_0 = p5_0;
    wire [GRAD_WIDTH-1:0] p6_1 = (p5_1 < p5_2) ? p5_1 : p5_2;
    wire [GRAD_WIDTH-1:0] p6_2 = (p5_1 < p5_2) ? p5_2 : p5_1;
    wire [GRAD_WIDTH-1:0] p6_3 = (p5_3 < p5_4) ? p5_3 : p5_4;
    wire [GRAD_WIDTH-1:0] p6_4 = (p5_3 < p5_4) ? p5_4 : p5_3;

    // Pass 7: Compare adjacent (indices 2-3)
    wire [GRAD_WIDTH-1:0] grad_s0_comb = p6_0;
    wire [GRAD_WIDTH-1:0] grad_s1_comb = p6_1;
    wire [GRAD_WIDTH-1:0] grad_s2_comb = (p6_2 < p6_3) ? p6_2 : p6_3;
    wire [GRAD_WIDTH-1:0] grad_s3_comb = (p6_2 < p6_3) ? p6_3 : p6_2;
    wire [GRAD_WIDTH-1:0] grad_s4_comb = p6_4;

    // Pipeline Stage 2: Register sorted results
    reg [DATA_WIDTH-1:0] avg0_c_s2, avg0_u_s2, avg0_d_s2, avg0_l_s2, avg0_r_s2;
    reg [DATA_WIDTH-1:0] avg1_c_s2, avg1_u_s2, avg1_d_s2, avg1_l_s2, avg1_r_s2;
    reg [GRAD_WIDTH-1:0] grad_s0_s2, grad_s1_s2, grad_s2_s2, grad_s3_s2, grad_s4_s2;
    reg                  valid_s2;
    // Position pipeline
    reg [PIC_WIDTH_BITS-1:0]  pixel_x_s2;
    reg [PIC_HEIGHT_BITS-1:0] pixel_y_s2;
    // Center pixel and win_size pipeline
    reg [DATA_WIDTH-1:0] center_pixel_s2;
    reg [5:0]            win_size_clip_s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            avg0_c_s2 <= {DATA_WIDTH{1'b0}};
            avg0_u_s2 <= {DATA_WIDTH{1'b0}};
            avg0_d_s2 <= {DATA_WIDTH{1'b0}};
            avg0_l_s2 <= {DATA_WIDTH{1'b0}};
            avg0_r_s2 <= {DATA_WIDTH{1'b0}};
            avg1_c_s2 <= {DATA_WIDTH{1'b0}};
            avg1_u_s2 <= {DATA_WIDTH{1'b0}};
            avg1_d_s2 <= {DATA_WIDTH{1'b0}};
            avg1_l_s2 <= {DATA_WIDTH{1'b0}};
            avg1_r_s2 <= {DATA_WIDTH{1'b0}};
            grad_s0_s2 <= {GRAD_WIDTH{1'b0}};
            grad_s1_s2 <= {GRAD_WIDTH{1'b0}};
            grad_s2_s2 <= {GRAD_WIDTH{1'b0}};
            grad_s3_s2 <= {GRAD_WIDTH{1'b0}};
            grad_s4_s2 <= {GRAD_WIDTH{1'b0}};
            valid_s2 <= 1'b0;
            pixel_x_s2 <= {PIC_WIDTH_BITS{1'b0}};
            pixel_y_s2 <= {PIC_HEIGHT_BITS{1'b0}};
            center_pixel_s2 <= {DATA_WIDTH{1'b0}};
            win_size_clip_s2 <= 6'd0;
        end else if (enable && valid_s1) begin
            // Pass through averages
            avg0_c_s2 <= avg0_c_s1;
            avg0_u_s2 <= avg0_u_s1;
            avg0_d_s2 <= avg0_d_s1;
            avg0_l_s2 <= avg0_l_s1;
            avg0_r_s2 <= avg0_r_s1;
            avg1_c_s2 <= avg1_c_s1;
            avg1_u_s2 <= avg1_u_s1;
            avg1_d_s2 <= avg1_d_s1;
            avg1_l_s2 <= avg1_l_s1;
            avg1_r_s2 <= avg1_r_s1;

            // Store sorted gradients
            grad_s0_s2 <= grad_s0_comb;
            grad_s1_s2 <= grad_s1_comb;
            grad_s2_s2 <= grad_s2_comb;
            grad_s3_s2 <= grad_s3_comb;
            grad_s4_s2 <= grad_s4_comb;

            // Pipeline position
            pixel_x_s2 <= pixel_x_s1;
            pixel_y_s2 <= pixel_y_s1;

            // Pipeline center pixel and win_size
            center_pixel_s2 <= center_pixel_s1;
            win_size_clip_s2 <= win_size_clip_s1;

            valid_s2 <= 1'b1;
        end else begin
            valid_s2 <= 1'b0;
        end
    end

    //=========================================================================
    // STAGE 3: Compute Weighted Sums (Combinational + Pipeline)
    //=========================================================================

    // Combinational: Compute gradient sum using adder tree
    wire [GRAD_WIDTH+2:0] grad_sum_comb = grad_s0_s2 + grad_s1_s2 + grad_s2_s2 + grad_s3_s2 + grad_s4_s2;

    // Combinational: Compute weighted sums using multiply-accumulate tree
    // For timing, split into partial sums
    wire [DATA_WIDTH+GRAD_WIDTH:0] blend0_partial0 = avg0_c_s2 * grad_s0_s2;
    wire [DATA_WIDTH+GRAD_WIDTH:0] blend0_partial1 = avg0_u_s2 * grad_s1_s2;
    wire [DATA_WIDTH+GRAD_WIDTH:0] blend0_partial2 = avg0_d_s2 * grad_s2_s2;
    wire [DATA_WIDTH+GRAD_WIDTH:0] blend0_partial3 = avg0_l_s2 * grad_s3_s2;
    wire [DATA_WIDTH+GRAD_WIDTH:0] blend0_partial4 = avg0_r_s2 * grad_s4_s2;

    wire [DATA_WIDTH+GRAD_WIDTH+1:0] blend0_sum0 = blend0_partial0 + blend0_partial1;
    wire [DATA_WIDTH+GRAD_WIDTH+1:0] blend0_sum1 = blend0_partial2 + blend0_partial3;
    wire [DATA_WIDTH+GRAD_WIDTH+2:0] blend0_sum_comb = blend0_sum0 + blend0_sum1 + blend0_partial4;

    wire [DATA_WIDTH+GRAD_WIDTH:0] blend1_partial0 = avg1_c_s2 * grad_s0_s2;
    wire [DATA_WIDTH+GRAD_WIDTH:0] blend1_partial1 = avg1_u_s2 * grad_s1_s2;
    wire [DATA_WIDTH+GRAD_WIDTH:0] blend1_partial2 = avg1_d_s2 * grad_s2_s2;
    wire [DATA_WIDTH+GRAD_WIDTH:0] blend1_partial3 = avg1_l_s2 * grad_s3_s2;
    wire [DATA_WIDTH+GRAD_WIDTH:0] blend1_partial4 = avg1_r_s2 * grad_s4_s2;

    wire [DATA_WIDTH+GRAD_WIDTH+1:0] blend1_sum0 = blend1_partial0 + blend1_partial1;
    wire [DATA_WIDTH+GRAD_WIDTH+1:0] blend1_sum1 = blend1_partial2 + blend1_partial3;
    wire [DATA_WIDTH+GRAD_WIDTH+2:0] blend1_sum_comb = blend1_sum0 + blend1_sum1 + blend1_partial4;

    // Pipeline Stage 3: Register weighted sums
    reg [DATA_WIDTH+GRAD_WIDTH+2:0] blend0_sum_s3;
    reg [DATA_WIDTH+GRAD_WIDTH+2:0] blend1_sum_s3;
    reg [GRAD_WIDTH+2:0]            grad_sum_s3;
    reg                             valid_s3;
    // Also pipeline avg values for zero-gradient case
    reg [DATA_WIDTH-1:0] avg0_c_s3, avg0_u_s3, avg0_d_s3, avg0_l_s3, avg0_r_s3;
    reg [DATA_WIDTH-1:0] avg1_c_s3, avg1_u_s3, avg1_d_s3, avg1_l_s3, avg1_r_s3;
    // Position pipeline
    reg [PIC_WIDTH_BITS-1:0]  pixel_x_s3;
    reg [PIC_HEIGHT_BITS-1:0] pixel_y_s3;
    // Center pixel and win_size pipeline
    reg [DATA_WIDTH-1:0] center_pixel_s3;
    reg [5:0]            win_size_clip_s3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blend0_sum_s3 <= {(DATA_WIDTH+GRAD_WIDTH+3){1'b0}};
            blend1_sum_s3 <= {(DATA_WIDTH+GRAD_WIDTH+3){1'b0}};
            grad_sum_s3   <= {(GRAD_WIDTH+3){1'b0}};
            valid_s3      <= 1'b0;
            avg0_c_s3 <= {DATA_WIDTH{1'b0}};
            avg0_u_s3 <= {DATA_WIDTH{1'b0}};
            avg0_d_s3 <= {DATA_WIDTH{1'b0}};
            avg0_l_s3 <= {DATA_WIDTH{1'b0}};
            avg0_r_s3 <= {DATA_WIDTH{1'b0}};
            avg1_c_s3 <= {DATA_WIDTH{1'b0}};
            avg1_u_s3 <= {DATA_WIDTH{1'b0}};
            avg1_d_s3 <= {DATA_WIDTH{1'b0}};
            avg1_l_s3 <= {DATA_WIDTH{1'b0}};
            avg1_r_s3 <= {DATA_WIDTH{1'b0}};
            pixel_x_s3 <= {PIC_WIDTH_BITS{1'b0}};
            pixel_y_s3 <= {PIC_HEIGHT_BITS{1'b0}};
            center_pixel_s3 <= {DATA_WIDTH{1'b0}};
            win_size_clip_s3 <= 6'd0;
        end else if (enable && valid_s2) begin
            blend0_sum_s3 <= blend0_sum_comb;
            blend1_sum_s3 <= blend1_sum_comb;
            grad_sum_s3   <= grad_sum_comb;
            // Also pipeline avg values
            avg0_c_s3 <= avg0_c_s2;
            avg0_u_s3 <= avg0_u_s2;
            avg0_d_s3 <= avg0_d_s2;
            avg0_l_s3 <= avg0_l_s2;
            avg0_r_s3 <= avg0_r_s2;
            avg1_c_s3 <= avg1_c_s2;
            avg1_u_s3 <= avg1_u_s2;
            avg1_d_s3 <= avg1_d_s2;
            avg1_l_s3 <= avg1_l_s2;
            avg1_r_s3 <= avg1_r_s2;
            pixel_x_s3 <= pixel_x_s2;
            pixel_y_s3 <= pixel_y_s2;
            center_pixel_s3 <= center_pixel_s2;
            win_size_clip_s3 <= win_size_clip_s2;
            valid_s3      <= 1'b1;
        end else begin
            valid_s3 <= 1'b0;
        end
    end

    //=========================================================================
    // STAGE 4: Division and Output (Combinational + Pipeline)
    //=========================================================================

    // Combinational: Compute simple average for zero gradient case
    // Use s3 registers (not s2) to match pipeline timing
    wire [DATA_WIDTH+2:0] avg0_sum_comb = avg0_c_s3 + avg0_u_s3 + avg0_d_s3 + avg0_l_s3 + avg0_r_s3;
    wire [DATA_WIDTH+2:0] avg1_sum_comb = avg1_c_s3 + avg1_u_s3 + avg1_d_s3 + avg1_l_s3 + avg1_r_s3;

    // Combinational: Division by grad_sum
    // Use integer division: blend = blend_sum / grad_sum
    // Note: grad_sum can be up to 5 * 16383 = 81915 (17 bits)
    wire [DATA_WIDTH-1:0] blend0_div = (grad_sum_s3 != 0) ?
        (blend0_sum_s3 / grad_sum_s3) : {DATA_WIDTH{1'b0}};
    wire [DATA_WIDTH-1:0] blend1_div = (grad_sum_s3 != 0) ?
        (blend1_sum_s3 / grad_sum_s3) : {DATA_WIDTH{1'b0}};

    // Combinational: Select output based on gradient sum
    wire [DATA_WIDTH-1:0] blend0_comb = (grad_sum_s3 == 0) ? (avg0_sum_comb / 5) : blend0_div;
    wire [DATA_WIDTH-1:0] blend1_comb = (grad_sum_s3 == 0) ? (avg1_sum_comb / 5) : blend1_div;

    // Pipeline Stage 4: Register outputs
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blend0_dir_avg <= {DATA_WIDTH{1'b0}};
            blend1_dir_avg <= {DATA_WIDTH{1'b0}};
            stage3_valid   <= 1'b0;
            pixel_x_out    <= {PIC_WIDTH_BITS{1'b0}};
            pixel_y_out    <= {PIC_HEIGHT_BITS{1'b0}};
            avg0_u_out     <= {DATA_WIDTH{1'b0}};
            avg1_u_out     <= {DATA_WIDTH{1'b0}};
            center_pixel_out <= {DATA_WIDTH{1'b0}};
            win_size_clip_out <= 6'd0;
        end else if (enable && valid_s3) begin
            blend0_dir_avg <= blend0_comb;
            blend1_dir_avg <= blend1_comb;
            stage3_valid   <= 1'b1;
            pixel_x_out    <= pixel_x_s3;
            pixel_y_out    <= pixel_y_s3;
            avg0_u_out     <= avg0_u_s3;
            avg1_u_out     <= avg1_u_s3;
            center_pixel_out <= center_pixel_s3;
            win_size_clip_out <= win_size_clip_s3;
        end else begin
            stage3_valid <= 1'b0;
        end
    end

endmodule