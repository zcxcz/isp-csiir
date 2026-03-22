//-----------------------------------------------------------------------------
// Module: isp_csiir_top
// Purpose: Top-level module for ISP-CSIIR image processing
// Author: rtl-impl
// Date: 2026-03-22
// Version: v1.0
//-----------------------------------------------------------------------------
// Description:
//   Top-level integration of ISP-CSIIR pipeline including:
//   - APB register configuration
//   - 5x5 line buffer with IIR feedback
//   - 4-stage processing pipeline
//   - Video stream I/O
//
// Pipeline Latency: 24 cycles (from din_valid to dout_valid)
//   - Stage 1: 5 cycles (gradient calculation)
//   - Stage 2: 8 cycles (directional average)
//   - Stage 3: 6 cycles (gradient fusion)
//   - Stage 4: 5 cycles (IIR blend)
//-----------------------------------------------------------------------------

module isp_csiir_top #(
    parameter IMG_WIDTH       = 5472,
    parameter IMG_HEIGHT      = 3076,
    parameter DATA_WIDTH      = 10,
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

    // Video Output Interface
    output wire [DATA_WIDTH-1:0]     dout,
    output wire                      dout_valid,
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

    // Line buffer interface
    wire [DATA_WIDTH-1:0]       window [0:4][0:4];
    wire                        window_valid;
    wire [LINE_ADDR_WIDTH-1:0]  center_x;
    wire [ROW_CNT_WIDTH-1:0]    center_y;

    // Stage 1 interface
    wire [GRAD_WIDTH-1:0]       s1_grad_h, s1_grad_v, s1_grad;
    wire [5:0]                  s1_win_size_clip;
    wire                        s1_valid;
    wire [DATA_WIDTH-1:0]       s1_center_pixel;
    wire [LINE_ADDR_WIDTH-1:0]  s1_pixel_x;
    wire [ROW_CNT_WIDTH-1:0]    s1_pixel_y;

    // Stage 2 interface
    wire [DATA_WIDTH-1:0]       s2_avg0_c, s2_avg0_u, s2_avg0_d, s2_avg0_l, s2_avg0_r;
    wire [DATA_WIDTH-1:0]       s2_avg1_c, s2_avg1_u, s2_avg1_d, s2_avg1_l, s2_avg1_r;
    wire                        s2_valid;
    wire [GRAD_WIDTH-1:0]       s2_grad;
    wire [5:0]                  s2_win_size_clip;
    wire [DATA_WIDTH-1:0]       s2_center_pixel;
    wire [LINE_ADDR_WIDTH-1:0]  s2_pixel_x;
    wire [ROW_CNT_WIDTH-1:0]    s2_pixel_y;

    // Stage 3 interface
    wire [DATA_WIDTH-1:0]       s3_blend0, s3_blend1;
    wire                        s3_valid;
    wire [DATA_WIDTH-1:0]       s3_avg0_u, s3_avg1_u;
    wire [5:0]                  s3_win_size_clip;
    wire [DATA_WIDTH-1:0]       s3_center_pixel;
    wire [LINE_ADDR_WIDTH-1:0]  s3_pixel_x;
    wire [ROW_CNT_WIDTH-1:0]    s3_pixel_y;

    // Stage 4 interface
    wire [DATA_WIDTH-1:0]       s4_dout;
    wire                        s4_dout_valid;
    wire [LINE_ADDR_WIDTH-1:0]  s4_pixel_x;
    wire [ROW_CNT_WIDTH-1:0]    s4_pixel_y;

    // IIR feedback signals
    wire                        iir_wb_en;
    wire [LINE_ADDR_WIDTH-1:0]  iir_wb_addr;
    wire [DATA_WIDTH-1:0]       iir_wb_data;
    wire [2:0]                  iir_wb_row_offset;

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
        .win_size_clip_sft_0 (),
        .win_size_clip_sft_1 (),
        .win_size_clip_sft_2 (),
        .win_size_clip_sft_3 (),
        .mot_protect   ()
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
        .din           (din),
        .din_valid     (din_valid),
        .sof           (sof),
        .eol           (eol),
        .iir_wb_en     (iir_wb_en),
        .iir_wb_data   (iir_wb_data),
        .iir_wb_addr   (iir_wb_addr),
        .iir_wb_row_offset (iir_wb_row_offset),
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
        .center_x      (center_x),
        .center_y      (center_y)
    );

    //=========================================================================
    // Stage 1: Gradient Calculation
    //=========================================================================
    stage1_gradient #(
        .DATA_WIDTH    (DATA_WIDTH),
        .GRAD_WIDTH    (GRAD_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH),
        .ROW_CNT_WIDTH (ROW_CNT_WIDTH)
    ) u_stage1 (
        .clk           (clk),
        .rst_n         (rst_n),
        .enable        (cfg_enable && !cfg_bypass),
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
        .win_size_clip_y_0 (cfg_clip_y_0),
        .win_size_clip_y_1 (cfg_clip_y_1),
        .win_size_clip_y_2 (cfg_clip_y_2),
        .win_size_clip_y_3 (cfg_clip_y_3),
        .grad_h        (s1_grad_h),
        .grad_v        (s1_grad_v),
        .grad          (s1_grad),
        .win_size_clip (s1_win_size_clip),
        .stage1_valid  (s1_valid),
        .pixel_x       (center_x),
        .pixel_y       (center_y),
        .pixel_x_out   (s1_pixel_x),
        .pixel_y_out   (s1_pixel_y),
        .center_pixel  (s1_center_pixel)
    );

    //=========================================================================
    // Stage 2: Directional Average
    //=========================================================================
    stage2_directional_avg #(
        .DATA_WIDTH    (DATA_WIDTH),
        .GRAD_WIDTH    (GRAD_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH),
        .ROW_CNT_WIDTH (ROW_CNT_WIDTH)
    ) u_stage2 (
        .clk           (clk),
        .rst_n         (rst_n),
        .enable        (cfg_enable && !cfg_bypass),
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
        .grad_h        (s1_grad_h),
        .grad_v        (s1_grad_v),
        .grad          (s1_grad),
        .win_size_clip (s1_win_size_clip),
        .stage1_valid  (s1_valid),
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
        .pixel_x       (s1_pixel_x),
        .pixel_y       (s1_pixel_y),
        .pixel_x_out   (s2_pixel_x),
        .pixel_y_out   (s2_pixel_y),
        .grad_out      (s2_grad),
        .win_size_clip_out (s2_win_size_clip),
        .center_pixel_out (s2_center_pixel)
    );

    //=========================================================================
    // Stage 3: Gradient Fusion
    //=========================================================================
    stage3_gradient_fusion #(
        .DATA_WIDTH    (DATA_WIDTH),
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
        .grad          (s2_grad),
        .win_size_clip (s2_win_size_clip),
        .center_pixel  (s2_center_pixel),
        .img_height    (cfg_img_height[ROW_CNT_WIDTH-1:0]),
        .img_width     (cfg_img_width[LINE_ADDR_WIDTH-1:0]),
        .blend0_dir_avg (s3_blend0),
        .blend1_dir_avg (s3_blend1),
        .stage3_valid  (s3_valid),
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
    // Stage 4: IIR Blend
    //=========================================================================
    stage4_iir_blend #(
        .DATA_WIDTH    (DATA_WIDTH),
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
        .center_pixel  (s3_center_pixel),
        .blending_ratio_0 (cfg_ratio_0),
        .blending_ratio_1 (cfg_ratio_1),
        .blending_ratio_2 (cfg_ratio_2),
        .blending_ratio_3 (cfg_ratio_3),
        .dout          (s4_dout),
        .dout_valid    (s4_dout_valid),
        .pixel_x       (s3_pixel_x),
        .pixel_y       (s3_pixel_y),
        .pixel_x_out   (s4_pixel_x),
        .pixel_y_out   (s4_pixel_y),
        .iir_wb_en     (iir_wb_en),
        .iir_wb_addr   (iir_wb_addr),
        .iir_wb_data   (iir_wb_data)
    );

    // IIR writeback row offset (currently not used, set to 0)
    assign iir_wb_row_offset = 3'd0;

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