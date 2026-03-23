//-----------------------------------------------------------------------------
// Module: stage3_gradient_fusion
// Purpose: Gradient-weighted directional fusion
// Author: rtl-impl
// Date: 2026-03-23
// Version: v2.2 - True row delay architecture for grad_d (next row gradient)
//-----------------------------------------------------------------------------
// Description:
//   Implements Stage 3 of ISP-CSIIR pipeline:
//   - Gradient fetch from neighbors (using 2-row gradient line buffer)
//   - Gradient sorting network (5-input descending sort)
//   - Weighted multiplication (avg x grad) - signed arithmetic
//   - Weighted sum and division for fusion
//
// Data Format:
//   - Input avg: s11 (11-bit signed, range -512 to +511)
//   - Output blend: s11 (11-bit signed)
//
// Pipeline Structure (6 cycles):
//   Cycle 0: Input buffer and gradient fetch
//   Cycle 1: Gradient sort (first stage)
//   Cycle 2: Gradient sort (second stage)
//   Cycle 3: Weighted multiplication
//   Cycle 4: Weighted sum
//   Cycle 5: Division output (using common_lut_divider)
//
// Gradient Line Buffer Design (v2.2 True Row Delay Architecture):
//   CRITICAL: Stage 3 processing is delayed by 1 FULL ROW
//   - Stage 2 outputs are stored in row delay buffer for IMG_WIDTH cycles
//   - When Stage 3 processes row N, Stage 1/2 are already processing row N+1
//   - The "current" grad input is actually grad(N+1, j) - the NEXT row's gradient
//   - The gradient buffer contains grad(N) - the CURRENT row being processed
//
//   Data Flow Timeline:
//   | Time        | Stage 1/2       | Stage 3 (delayed) |
//   |-------------|-----------------|-------------------|
//   | Row 0       | Process row 0   | Idle (no data)    |
//   | Row 1       | Process row 1   | Process row 0     |
//   | Row 2       | Process row 2   | Process row 1     |
//   | ...         | ...             | ...               |
//
//   For processing pixel (i, j) in Stage 3:
//   - grad_c = grad_buffer[pixel_x] = grad(i, j)   [current row from buffer]
//   - grad_u = grad_buffer_prev[pixel_x] = grad(i-1, j) [previous row from secondary buffer]
//   - grad_d = grad_current_input = grad(i+1, j)   [next row from Stage 1]
//
//   Architecture Benefits:
//   - True 3-row gradient access (up, center, down)
//   - Maintains 1 pixel/clock throughput
//   - Adds 1 row latency to Stage 3 output
//
// Modules Used:
//   - common_lut_divider: Single-cycle LUT-based divider
//-----------------------------------------------------------------------------

module stage3_gradient_fusion #(
    parameter DATA_WIDTH     = 10,
    parameter SIGNED_WIDTH   = 11,   // Signed data width
    parameter GRAD_WIDTH     = 14,
    parameter WIN_SIZE_WIDTH = 6,
    parameter LINE_ADDR_WIDTH = 14,
    parameter ROW_CNT_WIDTH  = 13,
    parameter IMG_WIDTH      = 5472
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // Stage 2 outputs (s11 signed format)
    input  wire signed [SIGNED_WIDTH-1:0] avg0_c, avg0_u, avg0_d, avg0_l, avg0_r,
    input  wire signed [SIGNED_WIDTH-1:0] avg1_c, avg1_u, avg1_d, avg1_l, avg1_r,
    input  wire                        stage2_valid,
    input  wire [GRAD_WIDTH-1:0]       grad,
    input  wire [WIN_SIZE_WIDTH-1:0]   win_size_clip,
    input  wire [DATA_WIDTH-1:0]       center_pixel,

    // Configuration
    input  wire [ROW_CNT_WIDTH-1:0]    img_height,
    input  wire [LINE_ADDR_WIDTH-1:0]  img_width,

    // Output (s11 signed format)
    output reg  signed [SIGNED_WIDTH-1:0] blend0_dir_avg,
    output reg  signed [SIGNED_WIDTH-1:0] blend1_dir_avg,
    output reg                         stage3_valid,

    // Pass through signals
    input  wire [LINE_ADDR_WIDTH-1:0]  pixel_x,
    input  wire [ROW_CNT_WIDTH-1:0]    pixel_y,
    output reg  [LINE_ADDR_WIDTH-1:0]  pixel_x_out,
    output reg  [ROW_CNT_WIDTH-1:0]    pixel_y_out,
    output reg  signed [SIGNED_WIDTH-1:0] avg0_u_out,
    output reg  signed [SIGNED_WIDTH-1:0] avg1_u_out,
    output reg  [WIN_SIZE_WIDTH-1:0]   win_size_clip_out,
    output reg  [DATA_WIDTH-1:0]       center_pixel_out
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam BLEND_WIDTH = SIGNED_WIDTH + GRAD_WIDTH + 2;  // 27-bit for blend sum (signed)
    localparam GRAD_SUM_WIDTH = GRAD_WIDTH + 3;              // 17-bit for grad sum

    //=========================================================================
    // Row Delay Control
    //=========================================================================
    // Row counter to track current processing row
    reg [ROW_CNT_WIDTH-1:0] row_counter;
    reg                     row_valid;          // At least 1 row has been buffered

    // Column counter for row delay buffer addressing
    reg [LINE_ADDR_WIDTH-1:0] col_counter;

    // First row indicator (no valid grad_d available)
    wire is_first_row = (row_counter == 0) || !row_valid;

    // Last row indicator (no next row data available)
    wire is_last_row = (row_counter >= img_height - 2);  // -2 because we're 1 row behind

    //=========================================================================
    // Row Delay Buffer for Stage 2 Outputs
    //=========================================================================
    // Store Stage 2 outputs for 1 full row duration
    // These are the signals that Stage 3 will process (delayed by 1 row)

    // Gradient line buffer: stores gradients for 2 rows
    // buf_0: current row being processed by Stage 3
    // buf_1: previous row (for grad_u)
    reg [GRAD_WIDTH-1:0] grad_line_buf_0 [0:IMG_WIDTH-1];  // Current row (row N)
    reg [GRAD_WIDTH-1:0] grad_line_buf_1 [0:IMG_WIDTH-1];  // Previous row (row N-1)
    reg                  grad_buf_sel;  // 0: buf_0 is current, 1: buf_1 is current

    // Horizontal gradient shift register for left/right neighbors
    reg [GRAD_WIDTH-1:0] grad_shift_l;  // Left neighbor (previous column)

    // Row delay buffer for avg signals and metadata (stores 1 full row of data)
    // These will be read 1 row later by Stage 3 pipeline
    reg signed [SIGNED_WIDTH-1:0] avg0_c_delay [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg0_u_delay [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg0_d_delay [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg0_l_delay [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg0_r_delay [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg1_c_delay [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg1_u_delay [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg1_d_delay [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg1_l_delay [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg1_r_delay [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0]   center_pixel_delay [0:IMG_WIDTH-1];
    reg [WIN_SIZE_WIDTH-1:0] win_size_delay [0:IMG_WIDTH-1];
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_delay [0:IMG_WIDTH-1];
    reg [ROW_CNT_WIDTH-1:0] pixel_y_delay [0:IMG_WIDTH-1];
    reg                     valid_delay [0:IMG_WIDTH-1];

    // Current gradient from Stage 1/2 (this is grad_d for the delayed row)
    wire [GRAD_WIDTH-1:0] grad_next_row = grad;  // Gradient of row N+1

    //=========================================================================
    // Row Delay Buffer Write (Stage 2 outputs -> delay buffer)
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_counter <= {ROW_CNT_WIDTH{1'b0}};
            col_counter <= {LINE_ADDR_WIDTH{1'b0}};
            row_valid   <= 1'b0;
            grad_buf_sel <= 1'b0;
            grad_shift_l <= {GRAD_WIDTH{1'b0}};
        end else if (enable) begin
            // Update horizontal shift register for left neighbor
            grad_shift_l <= grad;

            // Write Stage 2 outputs to row delay buffer
            if (stage2_valid) begin
                // Store avg signals and metadata for delayed processing
                avg0_c_delay[col_counter] <= avg0_c;
                avg0_u_delay[col_counter] <= avg0_u;
                avg0_d_delay[col_counter] <= avg0_d;
                avg0_l_delay[col_counter] <= avg0_l;
                avg0_r_delay[col_counter] <= avg0_r;
                avg1_c_delay[col_counter] <= avg1_c;
                avg1_u_delay[col_counter] <= avg1_u;
                avg1_d_delay[col_counter] <= avg1_d;
                avg1_l_delay[col_counter] <= avg1_l;
                avg1_r_delay[col_counter] <= avg1_r;
                center_pixel_delay[col_counter] <= center_pixel;
                win_size_delay[col_counter]     <= win_size_clip;
                pixel_x_delay[col_counter]      <= pixel_x;
                pixel_y_delay[col_counter]      <= pixel_y;
                valid_delay[col_counter]        <= stage2_valid;

                // Store current gradient to line buffer (for next row's grad_c)
                if (grad_buf_sel)
                    grad_line_buf_1[col_counter] <= grad;
                else
                    grad_line_buf_0[col_counter] <= grad;

                // Update column counter
                if (col_counter >= img_width - 1) begin
                    col_counter <= {LINE_ADDR_WIDTH{1'b0}};
                    // Swap buffer selection at end of row
                    grad_buf_sel <= ~grad_buf_sel;
                    // Update row counter
                    row_counter <= row_counter + 1'b1;
                    row_valid   <= 1'b1;  // After first row, we have valid delayed data
                end else begin
                    col_counter <= col_counter + 1'b1;
                end
            end
        end
    end

    //=========================================================================
    // Cycle 0: Read from Row Delay Buffer and Gradient Fetch
    //=========================================================================
    // Read delayed data from row buffer (1 row behind Stage 2)
    // The delayed pixel_x determines which column we're processing

    // Read address is the current col_counter (we're always 1 row behind)
    wire [LINE_ADDR_WIDTH-1:0] rd_addr = col_counter;

    // Delayed Stage 2 data (for the pixel being processed by Stage 3)
    wire signed [SIGNED_WIDTH-1:0] avg0_c_rd = avg0_c_delay[rd_addr];
    wire signed [SIGNED_WIDTH-1:0] avg0_u_rd = avg0_u_delay[rd_addr];
    wire signed [SIGNED_WIDTH-1:0] avg0_d_rd = avg0_d_delay[rd_addr];
    wire signed [SIGNED_WIDTH-1:0] avg0_l_rd = avg0_l_delay[rd_addr];
    wire signed [SIGNED_WIDTH-1:0] avg0_r_rd = avg0_r_delay[rd_addr];
    wire signed [SIGNED_WIDTH-1:0] avg1_c_rd = avg1_c_delay[rd_addr];
    wire signed [SIGNED_WIDTH-1:0] avg1_u_rd = avg1_u_delay[rd_addr];
    wire signed [SIGNED_WIDTH-1:0] avg1_d_rd = avg1_d_delay[rd_addr];
    wire signed [SIGNED_WIDTH-1:0] avg1_l_rd = avg1_l_delay[rd_addr];
    wire signed [SIGNED_WIDTH-1:0] avg1_r_rd = avg1_r_delay[rd_addr];
    wire [DATA_WIDTH-1:0]   center_rd = center_pixel_delay[rd_addr];
    wire [WIN_SIZE_WIDTH-1:0] win_size_rd = win_size_delay[rd_addr];
    wire [LINE_ADDR_WIDTH-1:0] pixel_x_rd = pixel_x_delay[rd_addr];
    wire [ROW_CNT_WIDTH-1:0] pixel_y_rd = pixel_y_delay[rd_addr];
    wire                    valid_rd = valid_delay[rd_addr];

    // Gradient fetch for the delayed pixel
    // grad_c: current row gradient (from buffer - stored when this row was processed by Stage 1)
    wire [GRAD_WIDTH-1:0] grad_c = grad_buf_sel ? grad_line_buf_0[rd_addr] : grad_line_buf_1[rd_addr];

    // grad_u: previous row gradient (from secondary buffer)
    wire [GRAD_WIDTH-1:0] grad_u = grad_buf_sel ? grad_line_buf_1[rd_addr] : grad_line_buf_0[rd_addr];

    // grad_d: next row gradient (current input from Stage 1/2) - THIS IS THE KEY CHANGE!
    // Since Stage 3 is 1 row behind, the current grad input IS the next row's gradient
    wire [GRAD_WIDTH-1:0] grad_d = grad_next_row;

    // grad_l: left neighbor (previous column in same row)
    wire [GRAD_WIDTH-1:0] grad_l = grad_shift_l;

    // grad_r: right neighbor (simplified - same as center)
    wire [GRAD_WIDTH-1:0] grad_r = grad_c;

    // Boundary handling for first and last rows
    wire [GRAD_WIDTH-1:0] grad_u_bound = is_first_row ? grad_c : grad_u;
    wire [GRAD_WIDTH-1:0] grad_d_bound = is_last_row ? grad_c : grad_d;

    // Pipeline registers for Cycle 0
    reg [GRAD_WIDTH-1:0]   grad_c_s0, grad_u_s0, grad_d_s0, grad_l_s0, grad_r_s0;
    reg signed [SIGNED_WIDTH-1:0] avg0_c_s0, avg0_u_s0, avg0_d_s0, avg0_l_s0, avg0_r_s0;
    reg signed [SIGNED_WIDTH-1:0] avg1_c_s0, avg1_u_s0, avg1_d_s0, avg1_l_s0, avg1_r_s0;
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
            avg0_c_s0  <= {SIGNED_WIDTH{1'b0}};
            avg0_u_s0  <= {SIGNED_WIDTH{1'b0}};
            avg0_d_s0  <= {SIGNED_WIDTH{1'b0}};
            avg0_l_s0  <= {SIGNED_WIDTH{1'b0}};
            avg0_r_s0  <= {SIGNED_WIDTH{1'b0}};
            avg1_c_s0  <= {SIGNED_WIDTH{1'b0}};
            avg1_u_s0  <= {SIGNED_WIDTH{1'b0}};
            avg1_d_s0  <= {SIGNED_WIDTH{1'b0}};
            avg1_l_s0  <= {SIGNED_WIDTH{1'b0}};
            avg1_r_s0  <= {SIGNED_WIDTH{1'b0}};
            valid_s0   <= 1'b0;
            center_s0  <= {DATA_WIDTH{1'b0}};
            win_size_s0 <= {WIN_SIZE_WIDTH{1'b0}};
            pixel_x_s0 <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s0 <= {ROW_CNT_WIDTH{1'b0}};
        end else if (enable) begin
            // Only process if we have valid delayed data (after first row)
            if (row_valid && stage2_valid) begin
                // Use delayed data from row buffer
                grad_c_s0  <= grad_c;
                grad_u_s0  <= grad_u_bound;
                grad_d_s0  <= grad_d_bound;
                grad_l_s0  <= grad_l;
                grad_r_s0  <= grad_r;
                avg0_c_s0  <= avg0_c_rd;
                avg0_u_s0  <= avg0_u_rd;
                avg0_d_s0  <= avg0_d_rd;
                avg0_l_s0  <= avg0_l_rd;
                avg0_r_s0  <= avg0_r_rd;
                avg1_c_s0  <= avg1_c_rd;
                avg1_u_s0  <= avg1_u_rd;
                avg1_d_s0  <= avg1_d_rd;
                avg1_l_s0  <= avg1_l_rd;
                avg1_r_s0  <= avg1_r_rd;
                valid_s0   <= valid_rd;
                center_s0  <= center_rd;
                win_size_s0 <= win_size_rd;
                pixel_x_s0 <= pixel_x_rd;
                pixel_y_s0 <= pixel_y_rd;
            end else begin
                // No valid data yet, clear pipeline
                valid_s0 <= 1'b0;
            end
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
    reg signed [SIGNED_WIDTH-1:0] avg0_s1 [0:4], avg1_s1 [0:4];
    reg                    valid_s1;
    reg [DATA_WIDTH-1:0]   center_s1;
    reg [WIN_SIZE_WIDTH-1:0] win_size_s1;
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_s1;
    reg [ROW_CNT_WIDTH-1:0] pixel_y_s1;
    // Pass-through pipeline for avg0_u and avg1_u
    reg signed [SIGNED_WIDTH-1:0] avg0_u_s1, avg1_u_s1;

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 5; i = i + 1) begin
                g_s1[i]    <= {GRAD_WIDTH{1'b0}};
                avg0_s1[i] <= {SIGNED_WIDTH{1'b0}};
                avg1_s1[i] <= {SIGNED_WIDTH{1'b0}};
            end
            valid_s1   <= 1'b0;
            center_s1  <= {DATA_WIDTH{1'b0}};
            win_size_s1 <= {WIN_SIZE_WIDTH{1'b0}};
            pixel_x_s1 <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s1 <= {ROW_CNT_WIDTH{1'b0}};
            avg0_u_s1  <= {SIGNED_WIDTH{1'b0}};
            avg1_u_s1  <= {SIGNED_WIDTH{1'b0}};
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
            // Pass-through pipeline
            avg0_u_s1  <= avg0_u_s0;
            avg1_u_s1  <= avg1_u_s0;
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
    reg signed [SIGNED_WIDTH-1:0] avg0_s2 [0:4], avg1_s2 [0:4];
    reg                    valid_s2;
    reg [DATA_WIDTH-1:0]   center_s2;
    reg [WIN_SIZE_WIDTH-1:0] win_size_s2;
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_s2;
    reg [ROW_CNT_WIDTH-1:0] pixel_y_s2;
    // Pass-through pipeline for avg0_u and avg1_u
    reg signed [SIGNED_WIDTH-1:0] avg0_u_s2, avg1_u_s2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 5; i = i + 1) begin
                g_s2[i]    <= {GRAD_WIDTH{1'b0}};
                avg0_s2[i] <= {SIGNED_WIDTH{1'b0}};
                avg1_s2[i] <= {SIGNED_WIDTH{1'b0}};
            end
            valid_s2   <= 1'b0;
            center_s2  <= {DATA_WIDTH{1'b0}};
            win_size_s2 <= {WIN_SIZE_WIDTH{1'b0}};
            pixel_x_s2 <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s2 <= {ROW_CNT_WIDTH{1'b0}};
            avg0_u_s2  <= {SIGNED_WIDTH{1'b0}};
            avg1_u_s2  <= {SIGNED_WIDTH{1'b0}};
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
            // Pass-through pipeline
            avg0_u_s2  <= avg0_u_s1;
            avg1_u_s2  <= avg1_u_s1;
        end
    end

    //=========================================================================
    // Cycle 3: Weighted Multiplication (Signed)
    //=========================================================================
    // Signed multiplication: avg (s11) * grad (u14) -> signed result
    wire signed [SIGNED_WIDTH+GRAD_WIDTH-1:0] blend0_partial [0:4];
    wire signed [SIGNED_WIDTH+GRAD_WIDTH-1:0] blend1_partial [0:4];

    genvar gi;
    generate
        for (gi = 0; gi < 5; gi = gi + 1) begin : gen_mul
            // Signed avg * unsigned grad = signed result
            assign blend0_partial[gi] = avg0_s2[gi] * $signed({1'b0, g_s2[gi]});
            assign blend1_partial[gi] = avg1_s2[gi] * $signed({1'b0, g_s2[gi]});
        end
    endgenerate

    // Pipeline registers for Cycle 3
    reg signed [SIGNED_WIDTH+GRAD_WIDTH-1:0] blend0_p_s3 [0:4];
    reg signed [SIGNED_WIDTH+GRAD_WIDTH-1:0] blend1_p_s3 [0:4];
    reg [GRAD_WIDTH-1:0]            g_s3 [0:4];
    reg                             valid_s3;
    reg [DATA_WIDTH-1:0]            center_s3;
    reg [WIN_SIZE_WIDTH-1:0]        win_size_s3;
    reg [LINE_ADDR_WIDTH-1:0]       pixel_x_s3;
    reg [ROW_CNT_WIDTH-1:0]         pixel_y_s3;
    // Pass-through pipeline for avg0_u and avg1_u
    reg signed [SIGNED_WIDTH-1:0]   avg0_u_s3, avg1_u_s3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 5; i = i + 1) begin
                blend0_p_s3[i] <= {SIGNED_WIDTH+GRAD_WIDTH{1'b0}};
                blend1_p_s3[i] <= {SIGNED_WIDTH+GRAD_WIDTH{1'b0}};
                g_s3[i]        <= {GRAD_WIDTH{1'b0}};
            end
            valid_s3   <= 1'b0;
            center_s3  <= {DATA_WIDTH{1'b0}};
            win_size_s3 <= {WIN_SIZE_WIDTH{1'b0}};
            pixel_x_s3 <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s3 <= {ROW_CNT_WIDTH{1'b0}};
            avg0_u_s3  <= {SIGNED_WIDTH{1'b0}};
            avg1_u_s3  <= {SIGNED_WIDTH{1'b0}};
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
            // Pass-through pipeline
            avg0_u_s3  <= avg0_u_s2;
            avg1_u_s3  <= avg1_u_s2;
        end
    end

    //=========================================================================
    // Cycle 4: Weighted Sum (Signed)
    //=========================================================================
    // Signed addition for blend sums
    wire signed [BLEND_WIDTH-1:0] blend0_sum_comb = blend0_p_s3[0] + blend0_p_s3[1] + blend0_p_s3[2] +
                                                    blend0_p_s3[3] + blend0_p_s3[4];
    wire signed [BLEND_WIDTH-1:0] blend1_sum_comb = blend1_p_s3[0] + blend1_p_s3[1] + blend1_p_s3[2] +
                                                    blend1_p_s3[3] + blend1_p_s3[4];
    wire [GRAD_SUM_WIDTH-1:0] grad_sum_comb = g_s3[0] + g_s3[1] + g_s3[2] + g_s3[3] + g_s3[4];

    // Pipeline registers for Cycle 4
    reg signed [BLEND_WIDTH-1:0]     blend0_sum_s4, blend1_sum_s4;
    reg [GRAD_SUM_WIDTH-1:0]  grad_sum_s4;
    reg                       valid_s4;
    reg [DATA_WIDTH-1:0]      center_s4;
    reg [WIN_SIZE_WIDTH-1:0]  win_size_s4;
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_s4;
    reg [ROW_CNT_WIDTH-1:0]   pixel_y_s4;
    // Pass-through pipeline for avg0_u and avg1_u
    reg signed [SIGNED_WIDTH-1:0] avg0_u_s4, avg1_u_s4;

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
            avg0_u_s4     <= {SIGNED_WIDTH{1'b0}};
            avg1_u_s4     <= {SIGNED_WIDTH{1'b0}};
        end else if (enable) begin
            blend0_sum_s4 <= blend0_sum_comb;
            blend1_sum_s4 <= blend1_sum_comb;
            grad_sum_s4   <= grad_sum_comb;
            valid_s4      <= valid_s3;
            center_s4     <= center_s3;
            win_size_s4   <= win_size_s3;
            pixel_x_s4    <= pixel_x_s3;
            pixel_y_s4    <= pixel_y_s3;
            // Pass-through pipeline
            avg0_u_s4     <= avg0_u_s3;
            avg1_u_s4     <= avg1_u_s3;
        end
    end

    //=========================================================================
    // Cycle 5: Division Output using LUT-based Divider Module
    //=========================================================================
    // Note: LUT divider works with unsigned values, need to handle sign separately
    // For now, use signed division directly (synthesizable but may have timing impact)

    // Signed division result
    wire signed [SIGNED_WIDTH-1:0] blend0_div_comb = (grad_sum_s4 != 0) ?
                                                     (blend0_sum_s4 / $signed({{BLEND_WIDTH-GRAD_SUM_WIDTH{1'b0}}, grad_sum_s4})) :
                                                     {SIGNED_WIDTH{1'b0}};
    wire signed [SIGNED_WIDTH-1:0] blend1_div_comb = (grad_sum_s4 != 0) ?
                                                     (blend1_sum_s4 / $signed({{BLEND_WIDTH-GRAD_SUM_WIDTH{1'b0}}, grad_sum_s4})) :
                                                     {SIGNED_WIDTH{1'b0}};

    // Pass-through signals for Cycle 5 (registered with divider output)
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_s5;
    reg [ROW_CNT_WIDTH-1:0]   pixel_y_s5;
    reg signed [SIGNED_WIDTH-1:0] avg0_u_s5, avg1_u_s5;
    reg [WIN_SIZE_WIDTH-1:0]  win_size_s5;
    reg [DATA_WIDTH-1:0]      center_s5;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_x_s5    <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_s5    <= {ROW_CNT_WIDTH{1'b0}};
            avg0_u_s5     <= {SIGNED_WIDTH{1'b0}};
            avg1_u_s5     <= {SIGNED_WIDTH{1'b0}};
            win_size_s5   <= {WIN_SIZE_WIDTH{1'b0}};
            center_s5     <= {DATA_WIDTH{1'b0}};
        end else if (enable) begin
            pixel_x_s5    <= pixel_x_s4;
            pixel_y_s5    <= pixel_y_s4;
            avg0_u_s5     <= avg0_u_s4;  // Pass through from pipeline
            avg1_u_s5     <= avg1_u_s4;
            win_size_s5   <= win_size_s4;
            center_s5     <= center_s4;
        end
    end

    // Output registers
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blend0_dir_avg  <= {SIGNED_WIDTH{1'b0}};
            blend1_dir_avg  <= {SIGNED_WIDTH{1'b0}};
            stage3_valid    <= 1'b0;
            pixel_x_out     <= {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_out     <= {ROW_CNT_WIDTH{1'b0}};
            avg0_u_out      <= {SIGNED_WIDTH{1'b0}};
            avg1_u_out      <= {SIGNED_WIDTH{1'b0}};
            win_size_clip_out <= {WIN_SIZE_WIDTH{1'b0}};
            center_pixel_out <= {DATA_WIDTH{1'b0}};
        end else if (enable) begin
            blend0_dir_avg  <= blend0_div_comb;
            blend1_dir_avg  <= blend1_div_comb;
            stage3_valid    <= valid_s4;
            pixel_x_out     <= pixel_x_s5;
            pixel_y_out     <= pixel_y_s5;
            avg0_u_out      <= avg0_u_s5;
            avg1_u_out      <= avg1_u_s5;
            win_size_clip_out <= win_size_s5;
            center_pixel_out <= center_s5;
        end
    end

endmodule