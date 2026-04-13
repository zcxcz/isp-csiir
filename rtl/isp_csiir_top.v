//-----------------------------------------------------------------------------
// Module: isp_csiir_top
// Purpose: Top-level module for ISP-CSIIR image processing
// Author: rtl-impl
// Date: 2026-03-23
// Version: v3.0 - Added valid/ready handshake protocol for back-pressure support
//-----------------------------------------------------------------------------
// Description:
//   Top-level integration of ISP-CSIIR pipeline including:
//   - APB register configuration
//   - 5x5 line buffer with IIR feedback
//   - 4-stage processing pipeline
//   - Video stream I/O with valid/ready handshake
//
// Data Format:
//   - Line buffer storage: u10 (10-bit unsigned)
//   - Stage 1: u10 input, u10 gradient output
//   - Stage 2-4 internal: s11 (11-bit signed, zero point = 512)
//   - Final output: u10 (10-bit unsigned)
//
// Pipeline Latency:
//   - Stage 1: 5 cycles (gradient calculation + window delay)
//   - Stage 2: 4 cycles (directional average, receives delayed window from Stage 1)
//   - Stage 3: 1 row + 6 cycles (gradient fusion with row delay)
//     * Row delay enables true 3-row gradient access (grad_u, grad_c, grad_d)
//     * First row has no valid output (buffering)
//   - Stage 4: 5 cycles (IIR blend)
//   - Total: 1 row + 20 cycles from din_valid to dout_valid
//
// Handshake Protocol:
//   - din_valid/din_ready: Input handshake (back-pressure support)
//   - dout_valid/dout_ready: Output handshake (downstream back-pressure)
//   - Ready signals propagate upstream from Stage 4 -> Stage 3 -> Stage 2 -> Stage 1 -> Line Buffer
//-----------------------------------------------------------------------------

module isp_csiir_top #(
    parameter IMG_WIDTH       = 5472,
    parameter IMG_HEIGHT      = 3076,
    parameter DATA_WIDTH      = 10,
    parameter SIGNED_WIDTH    = 11,   // Signed data width
    parameter GRAD_WIDTH      = 14,
    parameter LINE_ADDR_WIDTH = 14,
    parameter ROW_CNT_WIDTH   = 13
)(
    // Clock and Reset
    input  wire                      clk,
    input  wire                      rst_n,

    // APB Configuration Interface
    input  wire                      psel,
    input  wire                      penable,
    input  wire                      pwrite,
    input  wire [7:0]                paddr,
    input  wire [31:0]               pwdata,
    output wire [31:0]               prdata,
    output wire                      pready,
    output wire                      pslverr,

    // Video Input Interface
    input  wire                      vsync,
    input  wire                      hsync,
    input  wire [DATA_WIDTH-1:0]     din,
    input  wire                      din_valid,
    output wire                      din_ready,

    // Video Output Interface
    output wire [DATA_WIDTH-1:0]     dout,
    output wire                      dout_valid,
    input  wire                      dout_ready,
    output wire                      dout_vsync,
    output wire                      dout_hsync
);

    //=========================================================================
    // Internal Signals
    //=========================================================================
    // Configuration from register block
    wire                        cfg_enable;
    wire                        cfg_bypass;
    wire [15:0]                 cfg_img_width;
    wire [15:0]                 cfg_img_height;
    wire [15:0]                 cfg_thresh0, cfg_thresh1, cfg_thresh2, cfg_thresh3;
    wire [7:0]                  cfg_ratio_0, cfg_ratio_1, cfg_ratio_2, cfg_ratio_3;
    wire [DATA_WIDTH-1:0]       cfg_clip_y_0, cfg_clip_y_1, cfg_clip_y_2, cfg_clip_y_3;
    wire [7:0]                  cfg_clip_sft_0, cfg_clip_sft_1, cfg_clip_sft_2, cfg_clip_sft_3;
    wire [31:0]                 cfg_mot_protect;

    // Line buffer interface
    wire [DATA_WIDTH-1:0]       window [0:4][0:4];
    wire                        window_valid;
    wire                        window_ready;
    wire                        window_accept_ready;
    wire                        window_row_issue_allow;
    wire                        window_valid_stage1;
    wire [LINE_ADDR_WIDTH-1:0]  center_x;
    wire [ROW_CNT_WIDTH-1:0]    center_y;
    // Column interface (for isp_csiir_gradient)
    wire [DATA_WIDTH-1:0]       lb_col_0;
    wire [DATA_WIDTH-1:0]       lb_col_1;
    wire [DATA_WIDTH-1:0]       lb_col_2;
    wire [DATA_WIDTH-1:0]       lb_col_3;
    wire [DATA_WIDTH-1:0]       lb_col_4;
    wire                        lb_column_valid;

    // Stage 1 interface
    wire [GRAD_WIDTH-1:0]       s1_grad_h, s1_grad_v, s1_grad;
    wire [5:0]                  s1_win_size_clip;
    wire                        s1_valid;
    wire                        s1_ready;
    wire [DATA_WIDTH-1:0]       s1_center_pixel;
    wire [LINE_ADDR_WIDTH-1:0]  s1_pixel_x;
    wire [ROW_CNT_WIDTH-1:0]    s1_pixel_y;

    // Stage 1 window output (delayed to align with pipeline)
    wire [DATA_WIDTH-1:0]       s1_win_0_0, s1_win_0_1, s1_win_0_2, s1_win_0_3, s1_win_0_4;
    wire [DATA_WIDTH-1:0]       s1_win_1_0, s1_win_1_1, s1_win_1_2, s1_win_1_3, s1_win_1_4;
    wire [DATA_WIDTH-1:0]       s1_win_2_0, s1_win_2_1, s1_win_2_2, s1_win_2_3, s1_win_2_4;
    wire [DATA_WIDTH-1:0]       s1_win_3_0, s1_win_3_1, s1_win_3_2, s1_win_3_3, s1_win_3_4;
    wire [DATA_WIDTH-1:0]       s1_win_4_0, s1_win_4_1, s1_win_4_2, s1_win_4_3, s1_win_4_4;
    wire [DATA_WIDTH*25-1:0]    s1_patch_5x5;

    // Stage 2 interface (s11 signed format)
    wire signed [SIGNED_WIDTH-1:0] s2_avg0_c, s2_avg0_u, s2_avg0_d, s2_avg0_l, s2_avg0_r;
    wire signed [SIGNED_WIDTH-1:0] s2_avg1_c, s2_avg1_u, s2_avg1_d, s2_avg1_l, s2_avg1_r;
    wire                        s2_valid;
    wire                        s2_ready;
    wire [GRAD_WIDTH-1:0]       s2_grad;
    wire [5:0]                  s2_win_size_clip;
    wire [DATA_WIDTH-1:0]       s2_center_pixel;
    wire [LINE_ADDR_WIDTH-1:0]  s2_pixel_x;
    wire [ROW_CNT_WIDTH-1:0]    s2_pixel_y;

    // Stage 3 interface (s11 signed format)
    wire signed [SIGNED_WIDTH-1:0] s3_blend0, s3_blend1;
    wire                        s3_valid;
    wire                        s3_ready;
    wire signed [SIGNED_WIDTH-1:0] s3_avg0_u, s3_avg1_u;
    wire [5:0]                  s3_win_size_clip;
    wire [DATA_WIDTH-1:0]       s3_center_pixel;
    wire [LINE_ADDR_WIDTH-1:0]  s3_pixel_x;
    wire [ROW_CNT_WIDTH-1:0]    s3_pixel_y;

    localparam PATCH_WIDTH = DATA_WIDTH * 25;

    // Stage 4 interface (u10 unsigned format)
    wire [PATCH_WIDTH-1:0]      s4_src_patch_5x5;
    wire [PATCH_WIDTH-1:0]      s4_src_patch_aligned;
    wire [GRAD_WIDTH-1:0]       s4_grad_h_aligned;
    wire [GRAD_WIDTH-1:0]       s4_grad_v_aligned;
    wire [DATA_WIDTH-1:0]       s4_dout;
    wire                        s4_dout_valid;
    wire [LINE_ADDR_WIDTH-1:0]  s4_pixel_x;
    wire [ROW_CNT_WIDTH-1:0]    s4_pixel_y;

    reg  [PATCH_WIDTH-1:0]      s4_meta_patch_buf_0 [0:IMG_WIDTH-1];
    reg  [PATCH_WIDTH-1:0]      s4_meta_patch_buf_1 [0:IMG_WIDTH-1];
    reg  [GRAD_WIDTH-1:0]       s4_meta_grad_h_buf_0 [0:IMG_WIDTH-1];
    reg  [GRAD_WIDTH-1:0]       s4_meta_grad_h_buf_1 [0:IMG_WIDTH-1];
    reg  [GRAD_WIDTH-1:0]       s4_meta_grad_v_buf_0 [0:IMG_WIDTH-1];
    reg  [GRAD_WIDTH-1:0]       s4_meta_grad_v_buf_1 [0:IMG_WIDTH-1];
    integer                     meta_i;

    // Line buffer writeback signals
    wire                        lb_wb_en;
    wire [LINE_ADDR_WIDTH-1:0]  lb_wb_addr;
    wire [DATA_WIDTH-1:0]       lb_wb_data;
    wire [2:0]                  lb_wb_row_offset;
    wire                        s4_patch_valid;
    wire                        s4_patch_ready;
    wire [LINE_ADDR_WIDTH-1:0]  s4_patch_center_x;
    wire [ROW_CNT_WIDTH-1:0]    s4_patch_center_y;
    wire [PATCH_WIDTH-1:0]      s4_patch_5x5;
    reg  [ROW_CNT_WIDTH-1:0]    feedback_committed_row;
    reg                         feedback_committed_valid;
    wire                        patch_feedback_fire;
    wire                        patch_row_commit_fire;
    wire [ROW_CNT_WIDTH-1:0]    max_center_y_allow;

    // Video timing signals
    wire                        sof;
    wire                        eol;
    reg                         sof_delayed;
    reg                         eol_delayed;
    reg                         vsync_delayed;
    reg                         hsync_delayed;

    // Bypass path
    reg [DATA_WIDTH-1:0]        dout_bypass;
    reg                         dout_valid_bypass;

    assign patch_feedback_fire  = s4_patch_valid && s4_patch_ready;
    assign patch_row_commit_fire = patch_feedback_fire && (s4_patch_center_x == cfg_img_width[LINE_ADDR_WIDTH-1:0] - 1'b1);
    // Front-end row credit:
    // - Only throttle new window issue at the top boundary.
    // - Keep internal column/feedback draining unblocked.
    // - Stage3 needs the next-row gradient, so the front-end must be allowed
    //   to stay one extra row ahead of the latest fully committed feedback row.
    //   Before any row commit lands, rows 0 and 1 are allowed to issue.
    assign max_center_y_allow = feedback_committed_valid ? (feedback_committed_row + 2'd2)
                                                         : {{(ROW_CNT_WIDTH-1){1'b0}}, 1'b1};
    assign window_row_issue_allow = (center_y <= max_center_y_allow);
    assign window_accept_ready = s1_ready && window_row_issue_allow;
    assign window_valid_stage1 = window_valid && window_row_issue_allow;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            feedback_committed_row <= {{(ROW_CNT_WIDTH-1){1'b0}}, 1'b0};
            feedback_committed_valid <= 1'b0;
        end else if (sof) begin
            feedback_committed_row <= {{(ROW_CNT_WIDTH-1){1'b0}}, 1'b0};
            feedback_committed_valid <= 1'b0;
        end else if (cfg_enable && !cfg_bypass && patch_row_commit_fire) begin
            feedback_committed_row <= s4_patch_center_y;
            feedback_committed_valid <= 1'b1;
        end
    end

    //=========================================================================
    // Register Block Instance
    //=========================================================================
    isp_csiir_reg_block #(
        .DATA_WIDTH    (DATA_WIDTH),
        .GRAD_WIDTH    (GRAD_WIDTH)
    ) u_reg_block (
        .clk           (clk),
        .rst_n         (rst_n),
        .psel          (psel),
        .penable       (penable),
        .pwrite        (pwrite),
        .paddr         (paddr),
        .pwdata        (pwdata),
        .prdata        (prdata),
        .pready        (pready),
        .pslverr       (pslverr),
        .enable        (cfg_enable),
        .bypass        (cfg_bypass),
        .img_width     (cfg_img_width),
        .img_height    (cfg_img_height),
        .win_size_thresh0 (cfg_thresh0),
        .win_size_thresh1 (cfg_thresh1),
        .win_size_thresh2 (cfg_thresh2),
        .win_size_thresh3 (cfg_thresh3),
        .blending_ratio_0 (cfg_ratio_0),
        .blending_ratio_1 (cfg_ratio_1),
        .blending_ratio_2 (cfg_ratio_2),
        .blending_ratio_3 (cfg_ratio_3),
        .win_size_clip_y_0 (cfg_clip_y_0),
        .win_size_clip_y_1 (cfg_clip_y_1),
        .win_size_clip_y_2 (cfg_clip_y_2),
        .win_size_clip_y_3 (cfg_clip_y_3),
        .win_size_clip_sft_0 (cfg_clip_sft_0),
        .win_size_clip_sft_1 (cfg_clip_sft_1),
        .win_size_clip_sft_2 (cfg_clip_sft_2),
        .win_size_clip_sft_3 (cfg_clip_sft_3),
        .mot_protect   (cfg_mot_protect)
    );

    //=========================================================================
    // Line Buffer Instance
    //=========================================================================
    isp_csiir_line_buffer #(
        .IMG_WIDTH     (IMG_WIDTH),
        .DATA_WIDTH    (DATA_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH)
    ) u_line_buffer (
        .clk           (clk),
        .rst_n         (rst_n),
        .enable        (cfg_enable && !cfg_bypass),
        .img_width     (cfg_img_width[LINE_ADDR_WIDTH-1:0]),
        .img_height    (cfg_img_height[ROW_CNT_WIDTH-1:0]),
        .din           (din),
        .din_valid     (din_valid),
        .din_ready     (din_ready),
        .sof           (sof),
        .eol           (eol),
        .lb_wb_en      (lb_wb_en),
        .lb_wb_data    (lb_wb_data),
        .lb_wb_addr    (lb_wb_addr),
        .lb_wb_row_offset (lb_wb_row_offset),
        .patch_valid   (s4_patch_valid),
        .patch_ready   (s4_patch_ready),
        .patch_center_x(s4_patch_center_x),
        .patch_center_y(s4_patch_center_y),
        .patch_5x5     (s4_patch_5x5),
        .max_center_y_allow(max_center_y_allow),
        .window_0_0    (window[0][0]), .window_0_1 (window[0][1]),
        .window_0_2    (window[0][2]), .window_0_3 (window[0][3]),
        .window_0_4    (window[0][4]),
        .window_1_0    (window[1][0]), .window_1_1 (window[1][1]),
        .window_1_2    (window[1][2]), .window_1_3 (window[1][3]),
        .window_1_4    (window[1][4]),
        .window_2_0    (window[2][0]), .window_2_1 (window[2][1]),
        .window_2_2    (window[2][2]), .window_2_3 (window[2][3]),
        .window_2_4    (window[2][4]),
        .window_3_0    (window[3][0]), .window_3_1 (window[3][1]),
        .window_3_2    (window[3][2]), .window_3_3 (window[3][3]),
        .window_3_4    (window[3][4]),
        .window_4_0    (window[4][0]), .window_4_1 (window[4][1]),
        .window_4_2    (window[4][2]), .window_4_3 (window[4][3]),
        .window_4_4    (window[4][4]),
        .window_valid  (window_valid),
        .window_ready  (window_accept_ready),
        .center_x      (center_x),
        .center_y      (center_y),
        // Column output (for isp_csiir_gradient)
        .lb_col_0      (lb_col_0),
        .lb_col_1      (lb_col_1),
        .lb_col_2      (lb_col_2),
        .lb_col_3      (lb_col_3),
        .lb_col_4      (lb_col_4),
        .lb_column_valid (lb_column_valid),
        .lb_column_ready (window_accept_ready)
    );

    //=========================================================================
    // Stage 1: Gradient Calculation (isp_csiir_gradient - column interface)
    //=========================================================================
    // Note: This stage uses column-based interface for modularity
    // - Receives 5x1 column from line buffer
    // - Builds 5x5 window internally
    // - Outputs column (for downstream) + computed results
    //=========================================================================
    isp_csiir_gradient #(
        .IMG_WIDTH       (IMG_WIDTH),
        .DATA_WIDTH      (DATA_WIDTH),
        .GRAD_WIDTH      (GRAD_WIDTH),
        .WIN_SIZE_WIDTH  (6),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH),
        .ROW_CNT_WIDTH   (ROW_CNT_WIDTH)
    ) u_stage1 (
        .clk           (clk),
        .rst_n         (rst_n),
        .enable        (cfg_enable && !cfg_bypass),
        // Column input from line buffer
        .col_0         (lb_col_0),
        .col_1         (lb_col_1),
        .col_2         (lb_col_2),
        .col_3         (lb_col_3),
        .col_4         (lb_col_4),
        .column_valid   (lb_column_valid),
        .column_ready   (window_ready),
        .center_x       (center_x),
        .center_y       (center_y),
        .img_width      (cfg_img_width[LINE_ADDR_WIDTH-1:0]),
        // Configuration
        .win_size_clip_y_0 (cfg_clip_y_0),
        .win_size_clip_y_1 (cfg_clip_y_1),
        .win_size_clip_y_2 (cfg_clip_y_2),
        .win_size_clip_y_3 (cfg_clip_y_3),
        .win_size_clip_sft_0 (cfg_clip_sft_0),
        .win_size_clip_sft_1 (cfg_clip_sft_1),
        .win_size_clip_sft_2 (cfg_clip_sft_2),
        .win_size_clip_sft_3 (cfg_clip_sft_3),
        // Output (computed results)
        .grad_h        (s1_grad_h),
        .grad_v        (s1_grad_v),
        .grad          (s1_grad),
        .win_size_clip (s1_win_size_clip),
        .center_pixel  (s1_center_pixel),
        .dout_valid    (s1_valid),
        .dout_ready    (s1_ready),
        // Position info
        .pixel_x_out   (s1_pixel_x),
        .pixel_y_out   (s1_pixel_y),
        // Column output (for downstream stages - TEMPORARY: using window output for now)
        // TODO: Update downstream stages to use column interface
        .out_col_0     (s1_win_0_2),  // Temporary mapping
        .out_col_1     (s1_win_1_2),  // These will be replaced
        .out_col_2     (s1_win_2_2),  // when stage2 is migrated
        .out_col_3     (s1_win_3_2),
        .out_col_4     (s1_win_4_2)
    );

    assign s1_patch_5x5 = {
        s1_win_4_4, s1_win_4_3, s1_win_4_2, s1_win_4_1, s1_win_4_0,
        s1_win_3_4, s1_win_3_3, s1_win_3_2, s1_win_3_1, s1_win_3_0,
        s1_win_2_4, s1_win_2_3, s1_win_2_2, s1_win_2_1, s1_win_2_0,
        s1_win_1_4, s1_win_1_3, s1_win_1_2, s1_win_1_1, s1_win_1_0,
        s1_win_0_4, s1_win_0_3, s1_win_0_2, s1_win_0_1, s1_win_0_0
    };

    always @(posedge clk) begin
        if (s1_valid && s1_ready) begin
            if (s1_pixel_y[0]) begin
                s4_meta_patch_buf_1[s1_pixel_x]  <= s1_patch_5x5;
                s4_meta_grad_h_buf_1[s1_pixel_x] <= s1_grad_h;
                s4_meta_grad_v_buf_1[s1_pixel_x] <= s1_grad_v;
            end else begin
                s4_meta_patch_buf_0[s1_pixel_x]  <= s1_patch_5x5;
                s4_meta_grad_h_buf_0[s1_pixel_x] <= s1_grad_h;
                s4_meta_grad_v_buf_0[s1_pixel_x] <= s1_grad_v;
            end
        end
    end

    assign s4_src_patch_aligned = s3_pixel_y[0] ? s4_meta_patch_buf_1[s3_pixel_x] : s4_meta_patch_buf_0[s3_pixel_x];
    assign s4_grad_h_aligned    = s3_pixel_y[0] ? s4_meta_grad_h_buf_1[s3_pixel_x] : s4_meta_grad_h_buf_0[s3_pixel_x];
    assign s4_grad_v_aligned    = s3_pixel_y[0] ? s4_meta_grad_v_buf_1[s3_pixel_x] : s4_meta_grad_v_buf_0[s3_pixel_x];

    //=========================================================================
    // Stage 2: Directional Average (u10 -> s11 conversion)
    //=========================================================================
    // Window input comes from Stage 1 output (already delayed 5 cycles)
    stage2_directional_avg #(
        .DATA_WIDTH    (DATA_WIDTH),
        .SIGNED_WIDTH  (SIGNED_WIDTH),
        .GRAD_WIDTH    (GRAD_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH),
        .ROW_CNT_WIDTH (ROW_CNT_WIDTH)
    ) u_stage2 (
        .clk           (clk),
        .rst_n         (rst_n),
        .enable        (cfg_enable && !cfg_bypass),
        // Window from Stage 1 output (delayed to align with pipeline)
        .window_0_0    (s1_win_0_0), .window_0_1 (s1_win_0_1),
        .window_0_2    (s1_win_0_2), .window_0_3 (s1_win_0_3),
        .window_0_4    (s1_win_0_4),
        .window_1_0    (s1_win_1_0), .window_1_1 (s1_win_1_1),
        .window_1_2    (s1_win_1_2), .window_1_3 (s1_win_1_3),
        .window_1_4    (s1_win_1_4),
        .window_2_0    (s1_win_2_0), .window_2_1 (s1_win_2_1),
        .window_2_2    (s1_win_2_2), .window_2_3 (s1_win_2_3),
        .window_2_4    (s1_win_2_4),
        .window_3_0    (s1_win_3_0), .window_3_1 (s1_win_3_1),
        .window_3_2    (s1_win_3_2), .window_3_3 (s1_win_3_3),
        .window_3_4    (s1_win_3_4),
        .window_4_0    (s1_win_4_0), .window_4_1 (s1_win_4_1),
        .window_4_2    (s1_win_4_2), .window_4_3 (s1_win_4_3),
        .window_4_4    (s1_win_4_4),
        .grad_h        (s1_grad_h),
        .grad_v        (s1_grad_v),
        .grad          (s1_grad),
        .win_size_clip (s1_win_size_clip),
        .stage1_valid  (s1_valid),
        .stage1_ready  (s1_ready),
        .center_pixel  (s1_center_pixel),
        .win_size_thresh0 (cfg_thresh0),
        .win_size_thresh1 (cfg_thresh1),
        .win_size_thresh2 (cfg_thresh2),
        .win_size_thresh3 (cfg_thresh3),
        .avg0_c        (s2_avg0_c), .avg0_u (s2_avg0_u), .avg0_d (s2_avg0_d),
        .avg0_l        (s2_avg0_l), .avg0_r (s2_avg0_r),
        .avg1_c        (s2_avg1_c), .avg1_u (s2_avg1_u), .avg1_d (s2_avg1_d),
        .avg1_l        (s2_avg1_l), .avg1_r (s2_avg1_r),
        .stage2_valid  (s2_valid),
        .stage2_ready  (s2_ready),
        .pixel_x       (s1_pixel_x),
        .pixel_y       (s1_pixel_y),
        .pixel_x_out   (s2_pixel_x),
        .pixel_y_out   (s2_pixel_y),
        .grad_out      (s2_grad),
        .win_size_clip_out (s2_win_size_clip),
        .center_pixel_out (s2_center_pixel)
    );

    //=========================================================================
    // Stage 3: Gradient Fusion (s11 signed)
    //=========================================================================
    stage3_gradient_fusion #(
        .DATA_WIDTH    (DATA_WIDTH),
        .SIGNED_WIDTH  (SIGNED_WIDTH),
        .GRAD_WIDTH    (GRAD_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH),
        .ROW_CNT_WIDTH (ROW_CNT_WIDTH),
        .IMG_WIDTH     (IMG_WIDTH)
    ) u_stage3 (
        .clk           (clk),
        .rst_n         (rst_n),
        .enable        (cfg_enable && !cfg_bypass),
        .avg0_c        (s2_avg0_c), .avg0_u (s2_avg0_u), .avg0_d (s2_avg0_d),
        .avg0_l        (s2_avg0_l), .avg0_r (s2_avg0_r),
        .avg1_c        (s2_avg1_c), .avg1_u (s2_avg1_u), .avg1_d (s2_avg1_d),
        .avg1_l        (s2_avg1_l), .avg1_r (s2_avg1_r),
        .stage2_valid  (s2_valid),
        .stage2_ready  (s2_ready),
        .grad          (s2_grad),
        .win_size_clip (s2_win_size_clip),
        .center_pixel  (s2_center_pixel),
        .img_height    (cfg_img_height[ROW_CNT_WIDTH-1:0]),
        .img_width     (cfg_img_width[LINE_ADDR_WIDTH-1:0]),
        .blend0_dir_avg (s3_blend0),
        .blend1_dir_avg (s3_blend1),
        .stage3_valid  (s3_valid),
        .stage3_ready  (s3_ready),
        .pixel_x       (s2_pixel_x),
        .pixel_y       (s2_pixel_y),
        .pixel_x_out   (s3_pixel_x),
        .pixel_y_out   (s3_pixel_y),
        .avg0_u_out    (s3_avg0_u),
        .avg1_u_out    (s3_avg1_u),
        .win_size_clip_out (s3_win_size_clip),
        .center_pixel_out (s3_center_pixel)
    );

    //=========================================================================
    // Stage 4: IIR Blend (s11 -> u10 conversion)
    //=========================================================================
    stage4_iir_blend #(
        .DATA_WIDTH    (DATA_WIDTH),
        .SIGNED_WIDTH  (SIGNED_WIDTH),
        .GRAD_WIDTH    (GRAD_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH),
        .ROW_CNT_WIDTH (ROW_CNT_WIDTH)
    ) u_stage4 (
        .clk           (clk),
        .rst_n         (rst_n),
        .enable        (cfg_enable && !cfg_bypass),
        .blend0_dir_avg (s3_blend0),
        .blend1_dir_avg (s3_blend1),
        .stage3_valid  (s3_valid),
        .avg0_u        (s3_avg0_u),
        .avg1_u        (s3_avg1_u),
        .win_size_clip (s3_win_size_clip),
        .src_patch_5x5 (s4_src_patch_aligned),
        .grad_h        (s4_grad_h_aligned),
        .grad_v        (s4_grad_v_aligned),
        .reg_edge_protect (cfg_mot_protect[7:0]),
        .center_pixel  (s3_center_pixel),
        .stage3_ready  (s3_ready),
        .blending_ratio_0 (cfg_ratio_0),
        .blending_ratio_1 (cfg_ratio_1),
        .blending_ratio_2 (cfg_ratio_2),
        .blending_ratio_3 (cfg_ratio_3),
        .dout          (s4_dout),
        .dout_valid    (s4_dout_valid),
        .dout_ready    (dout_ready),
        .pixel_x       (s3_pixel_x),
        .pixel_y       (s3_pixel_y),
        .pixel_x_out   (s4_pixel_x),
        .pixel_y_out   (s4_pixel_y),
        .patch_valid   (s4_patch_valid),
        .patch_ready   (s4_patch_ready),
        .patch_center_x(s4_patch_center_x),
        .patch_center_y(s4_patch_center_y),
        .patch_5x5     (s4_patch_5x5),
        .lb_wb_en      (),
        .lb_wb_addr    (),
        .lb_wb_data    ()
    );

    // Legacy single-pixel writeback path is disabled in favor of patch feedback.
    // Keep the signals tied off so older debug hooks still compile.
    assign lb_wb_en = 1'b0;
    assign lb_wb_addr = {LINE_ADDR_WIDTH{1'b0}};
    assign lb_wb_data = {DATA_WIDTH{1'b0}};
    assign lb_wb_row_offset = 3'd0;

    //=========================================================================
    // Video Timing Generation
    //=========================================================================
    // Detect start of frame and end of line
    assign sof = vsync && !sof_delayed;
    assign eol = !hsync && hsync_delayed;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sof_delayed   <= 1'b0;
            eol_delayed   <= 1'b0;
            vsync_delayed <= 1'b0;
            hsync_delayed <= 1'b0;
        end else begin
            sof_delayed   <= vsync;
            eol_delayed   <= !hsync;
            vsync_delayed <= vsync;
            hsync_delayed <= hsync;
        end
    end

    //=========================================================================
    // Bypass Path
    //=========================================================================
    // Delay for bypass path alignment (approximately 24 cycles)
    reg [DATA_WIDTH-1:0] bypass_din [0:23];
    reg                  bypass_valid [0:23];
    reg                  bypass_hsync [0:23];
    reg                  bypass_vsync [0:23];

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 24; i = i + 1) begin
                bypass_din[i]   <= {DATA_WIDTH{1'b0}};
                bypass_valid[i] <= 1'b0;
                bypass_hsync[i] <= 1'b0;
                bypass_vsync[i] <= 1'b0;
            end
        end else begin
            bypass_din[0]   <= din;
            bypass_valid[0] <= din_valid;
            bypass_hsync[0] <= hsync;
            bypass_vsync[0] <= vsync;
            for (i = 1; i < 24; i = i + 1) begin
                bypass_din[i]   <= bypass_din[i-1];
                bypass_valid[i] <= bypass_valid[i-1];
                bypass_hsync[i] <= bypass_hsync[i-1];
                bypass_vsync[i] <= bypass_vsync[i-1];
            end
        end
    end

    //=========================================================================
    // Output Multiplexer
    //=========================================================================
    assign dout = cfg_bypass ? bypass_din[23] : s4_dout;
    assign dout_valid = cfg_bypass ? bypass_valid[23] : s4_dout_valid;
    assign dout_hsync = cfg_bypass ? bypass_hsync[23] : 1'b0;  // TODO: generate from pipeline
    assign dout_vsync = cfg_bypass ? bypass_vsync[23] : 1'b0;  // TODO: generate from pipeline

endmodule
