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

    // Gradients from Stage 1
    input  wire [GRAD_WIDTH-1:0]       grad,
    input  wire [GRAD_WIDTH-1:0]       grad_h, grad_v,

    // Position info for boundary handling (parameterized width)
    input  wire [PIC_WIDTH_BITS-1:0]   pixel_x,
    input  wire [PIC_HEIGHT_BITS-1:0]  pixel_y,
    input  wire [PIC_WIDTH_BITS-1:0]   pic_width_m1,
    input  wire [PIC_HEIGHT_BITS-1:0]  pic_height_m1,

    // Outputs
    output reg  [DATA_WIDTH-1:0]       blend0_dir_avg,
    output reg  [DATA_WIDTH-1:0]       blend1_dir_avg,
    output reg                         stage3_valid
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

    // Line buffer for storing previous row's gradient
    // This allows us to get grad_u (gradient from row above)
    reg [GRAD_WIDTH-1:0] grad_line_buf [0:4095];  // Support up to 4K width
    integer i;

    // Column buffer for left neighbor gradient
    reg [GRAD_WIDTH-1:0] grad_left_buf;

    // Boundary detection signals
    wire is_top_row    = (pixel_y == 0);
    wire is_bottom_row = (pixel_y == pic_height_m1);
    wire is_left_col   = (pixel_x == 0);
    wire is_right_col  = (pixel_x == pic_width_m1);

    // Get directional gradients with boundary handling
    wire [GRAD_WIDTH-1:0] grad_u_comb = is_top_row    ? grad : grad_line_buf[pixel_x];
    wire [GRAD_WIDTH-1:0] grad_l_comb = is_left_col   ? grad : grad_left_buf;
    // For grad_d and grad_r, we approximate with current (would need future pixel data)
    wire [GRAD_WIDTH-1:0] grad_d_comb = is_bottom_row ? grad : grad;  // Simplified
    wire [GRAD_WIDTH-1:0] grad_r_comb = is_right_col  ? grad : grad;  // Simplified

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
            grad_left_buf <= {GRAD_WIDTH{1'b0}};
            valid_s1  <= 1'b0;
            // Initialize line buffer
            for (i = 0; i < 4096; i = i + 1) begin
                grad_line_buf[i] <= {GRAD_WIDTH{1'b0}};
            end
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

            // Update line buffer at end of row (for next row's grad_u)
            // Store current gradient for future use
            grad_line_buf[pixel_x] <= grad;
            grad_left_buf <= grad;  // Store for next column's grad_l

            valid_s1 <= 1'b1;
        end else begin
            valid_s1 <= 1'b0;
        end
    end

    //=========================================================================
    // STAGE 2: Sort Gradients (Combinational + Pipeline)
    //=========================================================================

    // Combinational: Sort 5 gradients using sorting network
    // Using balanced comparison tree for timing optimization
    wire [GRAD_WIDTH-1:0] sort_in_0 = grad_c_s1;
    wire [GRAD_WIDTH-1:0] sort_in_1 = grad_u_s1;
    wire [GRAD_WIDTH-1:0] sort_in_2 = grad_d_s1;
    wire [GRAD_WIDTH-1:0] sort_in_3 = grad_l_s1;
    wire [GRAD_WIDTH-1:0] sort_in_4 = grad_r_s1;

    // Sorting network (bitonic sort for 5 elements, ascending order)
    // Level 1: Compare adjacent pairs
    wire [GRAD_WIDTH-1:0] l1_0 = (sort_in_0 < sort_in_1) ? sort_in_0 : sort_in_1;
    wire [GRAD_WIDTH-1:0] l1_1 = (sort_in_0 < sort_in_1) ? sort_in_1 : sort_in_0;
    wire [GRAD_WIDTH-1:0] l1_2 = (sort_in_2 < sort_in_3) ? sort_in_2 : sort_in_3;
    wire [GRAD_WIDTH-1:0] l1_3 = (sort_in_2 < sort_in_3) ? sort_in_3 : sort_in_2;

    // Level 2: Merge pairs
    wire [GRAD_WIDTH-1:0] l2_0 = (l1_0 < l1_2) ? l1_0 : l1_2;
    wire [GRAD_WIDTH-1:0] l2_2 = (l1_0 < l1_2) ? l1_2 : l1_0;
    wire [GRAD_WIDTH-1:0] l2_1 = (l1_1 < l1_3) ? l1_1 : l1_3;
    wire [GRAD_WIDTH-1:0] l2_3 = (l1_1 < l1_3) ? l1_3 : l1_1;

    // Level 3: Insert sort_in_4 and finalize
    wire [GRAD_WIDTH-1:0] l3_0 = (l2_0 < sort_in_4) ? l2_0 : sort_in_4;
    wire [GRAD_WIDTH-1:0] l3_1 = (l2_0 < sort_in_4) ? sort_in_4 : l2_0;
    wire [GRAD_WIDTH-1:0] l3_2 = (l2_1 < l3_1) ? l2_1 : l3_1;
    wire [GRAD_WIDTH-1:0] l3_3 = (l2_1 < l3_1) ? l3_1 : l2_1;

    // Final sorted outputs (ascending: s0=min, s4=max)
    wire [GRAD_WIDTH-1:0] grad_s0_comb = l3_0;
    wire [GRAD_WIDTH-1:0] grad_s1_comb = (l3_2 < l3_3) ? l3_2 : l3_3;
    wire [GRAD_WIDTH-1:0] grad_s2_comb = (l3_2 < l3_3) ? l3_3 : l3_2;
    wire [GRAD_WIDTH-1:0] grad_s3_comb = (l2_2 < l2_3) ? l2_2 : l2_3;
    wire [GRAD_WIDTH-1:0] grad_s4_comb = (l2_2 < l2_3) ? l2_3 : l2_2;

    // Pipeline Stage 2: Register sorted results
    reg [DATA_WIDTH-1:0] avg0_c_s2, avg0_u_s2, avg0_d_s2, avg0_l_s2, avg0_r_s2;
    reg [DATA_WIDTH-1:0] avg1_c_s2, avg1_u_s2, avg1_d_s2, avg1_l_s2, avg1_r_s2;
    reg [GRAD_WIDTH-1:0] grad_s0_s2, grad_s1_s2, grad_s2_s2, grad_s3_s2, grad_s4_s2;
    reg                  valid_s2;

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

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blend0_sum_s3 <= {(DATA_WIDTH+GRAD_WIDTH+3){1'b0}};
            blend1_sum_s3 <= {(DATA_WIDTH+GRAD_WIDTH+3){1'b0}};
            grad_sum_s3   <= {(GRAD_WIDTH+3){1'b0}};
            valid_s3      <= 1'b0;
        end else if (enable && valid_s2) begin
            blend0_sum_s3 <= blend0_sum_comb;
            blend1_sum_s3 <= blend1_sum_comb;
            grad_sum_s3   <= grad_sum_comb;
            valid_s3      <= 1'b1;
        end else begin
            valid_s3 <= 1'b0;
        end
    end

    //=========================================================================
    // STAGE 4: Division and Output (Combinational + Pipeline)
    //=========================================================================

    // Combinational: Compute simple average for zero gradient case
    wire [DATA_WIDTH+2:0] avg0_sum_comb = avg0_c_s2 + avg0_u_s2 + avg0_d_s2 + avg0_l_s2 + avg0_r_s2;
    wire [DATA_WIDTH+2:0] avg1_sum_comb = avg1_c_s2 + avg1_u_s2 + avg1_d_s2 + avg1_l_s2 + avg1_r_s2;

    // Combinational: Division (simplified using right shift for approximation)
    // For accurate division, a separate divider module would be needed
    wire [DATA_WIDTH-1:0] blend0_div = blend0_sum_s3[DATA_WIDTH+GRAD_WIDTH+2:GRAD_WIDTH+2];
    wire [DATA_WIDTH-1:0] blend1_div = blend1_sum_s3[DATA_WIDTH+GRAD_WIDTH+2:GRAD_WIDTH+2];

    // Combinational: Select output based on gradient sum
    wire [DATA_WIDTH-1:0] blend0_comb = (grad_sum_s3 == 0) ? (avg0_sum_comb / 5) : blend0_div;
    wire [DATA_WIDTH-1:0] blend1_comb = (grad_sum_s3 == 0) ? (avg1_sum_comb / 5) : blend1_div;

    // Pipeline Stage 4: Register outputs
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blend0_dir_avg <= {DATA_WIDTH{1'b0}};
            blend1_dir_avg <= {DATA_WIDTH{1'b0}};
            stage3_valid   <= 1'b0;
        end else if (enable && valid_s3) begin
            blend0_dir_avg <= blend0_comb;
            blend1_dir_avg <= blend1_comb;
            stage3_valid   <= 1'b1;
        end else begin
            stage3_valid <= 1'b0;
        end
    end

endmodule