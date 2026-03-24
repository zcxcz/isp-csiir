//-----------------------------------------------------------------------------
// Module: stage3_gradient_fusion
// Purpose: Gradient-weighted directional fusion
// Author: rtl-impl
// Date: 2026-03-24
// Version: v3.0 - Refactored with common_pipe and valid/ready handshake
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
// Gradient Line Buffer Design (True Row Delay Architecture):
//   CRITICAL: Stage 3 processing is delayed by 1 FULL ROW
//   - Stage 2 outputs are stored in row delay buffer for IMG_WIDTH cycles
//   - When Stage 3 processes row N, Stage 1/2 are already processing row N+1
//   - The "current" grad input is actually grad(N+1, j) - the NEXT row's gradient
//   - The gradient buffer contains grad(N) - the CURRENT row being processed
//
// Handshake Protocol:
//   - valid_in/valid_out: Data valid indicators
//   - ready_in: Downstream back-pressure signal
//   - ready_out: Always 1 (simple pipeline without skid buffer)
//
// Modules Used:
//   - common_lut_divider: Single-cycle LUT-based divider
//   - common_pipe: Pipeline register with handshake
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
    output wire                        stage2_ready,

    // Configuration
    input  wire [ROW_CNT_WIDTH-1:0]    img_height,
    input  wire [LINE_ADDR_WIDTH-1:0]  img_width,

    // Output (s11 signed format)
    output wire signed [SIGNED_WIDTH-1:0] blend0_dir_avg,
    output wire signed [SIGNED_WIDTH-1:0] blend1_dir_avg,
    output wire                         stage3_valid,
    input  wire                         stage3_ready,

    // Pass through signals
    input  wire [LINE_ADDR_WIDTH-1:0]  pixel_x,
    input  wire [ROW_CNT_WIDTH-1:0]    pixel_y,
    output wire [LINE_ADDR_WIDTH-1:0]  pixel_x_out,
    output wire [ROW_CNT_WIDTH-1:0]    pixel_y_out,
    output wire signed [SIGNED_WIDTH-1:0] avg0_u_out,
    output wire signed [SIGNED_WIDTH-1:0] avg1_u_out,
    output wire [WIN_SIZE_WIDTH-1:0]   win_size_clip_out,
    output wire [DATA_WIDTH-1:0]       center_pixel_out
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam BLEND_WIDTH = SIGNED_WIDTH + GRAD_WIDTH + 2;  // 27-bit for blend sum (signed)
    localparam GRAD_SUM_WIDTH = GRAD_WIDTH + 3;              // 17-bit for grad sum
    localparam PRODUCT_SHIFT = 26;  // For LUT divider

    //=========================================================================
    // Ready Signal (Simple Pipeline - Always Ready)
    //=========================================================================
    assign stage2_ready = 1'b1;

    //=========================================================================
    // Row Delay Control
    //=========================================================================
    reg [ROW_CNT_WIDTH-1:0] row_counter;
    reg                     row_valid;
    reg [LINE_ADDR_WIDTH-1:0] col_counter;
    reg                     flush_active;
    reg [LINE_ADDR_WIDTH-1:0] flush_counter;
    reg                     flush_done;
    reg                     stage2_valid_d;

    wire is_first_row = (row_counter == 0) || !row_valid;
    wire is_last_row = (row_counter >= img_height - 1) || flush_active;
    wire stage2_stopped = stage2_valid_d && !stage2_valid && row_valid && !flush_done;

    //=========================================================================
    // Row Delay Buffer for Stage 2 Outputs
    //=========================================================================
    reg [GRAD_WIDTH-1:0] grad_line_buf_0 [0:IMG_WIDTH-1];
    reg [GRAD_WIDTH-1:0] grad_line_buf_1 [0:IMG_WIDTH-1];
    reg                  grad_buf_sel;

    reg signed [SIGNED_WIDTH-1:0] avg0_c_buf_0 [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg0_u_buf_0 [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg0_d_buf_0 [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg0_l_buf_0 [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg0_r_buf_0 [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg1_c_buf_0 [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg1_u_buf_0 [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg1_d_buf_0 [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg1_l_buf_0 [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg1_r_buf_0 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0]   center_buf_0 [0:IMG_WIDTH-1];
    reg [WIN_SIZE_WIDTH-1:0] win_size_buf_0 [0:IMG_WIDTH-1];
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_buf_0 [0:IMG_WIDTH-1];
    reg [ROW_CNT_WIDTH-1:0] pixel_y_buf_0 [0:IMG_WIDTH-1];
    reg                     valid_buf_0 [0:IMG_WIDTH-1];

    reg signed [SIGNED_WIDTH-1:0] avg0_c_buf_1 [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg0_u_buf_1 [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg0_d_buf_1 [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg0_l_buf_1 [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg0_r_buf_1 [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg1_c_buf_1 [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg1_u_buf_1 [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg1_d_buf_1 [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg1_l_buf_1 [0:IMG_WIDTH-1];
    reg signed [SIGNED_WIDTH-1:0] avg1_r_buf_1 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0]   center_buf_1 [0:IMG_WIDTH-1];
    reg [WIN_SIZE_WIDTH-1:0] win_size_buf_1 [0:IMG_WIDTH-1];
    reg [LINE_ADDR_WIDTH-1:0] pixel_x_buf_1 [0:IMG_WIDTH-1];
    reg [ROW_CNT_WIDTH-1:0] pixel_y_buf_1 [0:IMG_WIDTH-1];
    reg                     valid_buf_1 [0:IMG_WIDTH-1];

    reg                     avg_buf_sel;

    wire [GRAD_WIDTH-1:0] grad_next_row = grad;

    integer init_i;
    initial begin
        for (init_i = 0; init_i < IMG_WIDTH; init_i = init_i + 1) begin
            grad_line_buf_0[init_i] = {GRAD_WIDTH{1'b0}};
            grad_line_buf_1[init_i] = {GRAD_WIDTH{1'b0}};
            avg0_c_buf_0[init_i] = {SIGNED_WIDTH{1'b0}};
            avg0_u_buf_0[init_i] = {SIGNED_WIDTH{1'b0}};
            avg0_d_buf_0[init_i] = {SIGNED_WIDTH{1'b0}};
            avg0_l_buf_0[init_i] = {SIGNED_WIDTH{1'b0}};
            avg0_r_buf_0[init_i] = {SIGNED_WIDTH{1'b0}};
            avg1_c_buf_0[init_i] = {SIGNED_WIDTH{1'b0}};
            avg1_u_buf_0[init_i] = {SIGNED_WIDTH{1'b0}};
            avg1_d_buf_0[init_i] = {SIGNED_WIDTH{1'b0}};
            avg1_l_buf_0[init_i] = {SIGNED_WIDTH{1'b0}};
            avg1_r_buf_0[init_i] = {SIGNED_WIDTH{1'b0}};
            center_buf_0[init_i] = {DATA_WIDTH{1'b0}};
            win_size_buf_0[init_i] = {WIN_SIZE_WIDTH{1'b0}};
            pixel_x_buf_0[init_i] = {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_buf_0[init_i] = {ROW_CNT_WIDTH{1'b0}};
            valid_buf_0[init_i] = 1'b0;
            avg0_c_buf_1[init_i] = {SIGNED_WIDTH{1'b0}};
            avg0_u_buf_1[init_i] = {SIGNED_WIDTH{1'b0}};
            avg0_d_buf_1[init_i] = {SIGNED_WIDTH{1'b0}};
            avg0_l_buf_1[init_i] = {SIGNED_WIDTH{1'b0}};
            avg0_r_buf_1[init_i] = {SIGNED_WIDTH{1'b0}};
            avg1_c_buf_1[init_i] = {SIGNED_WIDTH{1'b0}};
            avg1_u_buf_1[init_i] = {SIGNED_WIDTH{1'b0}};
            avg1_d_buf_1[init_i] = {SIGNED_WIDTH{1'b0}};
            avg1_l_buf_1[init_i] = {SIGNED_WIDTH{1'b0}};
            avg1_r_buf_1[init_i] = {SIGNED_WIDTH{1'b0}};
            center_buf_1[init_i] = {DATA_WIDTH{1'b0}};
            win_size_buf_1[init_i] = {WIN_SIZE_WIDTH{1'b0}};
            pixel_x_buf_1[init_i] = {LINE_ADDR_WIDTH{1'b0}};
            pixel_y_buf_1[init_i] = {ROW_CNT_WIDTH{1'b0}};
            valid_buf_1[init_i] = 1'b0;
        end
    end

    //=========================================================================
    // Row Delay Buffer Write
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_counter <= {ROW_CNT_WIDTH{1'b0}};
            col_counter <= {LINE_ADDR_WIDTH{1'b0}};
            row_valid   <= 1'b0;
            grad_buf_sel <= 1'b0;
            avg_buf_sel <= 1'b0;
            flush_active <= 1'b0;
            flush_counter <= {LINE_ADDR_WIDTH{1'b0}};
            flush_done <= 1'b0;
            stage2_valid_d <= 1'b0;
        end else if (enable && stage3_ready) begin
            stage2_valid_d <= stage2_valid;

            if (stage2_stopped && !flush_active) begin
                flush_active <= 1'b1;
                flush_counter <= {LINE_ADDR_WIDTH{1'b0}};
            end else if (flush_active) begin
                if (flush_counter >= img_width - 1) begin
                    flush_active <= 1'b0;
                    flush_done <= 1'b1;
                end else begin
                    flush_counter <= flush_counter + 1'b1;
                end
            end

            if (stage2_valid) begin
                if (avg_buf_sel == 0) begin
                    avg0_c_buf_0[col_counter] <= avg0_c;
                    avg0_u_buf_0[col_counter] <= avg0_u;
                    avg0_d_buf_0[col_counter] <= avg0_d;
                    avg0_l_buf_0[col_counter] <= avg0_l;
                    avg0_r_buf_0[col_counter] <= avg0_r;
                    avg1_c_buf_0[col_counter] <= avg1_c;
                    avg1_u_buf_0[col_counter] <= avg1_u;
                    avg1_d_buf_0[col_counter] <= avg1_d;
                    avg1_l_buf_0[col_counter] <= avg1_l;
                    avg1_r_buf_0[col_counter] <= avg1_r;
                    center_buf_0[col_counter] <= center_pixel;
                    win_size_buf_0[col_counter] <= win_size_clip;
                    pixel_x_buf_0[col_counter] <= pixel_x;
                    pixel_y_buf_0[col_counter] <= pixel_y;
                    valid_buf_0[col_counter] <= stage2_valid;
                end else begin
                    avg0_c_buf_1[col_counter] <= avg0_c;
                    avg0_u_buf_1[col_counter] <= avg0_u;
                    avg0_d_buf_1[col_counter] <= avg0_d;
                    avg0_l_buf_1[col_counter] <= avg0_l;
                    avg0_r_buf_1[col_counter] <= avg0_r;
                    avg1_c_buf_1[col_counter] <= avg1_c;
                    avg1_u_buf_1[col_counter] <= avg1_u;
                    avg1_d_buf_1[col_counter] <= avg1_d;
                    avg1_l_buf_1[col_counter] <= avg1_l;
                    avg1_r_buf_1[col_counter] <= avg1_r;
                    center_buf_1[col_counter] <= center_pixel;
                    win_size_buf_1[col_counter] <= win_size_clip;
                    pixel_x_buf_1[col_counter] <= pixel_x;
                    pixel_y_buf_1[col_counter] <= pixel_y;
                    valid_buf_1[col_counter] <= stage2_valid;
                end

                if (grad_buf_sel)
                    grad_line_buf_1[col_counter] <= grad;
                else
                    grad_line_buf_0[col_counter] <= grad;

                if (col_counter >= img_width - 1) begin
                    col_counter <= {LINE_ADDR_WIDTH{1'b0}};
                    grad_buf_sel <= ~grad_buf_sel;
                    avg_buf_sel <= ~avg_buf_sel;
                    row_counter <= row_counter + 1'b1;
                    row_valid   <= 1'b1;
                end else begin
                    col_counter <= col_counter + 1'b1;
                end
            end
        end
    end

    //=========================================================================
    // Cycle 0: Read from Previous Buffer
    //=========================================================================
    wire [LINE_ADDR_WIDTH-1:0] rd_addr = flush_active ? flush_counter : col_counter;

    wire signed [SIGNED_WIDTH-1:0] avg0_c_rd = avg_buf_sel ? avg0_c_buf_0[rd_addr] : avg0_c_buf_1[rd_addr];
    wire signed [SIGNED_WIDTH-1:0] avg0_u_rd = avg_buf_sel ? avg0_u_buf_0[rd_addr] : avg0_u_buf_1[rd_addr];
    wire signed [SIGNED_WIDTH-1:0] avg0_d_rd = avg_buf_sel ? avg0_d_buf_0[rd_addr] : avg0_d_buf_1[rd_addr];
    wire signed [SIGNED_WIDTH-1:0] avg0_l_rd = avg_buf_sel ? avg0_l_buf_0[rd_addr] : avg0_l_buf_1[rd_addr];
    wire signed [SIGNED_WIDTH-1:0] avg0_r_rd = avg_buf_sel ? avg0_r_buf_0[rd_addr] : avg0_r_buf_1[rd_addr];
    wire signed [SIGNED_WIDTH-1:0] avg1_c_rd = avg_buf_sel ? avg1_c_buf_0[rd_addr] : avg1_c_buf_1[rd_addr];
    wire signed [SIGNED_WIDTH-1:0] avg1_u_rd = avg_buf_sel ? avg1_u_buf_0[rd_addr] : avg1_u_buf_1[rd_addr];
    wire signed [SIGNED_WIDTH-1:0] avg1_d_rd = avg_buf_sel ? avg1_d_buf_0[rd_addr] : avg1_d_buf_1[rd_addr];
    wire signed [SIGNED_WIDTH-1:0] avg1_l_rd = avg_buf_sel ? avg1_l_buf_0[rd_addr] : avg1_l_buf_1[rd_addr];
    wire signed [SIGNED_WIDTH-1:0] avg1_r_rd = avg_buf_sel ? avg1_r_buf_0[rd_addr] : avg1_r_buf_1[rd_addr];
    wire [DATA_WIDTH-1:0]   center_rd = avg_buf_sel ? center_buf_0[rd_addr] : center_buf_1[rd_addr];
    wire [WIN_SIZE_WIDTH-1:0] win_size_rd = avg_buf_sel ? win_size_buf_0[rd_addr] : win_size_buf_1[rd_addr];
    wire [LINE_ADDR_WIDTH-1:0] pixel_x_rd = avg_buf_sel ? pixel_x_buf_0[rd_addr] : pixel_x_buf_1[rd_addr];
    wire [ROW_CNT_WIDTH-1:0] pixel_y_rd = avg_buf_sel ? pixel_y_buf_0[rd_addr] : pixel_y_buf_1[rd_addr];
    wire                    valid_rd = avg_buf_sel ? valid_buf_0[rd_addr] : valid_buf_1[rd_addr];

    wire [GRAD_WIDTH-1:0] grad_c = grad_buf_sel ? grad_line_buf_0[rd_addr] : grad_line_buf_1[rd_addr];
    wire [GRAD_WIDTH-1:0] grad_u = grad_buf_sel ? grad_line_buf_1[rd_addr] : grad_line_buf_0[rd_addr];
    wire [GRAD_WIDTH-1:0] grad_d = grad_next_row;
    wire [LINE_ADDR_WIDTH-1:0] grad_l_addr = (rd_addr > 0) ? rd_addr - 1'b1 : {LINE_ADDR_WIDTH{1'b0}};
    wire [GRAD_WIDTH-1:0] grad_l_raw = grad_buf_sel ? grad_line_buf_0[grad_l_addr] : grad_line_buf_1[grad_l_addr];
    wire [GRAD_WIDTH-1:0] grad_l = (rd_addr == 0) ? grad_c : grad_l_raw;
    wire [GRAD_WIDTH-1:0] grad_r = grad_c;

    wire [GRAD_WIDTH-1:0] grad_u_bound = is_first_row ? grad_c : grad_u;
    wire [GRAD_WIDTH-1:0] grad_d_bound = is_last_row ? grad_c : grad_d;

    // Valid signal for Cycle 0
    wire valid_s0_comb = row_valid && valid_rd && (stage2_valid || flush_active);

    //=========================================================================
    // Cycle 0 Pipeline Registers
    //=========================================================================
    localparam PIPE_S0_WIDTH = 5 * GRAD_WIDTH + 10 * SIGNED_WIDTH + WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1;

    wire [PIPE_S0_WIDTH-1:0] pipe_s0_din = {grad_c, grad_u_bound, grad_d_bound, grad_l, grad_r,
                                            avg0_c_rd, avg0_u_rd, avg0_d_rd, avg0_l_rd, avg0_r_rd,
                                            avg1_c_rd, avg1_u_rd, avg1_d_rd, avg1_l_rd, avg1_r_rd,
                                            win_size_rd, pixel_x_rd, pixel_y_rd, center_rd, valid_s0_comb};

    wire [PIPE_S0_WIDTH-1:0] pipe_s0_dout;
    wire                     valid_s0;

    common_pipe #(
        .DATA_WIDTH (PIPE_S0_WIDTH),
        .STAGES     (1),
        .RESET_VAL  (0)
    ) u_pipe_s0 (
        .clk       (clk),
        .rst_n     (rst_n),
        .din       (pipe_s0_din),
        .valid_in  (valid_s0_comb),
        .ready_out (),
        .dout      (pipe_s0_dout),
        .valid_out (valid_s0),
        .ready_in  (stage3_ready)
    );

    // Unpack signals
    wire [GRAD_WIDTH-1:0]   grad_c_s0  = pipe_s0_dout[PIPE_S0_WIDTH-1 -: GRAD_WIDTH];
    wire [GRAD_WIDTH-1:0]   grad_u_s0  = pipe_s0_dout[PIPE_S0_WIDTH-1-GRAD_WIDTH -: GRAD_WIDTH];
    wire [GRAD_WIDTH-1:0]   grad_d_s0  = pipe_s0_dout[PIPE_S0_WIDTH-1-2*GRAD_WIDTH -: GRAD_WIDTH];
    wire [GRAD_WIDTH-1:0]   grad_l_s0  = pipe_s0_dout[PIPE_S0_WIDTH-1-3*GRAD_WIDTH -: GRAD_WIDTH];
    wire [GRAD_WIDTH-1:0]   grad_r_s0  = pipe_s0_dout[PIPE_S0_WIDTH-1-4*GRAD_WIDTH -: GRAD_WIDTH];

    wire signed [SIGNED_WIDTH-1:0] avg0_c_s0 = pipe_s0_dout[5*GRAD_WIDTH + 10*SIGNED_WIDTH - 1 -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] avg0_u_s0 = pipe_s0_dout[5*GRAD_WIDTH + 9*SIGNED_WIDTH - 1 -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] avg0_d_s0 = pipe_s0_dout[5*GRAD_WIDTH + 8*SIGNED_WIDTH - 1 -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] avg0_l_s0 = pipe_s0_dout[5*GRAD_WIDTH + 7*SIGNED_WIDTH - 1 -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] avg0_r_s0 = pipe_s0_dout[5*GRAD_WIDTH + 6*SIGNED_WIDTH - 1 -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] avg1_c_s0 = pipe_s0_dout[5*GRAD_WIDTH + 5*SIGNED_WIDTH - 1 -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] avg1_u_s0 = pipe_s0_dout[5*GRAD_WIDTH + 4*SIGNED_WIDTH - 1 -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] avg1_d_s0 = pipe_s0_dout[5*GRAD_WIDTH + 3*SIGNED_WIDTH - 1 -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] avg1_l_s0 = pipe_s0_dout[5*GRAD_WIDTH + 2*SIGNED_WIDTH - 1 -: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] avg1_r_s0 = pipe_s0_dout[5*GRAD_WIDTH + SIGNED_WIDTH - 1 -: SIGNED_WIDTH];

    wire [WIN_SIZE_WIDTH-1:0]   win_size_s0 = pipe_s0_dout[WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1 +: WIN_SIZE_WIDTH];
    wire [LINE_ADDR_WIDTH-1:0]  pixel_x_s0  = pipe_s0_dout[LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1 +: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0]    pixel_y_s0  = pipe_s0_dout[ROW_CNT_WIDTH + DATA_WIDTH + 1 +: ROW_CNT_WIDTH];
    wire [DATA_WIDTH-1:0]       center_s0   = pipe_s0_dout[DATA_WIDTH + 1 +: DATA_WIDTH];

    //=========================================================================
    // Cycle 1: Gradient Sort (First Stage)
    //=========================================================================
    wire [GRAD_WIDTH-1:0] g0 = grad_c_s0;
    wire [GRAD_WIDTH-1:0] g1 = grad_u_s0;
    wire [GRAD_WIDTH-1:0] g2 = grad_d_s0;
    wire [GRAD_WIDTH-1:0] g3 = grad_l_s0;
    wire [GRAD_WIDTH-1:0] g4 = grad_r_s0;

    //=========================================================================
    // Cycle 1 Pipeline Registers
    //=========================================================================
    localparam PIPE_S1_WIDTH = 5 * GRAD_WIDTH + 10 * SIGNED_WIDTH + WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1;

    wire [PIPE_S1_WIDTH-1:0] pipe_s1_din = {g0, g1, g2, g3, g4,
                                            avg0_c_s0, avg0_u_s0, avg0_d_s0, avg0_l_s0, avg0_r_s0,
                                            avg1_c_s0, avg1_u_s0, avg1_d_s0, avg1_l_s0, avg1_r_s0,
                                            win_size_s0, pixel_x_s0, pixel_y_s0, center_s0, valid_s0};

    wire [PIPE_S1_WIDTH-1:0] pipe_s1_dout;
    wire                     valid_s1;

    common_pipe #(
        .DATA_WIDTH (PIPE_S1_WIDTH),
        .STAGES     (1),
        .RESET_VAL  (0)
    ) u_pipe_s1 (
        .clk       (clk),
        .rst_n     (rst_n),
        .din       (pipe_s1_din),
        .valid_in  (valid_s0),
        .ready_out (),
        .dout      (pipe_s1_dout),
        .valid_out (valid_s1),
        .ready_in  (stage3_ready)
    );

    // Unpack signals
    wire [GRAD_WIDTH-1:0]   g_s1 [0:4];
    genvar gi;
    generate
        for (gi = 0; gi < 5; gi = gi + 1) begin : gen_g_s1
            assign g_s1[gi] = pipe_s1_dout[PIPE_S1_WIDTH-1-gi*GRAD_WIDTH -: GRAD_WIDTH];
        end
    endgenerate

    wire signed [SIGNED_WIDTH-1:0] avg0_s1 [0:4], avg1_s1 [0:4];
    generate
        for (gi = 0; gi < 5; gi = gi + 1) begin : gen_avg0_s1
            assign avg0_s1[gi] = pipe_s1_dout[5*GRAD_WIDTH + (9-gi)*SIGNED_WIDTH +: SIGNED_WIDTH];
            assign avg1_s1[gi] = pipe_s1_dout[5*GRAD_WIDTH + 5*SIGNED_WIDTH + (4-gi)*SIGNED_WIDTH +: SIGNED_WIDTH];
        end
    endgenerate

    wire [WIN_SIZE_WIDTH-1:0]   win_size_s1 = pipe_s1_dout[WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1 +: WIN_SIZE_WIDTH];
    wire [LINE_ADDR_WIDTH-1:0]  pixel_x_s1  = pipe_s1_dout[LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1 +: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0]    pixel_y_s1  = pipe_s1_dout[ROW_CNT_WIDTH + DATA_WIDTH + 1 +: ROW_CNT_WIDTH];
    wire [DATA_WIDTH-1:0]       center_s1   = pipe_s1_dout[DATA_WIDTH + 1 +: DATA_WIDTH];

    // Pass-through for avg0_u and avg1_u
    wire signed [SIGNED_WIDTH-1:0] avg0_u_s1 = avg0_s1[1];
    wire signed [SIGNED_WIDTH-1:0] avg1_u_s1 = avg1_s1[1];

    //=========================================================================
    // Cycle 2: Complete Sorting (Full 5-input descending sort)
    //=========================================================================
    function [5*GRAD_WIDTH-1:0] sort_5_desc;
        input [GRAD_WIDTH-1:0] in0, in1, in2, in3, in4;
        reg [GRAD_WIDTH-1:0] a, b, c, d, e;
        reg [GRAD_WIDTH-1:0] tmp;
        begin
            a = in0; b = in1; c = in2; d = in3; e = in4;
            if (b > a) begin tmp = a; a = b; b = tmp; end
            if (c > b) begin tmp = b; b = c; c = tmp; end
            if (d > c) begin tmp = c; c = d; d = tmp; end
            if (e > d) begin tmp = d; d = e; e = tmp; end
            if (b > a) begin tmp = a; a = b; b = tmp; end
            if (c > b) begin tmp = b; b = c; c = tmp; end
            if (d > c) begin tmp = c; c = d; d = tmp; end
            if (b > a) begin tmp = a; a = b; b = tmp; end
            if (c > b) begin tmp = b; b = c; c = tmp; end
            if (b > a) begin tmp = a; a = b; b = tmp; end
            sort_5_desc = {e, d, c, b, a};
        end
    endfunction

    wire [5*GRAD_WIDTH-1:0] sorted_pack = sort_5_desc(g_s1[0], g_s1[1], g_s1[2], g_s1[3], g_s1[4]);
    wire [GRAD_WIDTH-1:0] g_sorted [0:4];
    assign {g_sorted[4], g_sorted[3], g_sorted[2], g_sorted[1], g_sorted[0]} = sorted_pack;

    //=========================================================================
    // Cycle 2 Pipeline Registers
    //=========================================================================
    localparam PIPE_S2_WIDTH = 5 * GRAD_WIDTH + 10 * SIGNED_WIDTH + WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1;

    wire [PIPE_S2_WIDTH-1:0] pipe_s2_din = {g_sorted[0], g_sorted[1], g_sorted[2], g_sorted[3], g_sorted[4],
                                            avg0_s1[0], avg0_s1[1], avg0_s1[2], avg0_s1[3], avg0_s1[4],
                                            avg1_s1[0], avg1_s1[1], avg1_s1[2], avg1_s1[3], avg1_s1[4],
                                            win_size_s1, pixel_x_s1, pixel_y_s1, center_s1, valid_s1};

    wire [PIPE_S2_WIDTH-1:0] pipe_s2_dout;
    wire                     valid_s2;

    common_pipe #(
        .DATA_WIDTH (PIPE_S2_WIDTH),
        .STAGES     (1),
        .RESET_VAL  (0)
    ) u_pipe_s2 (
        .clk       (clk),
        .rst_n     (rst_n),
        .din       (pipe_s2_din),
        .valid_in  (valid_s1),
        .ready_out (),
        .dout      (pipe_s2_dout),
        .valid_out (valid_s2),
        .ready_in  (stage3_ready)
    );

    // Unpack signals
    wire [GRAD_WIDTH-1:0]   g_s2 [0:4];
    generate
        for (gi = 0; gi < 5; gi = gi + 1) begin : gen_g_s2
            assign g_s2[gi] = pipe_s2_dout[PIPE_S2_WIDTH-1-gi*GRAD_WIDTH -: GRAD_WIDTH];
        end
    endgenerate

    wire signed [SIGNED_WIDTH-1:0] avg0_s2 [0:4], avg1_s2 [0:4];
    generate
        for (gi = 0; gi < 5; gi = gi + 1) begin : gen_avg_s2
            assign avg0_s2[gi] = pipe_s2_dout[5*GRAD_WIDTH + (9-gi)*SIGNED_WIDTH +: SIGNED_WIDTH];
            assign avg1_s2[gi] = pipe_s2_dout[5*GRAD_WIDTH + 5*SIGNED_WIDTH + (4-gi)*SIGNED_WIDTH +: SIGNED_WIDTH];
        end
    endgenerate

    wire [WIN_SIZE_WIDTH-1:0]   win_size_s2 = pipe_s2_dout[WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1 +: WIN_SIZE_WIDTH];
    wire [LINE_ADDR_WIDTH-1:0]  pixel_x_s2  = pipe_s2_dout[LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1 +: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0]    pixel_y_s2  = pipe_s2_dout[ROW_CNT_WIDTH + DATA_WIDTH + 1 +: ROW_CNT_WIDTH];
    wire [DATA_WIDTH-1:0]       center_s2   = pipe_s2_dout[DATA_WIDTH + 1 +: DATA_WIDTH];

    wire signed [SIGNED_WIDTH-1:0] avg0_u_s2 = avg0_s2[1];
    wire signed [SIGNED_WIDTH-1:0] avg1_u_s2 = avg1_s2[1];

    //=========================================================================
    // Cycle 3: Weighted Multiplication (Signed)
    //=========================================================================
    wire signed [SIGNED_WIDTH+GRAD_WIDTH:0] blend0_partial [0:4];
    wire signed [SIGNED_WIDTH+GRAD_WIDTH:0] blend1_partial [0:4];

    genvar mi;
    generate
        for (mi = 0; mi < 5; mi = mi + 1) begin : gen_mul
            assign blend0_partial[mi] = avg0_s2[mi] * $signed({1'b0, g_s2[mi]});
            assign blend1_partial[mi] = avg1_s2[mi] * $signed({1'b0, g_s2[mi]});
        end
    endgenerate

    //=========================================================================
    // Cycle 3 Pipeline Registers
    //=========================================================================
    localparam PIPE_S3_WIDTH = 10 * (SIGNED_WIDTH + GRAD_WIDTH + 1) + 5 * GRAD_WIDTH + WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1;

    wire [PIPE_S3_WIDTH-1:0] pipe_s3_din = {blend0_partial[0], blend0_partial[1], blend0_partial[2], blend0_partial[3], blend0_partial[4],
                                            blend1_partial[0], blend1_partial[1], blend1_partial[2], blend1_partial[3], blend1_partial[4],
                                            g_s2[0], g_s2[1], g_s2[2], g_s2[3], g_s2[4],
                                            win_size_s2, pixel_x_s2, pixel_y_s2, center_s2, valid_s2};

    wire [PIPE_S3_WIDTH-1:0] pipe_s3_dout;
    wire                     valid_s3;

    common_pipe #(
        .DATA_WIDTH (PIPE_S3_WIDTH),
        .STAGES     (1),
        .RESET_VAL  (0)
    ) u_pipe_s3 (
        .clk       (clk),
        .rst_n     (rst_n),
        .din       (pipe_s3_din),
        .valid_in  (valid_s2),
        .ready_out (),
        .dout      (pipe_s3_dout),
        .valid_out (valid_s3),
        .ready_in  (stage3_ready)
    );

    // Unpack signals
    localparam MUL_WIDTH = SIGNED_WIDTH + GRAD_WIDTH + 1;
    wire signed [MUL_WIDTH-1:0] blend0_p_s3 [0:4], blend1_p_s3 [0:4];
    generate
        for (gi = 0; gi < 5; gi = gi + 1) begin : gen_blend_p_s3
            assign blend0_p_s3[gi] = pipe_s3_dout[PIPE_S3_WIDTH-1-gi*MUL_WIDTH -: MUL_WIDTH];
            assign blend1_p_s3[gi] = pipe_s3_dout[PIPE_S3_WIDTH-1-(5+gi)*MUL_WIDTH -: MUL_WIDTH];
        end
    endgenerate

    wire [GRAD_WIDTH-1:0]   g_s3 [0:4];
    generate
        for (gi = 0; gi < 5; gi = gi + 1) begin : gen_g_s3
            assign g_s3[gi] = pipe_s3_dout[10*MUL_WIDTH + (4-gi)*GRAD_WIDTH +: GRAD_WIDTH];
        end
    endgenerate

    wire [WIN_SIZE_WIDTH-1:0]   win_size_s3 = pipe_s3_dout[WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1 +: WIN_SIZE_WIDTH];
    wire [LINE_ADDR_WIDTH-1:0]  pixel_x_s3  = pipe_s3_dout[LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1 +: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0]    pixel_y_s3  = pipe_s3_dout[ROW_CNT_WIDTH + DATA_WIDTH + 1 +: ROW_CNT_WIDTH];
    wire [DATA_WIDTH-1:0]       center_s3   = pipe_s3_dout[DATA_WIDTH + 1 +: DATA_WIDTH];

    wire signed [SIGNED_WIDTH-1:0] avg0_u_s3 = avg0_u_s2;
    wire signed [SIGNED_WIDTH-1:0] avg1_u_s3 = avg1_u_s2;

    //=========================================================================
    // Cycle 4: Weighted Sum (Signed) + Sign Extraction
    //=========================================================================
    wire signed [BLEND_WIDTH-1:0] blend0_sum_comb = blend0_p_s3[0] + blend0_p_s3[1] + blend0_p_s3[2] + blend0_p_s3[3] + blend0_p_s3[4];
    wire signed [BLEND_WIDTH-1:0] blend1_sum_comb = blend1_p_s3[0] + blend1_p_s3[1] + blend1_p_s3[2] + blend1_p_s3[3] + blend1_p_s3[4];
    wire [GRAD_SUM_WIDTH-1:0] grad_sum_comb = g_s3[0] + g_s3[1] + g_s3[2] + g_s3[3] + g_s3[4];

    wire blend0_sign = blend0_sum_comb[BLEND_WIDTH-1];
    wire blend1_sign = blend1_sum_comb[BLEND_WIDTH-1];
    wire signed [BLEND_WIDTH-1:0] blend0_abs_full = blend0_sign ? -blend0_sum_comb : blend0_sum_comb;
    wire signed [BLEND_WIDTH-1:0] blend1_abs_full = blend1_sign ? -blend1_sum_comb : blend1_sum_comb;
    wire [PRODUCT_SHIFT-1:0] blend0_abs = blend0_abs_full[PRODUCT_SHIFT-1:0];
    wire [PRODUCT_SHIFT-1:0] blend1_abs = blend1_abs_full[PRODUCT_SHIFT-1:0];

    //=========================================================================
    // Cycle 4 Pipeline Registers
    //=========================================================================
    localparam PIPE_S4_WIDTH = 2 * BLEND_WIDTH + GRAD_SUM_WIDTH + WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 3;

    wire [PIPE_S4_WIDTH-1:0] pipe_s4_din = {blend0_sum_comb, blend1_sum_comb, grad_sum_comb,
                                            win_size_s3, pixel_x_s3, pixel_y_s3, center_s3,
                                            blend0_sign, blend1_sign, valid_s3};

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
        .valid_in  (valid_s3),
        .ready_out (),
        .dout      (pipe_s4_dout),
        .valid_out (valid_s4),
        .ready_in  (stage3_ready)
    );

    // Unpack signals
    wire signed [BLEND_WIDTH-1:0] blend0_sum_s4 = pipe_s4_dout[PIPE_S4_WIDTH-1 -: BLEND_WIDTH];
    wire signed [BLEND_WIDTH-1:0] blend1_sum_s4 = pipe_s4_dout[PIPE_S4_WIDTH-1-BLEND_WIDTH -: BLEND_WIDTH];
    wire [GRAD_SUM_WIDTH-1:0] grad_sum_s4 = pipe_s4_dout[PIPE_S4_WIDTH-1-2*BLEND_WIDTH -: GRAD_SUM_WIDTH];
    wire [WIN_SIZE_WIDTH-1:0] win_size_s4 = pipe_s4_dout[WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 3 +: WIN_SIZE_WIDTH];
    wire [LINE_ADDR_WIDTH-1:0] pixel_x_s4 = pipe_s4_dout[LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 3 +: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0] pixel_y_s4 = pipe_s4_dout[ROW_CNT_WIDTH + DATA_WIDTH + 3 +: ROW_CNT_WIDTH];
    wire [DATA_WIDTH-1:0] center_s4 = pipe_s4_dout[DATA_WIDTH + 3 +: DATA_WIDTH];
    wire blend0_sign_s4 = pipe_s4_dout[2];
    wire blend1_sign_s4 = pipe_s4_dout[1];

    wire signed [SIGNED_WIDTH-1:0] avg0_u_s4 = avg0_u_s3;
    wire signed [SIGNED_WIDTH-1:0] avg1_u_s4 = avg1_u_s3;

    //=========================================================================
    // Cycle 5: Division Output using LUT-based Divider
    //=========================================================================
    wire signed [BLEND_WIDTH-1:0] blend0_abs_full_s4 = blend0_sign_s4 ? -blend0_sum_s4 : blend0_sum_s4;
    wire signed [BLEND_WIDTH-1:0] blend1_abs_full_s4 = blend1_sign_s4 ? -blend1_sum_s4 : blend1_sum_s4;
    wire [PRODUCT_SHIFT-1:0] blend0_abs_s4 = blend0_abs_full_s4[PRODUCT_SHIFT-1:0];
    wire [PRODUCT_SHIFT-1:0] blend1_abs_s4 = blend1_abs_full_s4[PRODUCT_SHIFT-1:0];

    wire [SIGNED_WIDTH-1:0] blend0_quot, blend1_quot;
    wire                    div_valid;

    common_lut_divider #(
        .DIVIDEND_WIDTH (GRAD_SUM_WIDTH),
        .QUOTIENT_WIDTH (SIGNED_WIDTH),
        .PRODUCT_SHIFT  (PRODUCT_SHIFT)
    ) u_lut_div_0 (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (enable),
        .dividend (grad_sum_s4),
        .numerator(blend0_abs_s4),
        .valid_in (valid_s4),
        .quotient (blend0_quot),
        .valid_out(div_valid)
    );

    common_lut_divider #(
        .DIVIDEND_WIDTH (GRAD_SUM_WIDTH),
        .QUOTIENT_WIDTH (SIGNED_WIDTH),
        .PRODUCT_SHIFT  (PRODUCT_SHIFT)
    ) u_lut_div_1 (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (enable),
        .dividend (grad_sum_s4),
        .numerator(blend1_abs_s4),
        .valid_in (valid_s4),
        .quotient (blend1_quot),
        .valid_out()
    );

    //=========================================================================
    // Pass-through signals for Cycle 5
    //=========================================================================
    localparam PIPE_S5_WIDTH = LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 2 * SIGNED_WIDTH + WIN_SIZE_WIDTH + DATA_WIDTH + 2;

    wire [PIPE_S5_WIDTH-1:0] pipe_s5_din = {pixel_x_s4, pixel_y_s4, avg0_u_s4, avg1_u_s4, win_size_s4, center_s4, blend0_sign_s4, blend1_sign_s4};

    wire [PIPE_S5_WIDTH-1:0] pipe_s5_dout;

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
        .valid_out (),
        .ready_in  (stage3_ready)
    );

    wire [LINE_ADDR_WIDTH-1:0] pixel_x_s5 = pipe_s5_dout[PIPE_S5_WIDTH-1 -: LINE_ADDR_WIDTH];
    wire [ROW_CNT_WIDTH-1:0] pixel_y_s5 = pipe_s5_dout[PIPE_S5_WIDTH-1-LINE_ADDR_WIDTH -: ROW_CNT_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] avg0_u_s5 = pipe_s5_dout[2*SIGNED_WIDTH + WIN_SIZE_WIDTH + DATA_WIDTH + 2 +: SIGNED_WIDTH];
    wire signed [SIGNED_WIDTH-1:0] avg1_u_s5 = pipe_s5_dout[SIGNED_WIDTH + WIN_SIZE_WIDTH + DATA_WIDTH + 2 +: SIGNED_WIDTH];
    wire [WIN_SIZE_WIDTH-1:0] win_size_s5 = pipe_s5_dout[WIN_SIZE_WIDTH + DATA_WIDTH + 2 +: WIN_SIZE_WIDTH];
    wire [DATA_WIDTH-1:0] center_s5 = pipe_s5_dout[DATA_WIDTH + 2 +: DATA_WIDTH];
    wire blend0_sign_s5 = pipe_s5_dout[1];
    wire blend1_sign_s5 = pipe_s5_dout[0];

    //=========================================================================
    // Restore sign and saturate
    //=========================================================================
    wire signed [SIGNED_WIDTH-1:0] blend0_div_signed = blend0_sign_s5 ? -blend0_quot : blend0_quot;
    wire signed [SIGNED_WIDTH-1:0] blend1_div_signed = blend1_sign_s5 ? -blend1_quot : blend1_quot;

    wire signed [SIGNED_WIDTH-1:0] blend0_div_comb = (blend0_div_signed > $signed(11'sd511)) ? $signed(11'sd511) :
                                                     (blend0_div_signed < $signed(-11'sd512)) ? $signed(-11'sd512) : blend0_div_signed;
    wire signed [SIGNED_WIDTH-1:0] blend1_div_comb = (blend1_div_signed > $signed(11'sd511)) ? $signed(11'sd511) :
                                                     (blend1_div_signed < $signed(-11'sd512)) ? $signed(-11'sd512) : blend1_div_signed;

    //=========================================================================
    // Output Registers
    //=========================================================================
    localparam PIPE_OUT_WIDTH = 2 * SIGNED_WIDTH + WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + DATA_WIDTH + 1;

    wire [PIPE_OUT_WIDTH-1:0] pipe_out_din = {blend0_div_comb, blend1_div_comb, win_size_s5, pixel_x_s5, pixel_y_s5, avg0_u_s5, avg1_u_s5, center_s5, div_valid};

    wire [PIPE_OUT_WIDTH-1:0] pipe_out_dout;

    common_pipe #(
        .DATA_WIDTH (PIPE_OUT_WIDTH),
        .STAGES     (1),
        .RESET_VAL  (0)
    ) u_pipe_out (
        .clk       (clk),
        .rst_n     (rst_n),
        .din       (pipe_out_din),
        .valid_in  (div_valid),
        .ready_out (),
        .dout      (pipe_out_dout),
        .valid_out (stage3_valid),
        .ready_in  (stage3_ready)
    );

    // Unpack output signals
    assign blend0_dir_avg  = pipe_out_dout[PIPE_OUT_WIDTH-1 -: SIGNED_WIDTH];
    assign blend1_dir_avg  = pipe_out_dout[PIPE_OUT_WIDTH-1-SIGNED_WIDTH -: SIGNED_WIDTH];
    assign win_size_clip_out = pipe_out_dout[WIN_SIZE_WIDTH + LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 2*SIGNED_WIDTH + DATA_WIDTH + 1 +: WIN_SIZE_WIDTH];
    assign pixel_x_out     = pipe_out_dout[LINE_ADDR_WIDTH + ROW_CNT_WIDTH + 2*SIGNED_WIDTH + DATA_WIDTH + 1 +: LINE_ADDR_WIDTH];
    assign pixel_y_out     = pipe_out_dout[ROW_CNT_WIDTH + 2*SIGNED_WIDTH + DATA_WIDTH + 1 +: ROW_CNT_WIDTH];
    assign avg0_u_out      = pipe_out_dout[2*SIGNED_WIDTH + DATA_WIDTH + 1 +: SIGNED_WIDTH];
    assign avg1_u_out      = pipe_out_dout[SIGNED_WIDTH + DATA_WIDTH + 1 +: SIGNED_WIDTH];
    assign center_pixel_out = pipe_out_dout[DATA_WIDTH + 1 +: DATA_WIDTH];

endmodule