//-----------------------------------------------------------------------------
// Module: isp_csiir_top
// Description: Top module integrating all ISP-CSIIR pipeline stages
//              Pure Verilog-2001 compatible
//              Supports configurable resolution and data width
//              Single-channel processing (instantiate multiple for YUV)
//-----------------------------------------------------------------------------

module isp_csiir_top #(
    // Image dimensions (configurable for different resolutions)
    parameter IMG_WIDTH    = 5472,                      // 8K width
    parameter IMG_HEIGHT   = 3076,                      // 8K height
    parameter DATA_WIDTH   = 10,                        // 10-bit per channel
    parameter GRAD_WIDTH   = 14,                        // Gradient width (DATA_WIDTH + margin)
    parameter LINE_ADDR_WIDTH = 14,                     // log2(IMG_WIDTH) + margin
    parameter ROW_CNT_WIDTH = 13                        // log2(IMG_HEIGHT) + margin
)(
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

    `include "isp_csiir_defines.vh"

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam WIN_SIZE_WIDTH = 6;
    localparam ACC_WIDTH = DATA_WIDTH + 10;
    localparam PIC_WIDTH_BITS = $clog2(IMG_WIDTH) + 1;
    localparam PIC_HEIGHT_BITS = $clog2(IMG_HEIGHT) + 1;

    //=========================================================================
    // Register Block Signals
    //=========================================================================
    wire [PIC_WIDTH_BITS-1:0]  pic_width_m1;
    wire [PIC_HEIGHT_BITS-1:0] pic_height_m1;
    wire [15:0] win_size_thresh0;
    wire [15:0] win_size_thresh1;
    wire [15:0] win_size_thresh2;
    wire [15:0] win_size_thresh3;
    wire [7:0]  blending_ratio_0;
    wire [7:0]  blending_ratio_1;
    wire [7:0]  blending_ratio_2;
    wire [7:0]  blending_ratio_3;
    wire [DATA_WIDTH-1:0] win_size_clip_y_0;
    wire [DATA_WIDTH-1:0] win_size_clip_y_1;
    wire [DATA_WIDTH-1:0] win_size_clip_y_2;
    wire [DATA_WIDTH-1:0] win_size_clip_y_3;
    wire [7:0]  win_size_clip_sft_0;
    wire [7:0]  win_size_clip_sft_1;
    wire [7:0]  win_size_clip_sft_2;
    wire [7:0]  win_size_clip_sft_3;
    wire [7:0]  mot_protect_0;
    wire [7:0]  mot_protect_1;
    wire [7:0]  mot_protect_2;
    wire [7:0]  mot_protect_3;
    wire        enable;
    wire        bypass;
    wire        regs_updated;

    //=========================================================================
    // IIR Feedback Signals
    //=========================================================================
    // Pipeline delay for column tracking (for IIR feedback)
    // Track the column index delayed by pipeline stages
    localparam PIPELINE_DELAY = 17;  // Total pipeline cycles

    reg [LINE_ADDR_WIDTH-1:0] col_delay [0:PIPELINE_DELAY-1];
    reg [PIPELINE_DELAY-1:0]  valid_delay;
    reg [ROW_CNT_WIDTH-1:0]   row_delay [0:PIPELINE_DELAY-1];

    wire [LINE_ADDR_WIDTH-1:0] iir_feedback_col;
    wire                       iir_feedback_valid;

    //=========================================================================
    // Video Timing Signals (declared early for use in delay chain)
    //=========================================================================
    reg                   sof_reg;
    reg                   eol_reg;
    reg [PIC_WIDTH_BITS-1:0]  pixel_x;
    reg [PIC_HEIGHT_BITS-1:0] pixel_y;
    reg [PIC_WIDTH_BITS-1:0]  pixel_cnt;
    reg [PIC_HEIGHT_BITS-1:0] line_cnt;
    reg                   vsync_d1, vsync_d2;
    reg                   hsync_d1, hsync_d2;

    //=========================================================================
    // Line Buffer Window Outputs
    //=========================================================================
    wire [DATA_WIDTH-1:0] window_0_0, window_0_1, window_0_2, window_0_3, window_0_4;
    wire [DATA_WIDTH-1:0] window_1_0, window_1_1, window_1_2, window_1_3, window_1_4;
    wire [DATA_WIDTH-1:0] window_2_0, window_2_1, window_2_2, window_2_3, window_2_4;
    wire [DATA_WIDTH-1:0] window_3_0, window_3_1, window_3_2, window_3_3, window_3_4;
    wire [DATA_WIDTH-1:0] window_4_0, window_4_1, window_4_2, window_4_3, window_4_4;
    wire                  window_valid;

    // Window center position from line buffer (tracks the center of 5x5 window)
    wire [LINE_ADDR_WIDTH-1:0] window_center_x;
    wire [ROW_CNT_WIDTH-1:0]   window_center_y;

    //=========================================================================
    // Stage 1 Outputs
    //=========================================================================
    wire [GRAD_WIDTH-1:0]          grad_h_s1;
    wire [GRAD_WIDTH-1:0]          grad_v_s1;
    wire [GRAD_WIDTH-1:0]          grad_s1;
    wire [WIN_SIZE_WIDTH-1:0]      win_size_clip_s1;
    wire                           stage1_valid;
    // Pipelined window center position from Stage 1
    wire [PIC_WIDTH_BITS-1:0]      center_x_s1;
    wire [PIC_HEIGHT_BITS-1:0]     center_y_s1;

    //=========================================================================
    // Stage 2 Outputs
    //=========================================================================
    wire [DATA_WIDTH-1:0] avg0_c, avg0_u, avg0_d, avg0_l, avg0_r;
    wire [DATA_WIDTH-1:0] avg1_c, avg1_u, avg1_d, avg1_l, avg1_r;
    wire                  stage2_valid;
    // New outputs: pipelined center pixel and win_size from Stage 2
    wire [DATA_WIDTH-1:0]     center_pixel_s2_out;
    wire [WIN_SIZE_WIDTH-1:0] win_size_s2_out;
    // Position outputs from Stage 2
    wire [13:0]               pixel_x_s2;
    wire [12:0]               pixel_y_s2;

    //=========================================================================
    // Stage 3 Outputs
    //=========================================================================
    wire [DATA_WIDTH-1:0] blend0_dir_avg;
    wire [DATA_WIDTH-1:0] blend1_dir_avg;
    wire                  stage3_valid;
    // Position outputs from Stage 3
    wire [PIC_WIDTH_BITS-1:0]  pixel_x_s3;
    wire [PIC_HEIGHT_BITS-1:0] pixel_y_s3;
    // avg0_u and avg1_u outputs from Stage 3 (pipelined for Stage 4 IIR)
    wire [DATA_WIDTH-1:0] avg0_u_s3_out;
    wire [DATA_WIDTH-1:0] avg1_u_s3_out;
    // Center pixel and win_size outputs from Stage 3 (pipelined for Stage 4)
    wire [DATA_WIDTH-1:0] center_pixel_s3_out;
    wire [5:0]            win_size_clip_s3_out;

    //=========================================================================
    // Gradient Delay Pipeline (to match Stage 2 latency)
    // Stage 2 has 5 cycles of latency from stage1_valid to stage2_valid
    // We need to delay grad signals to align with avg signals
    // IMPORTANT: Shift every cycle to allow valid data to propagate through
    //=========================================================================
    reg [GRAD_WIDTH-1:0] grad_delay [0:5];
    reg [GRAD_WIDTH-1:0] grad_h_delay [0:5];
    reg [GRAD_WIDTH-1:0] grad_v_delay [0:5];
    reg [PIC_WIDTH_BITS-1:0] pixel_x_delay [0:5];
    reg [PIC_HEIGHT_BITS-1:0] pixel_y_delay [0:5];

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k <= 5; k = k + 1) begin
                grad_delay[k] <= {GRAD_WIDTH{1'b0}};
                grad_h_delay[k] <= {GRAD_WIDTH{1'b0}};
                grad_v_delay[k] <= {GRAD_WIDTH{1'b0}};
                pixel_x_delay[k] <= {PIC_WIDTH_BITS{1'b0}};
                pixel_y_delay[k] <= {PIC_HEIGHT_BITS{1'b0}};
            end
        end else if (enable) begin
            // Always shift to allow valid data to propagate through the pipeline
            // Input new data when stage1_valid fires, otherwise input 0
            grad_delay[0] <= stage1_valid ? grad_s1 : {GRAD_WIDTH{1'b0}};
            grad_h_delay[0] <= stage1_valid ? grad_h_s1 : {GRAD_WIDTH{1'b0}};
            grad_v_delay[0] <= stage1_valid ? grad_v_s1 : {GRAD_WIDTH{1'b0}};
            pixel_x_delay[0] <= stage1_valid ? center_x_s1 : {PIC_WIDTH_BITS{1'b0}};
            pixel_y_delay[0] <= stage1_valid ? center_y_s1 : {PIC_HEIGHT_BITS{1'b0}};
            for (k = 1; k <= 5; k = k + 1) begin
                grad_delay[k] <= grad_delay[k-1];
                grad_h_delay[k] <= grad_h_delay[k-1];
                grad_v_delay[k] <= grad_v_delay[k-1];
                pixel_x_delay[k] <= pixel_x_delay[k-1];
                pixel_y_delay[k] <= pixel_y_delay[k-1];
            end
        end
    end

    //=========================================================================
    // Delay chains for Stage 4 inputs (must match Stage 3 pipeline depth)
    // Stage 3 has 4 pipeline stages with valid gating
    //=========================================================================
    reg [DATA_WIDTH-1:0]     avg0_u_s1, avg0_u_s2, avg0_u_s3, avg0_u_s4;
    reg [DATA_WIDTH-1:0]     avg1_u_s1, avg1_u_s2, avg1_u_s3, avg1_u_s4;
    reg [DATA_WIDTH-1:0]     center_s1, center_s2, center_s3, center_s4;
    reg [WIN_SIZE_WIDTH-1:0] win_size_s1, win_size_s2, win_size_s3, win_size_s4;
    reg                      delay_valid_s1, delay_valid_s2, delay_valid_s3, delay_valid_s4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            avg0_u_s1 <= {DATA_WIDTH{1'b0}};
            avg0_u_s2 <= {DATA_WIDTH{1'b0}};
            avg0_u_s3 <= {DATA_WIDTH{1'b0}};
            avg0_u_s4 <= {DATA_WIDTH{1'b0}};
            avg1_u_s1 <= {DATA_WIDTH{1'b0}};
            avg1_u_s2 <= {DATA_WIDTH{1'b0}};
            avg1_u_s3 <= {DATA_WIDTH{1'b0}};
            avg1_u_s4 <= {DATA_WIDTH{1'b0}};
            center_s1 <= {DATA_WIDTH{1'b0}};
            center_s2 <= {DATA_WIDTH{1'b0}};
            center_s3 <= {DATA_WIDTH{1'b0}};
            center_s4 <= {DATA_WIDTH{1'b0}};
            win_size_s1 <= {WIN_SIZE_WIDTH{1'b0}};
            win_size_s2 <= {WIN_SIZE_WIDTH{1'b0}};
            win_size_s3 <= {WIN_SIZE_WIDTH{1'b0}};
            win_size_s4 <= {WIN_SIZE_WIDTH{1'b0}};
            delay_valid_s1 <= 1'b0;
            delay_valid_s2 <= 1'b0;
            delay_valid_s3 <= 1'b0;
            delay_valid_s4 <= 1'b0;
        end else if (enable && !bypass) begin
            // Stage 1: capture when stage2_valid fires
            // Use the properly pipelined center_pixel and win_size from Stage 2
            if (stage2_valid) begin
                avg0_u_s1 <= avg0_u;
                avg1_u_s1 <= avg1_u;
                center_s1 <= center_pixel_s2_out;  // Use pipelined center from Stage 2
                win_size_s1 <= win_size_s2_out;     // Use pipelined win_size from Stage 2
                delay_valid_s1 <= 1'b1;
            end else begin
                delay_valid_s1 <= 1'b0;
            end

            // Stage 2: shift only when s1 was valid
            if (delay_valid_s1) begin
                avg0_u_s2 <= avg0_u_s1;
                avg1_u_s2 <= avg1_u_s1;
                center_s2 <= center_s1;
                win_size_s2 <= win_size_s1;
                delay_valid_s2 <= 1'b1;
            end else begin
                delay_valid_s2 <= 1'b0;
            end

            // Stage 3: shift only when s2 was valid
            if (delay_valid_s2) begin
                avg0_u_s3 <= avg0_u_s2;
                avg1_u_s3 <= avg1_u_s2;
                center_s3 <= center_s2;
                win_size_s3 <= win_size_s2;
                delay_valid_s3 <= 1'b1;
            end else begin
                delay_valid_s3 <= 1'b0;
            end

            // Stage 4: shift only when s3 was valid
            if (delay_valid_s3) begin
                avg0_u_s4 <= avg0_u_s3;
                avg1_u_s4 <= avg1_u_s3;
                center_s4 <= center_s3;
                win_size_s4 <= win_size_s3;
                delay_valid_s4 <= 1'b1;
            end else begin
                delay_valid_s4 <= 1'b0;
            end
        end
    end

    //=========================================================================
    // Stage 4 Outputs (Final)
    //=========================================================================
    wire [DATA_WIDTH-1:0] dout_final;
    wire                  dout_final_valid;
    // Position outputs from Stage 4
    wire [13:0]           pixel_x_final;
    wire [12:0]           pixel_y_final;

    //=========================================================================
    // Bypass Path
    //=========================================================================
    reg [DATA_WIDTH-1:0]  din_delay [0:20];
    reg [20:0]            din_valid_delay;
    reg                   vsync_delay [0:20];
    reg                   hsync_delay [0:20];
    integer               i;

    //=========================================================================
    // Boundary Mode
    //=========================================================================
    wire [1:0]            boundary_mode = 2'b01;  // Replicate mode

    // Delay chain for column tracking
    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (j = 0; j < PIPELINE_DELAY; j = j + 1) begin
                col_delay[j]  <= {LINE_ADDR_WIDTH{1'b0}};
                row_delay[j]  <= {ROW_CNT_WIDTH{1'b0}};
                valid_delay[j] <= 1'b0;
            end
        end else if (enable && !bypass) begin
            col_delay[0]  <= pixel_cnt;
            row_delay[0]  <= line_cnt;
            valid_delay[0] <= din_valid;
            for (j = 1; j < PIPELINE_DELAY; j = j + 1) begin
                col_delay[j]  <= col_delay[j-1];
                row_delay[j]  <= row_delay[j-1];
                valid_delay[j] <= valid_delay[j-1];
            end
        end
    end

    assign iir_feedback_col   = col_delay[PIPELINE_DELAY-1];
    assign iir_feedback_valid = dout_final_valid;

    //=========================================================================
    // Register Block Instance
    //=========================================================================
    isp_csiir_reg_block #(
        .APB_ADDR_WIDTH(8),
        .PIC_WIDTH_BITS(PIC_WIDTH_BITS),
        .PIC_HEIGHT_BITS(PIC_HEIGHT_BITS),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_reg_block (
        .clk              (clk),
        .rst_n            (rst_n),
        .psel             (psel),
        .penable          (penable),
        .pwrite           (pwrite),
        .paddr            (paddr),
        .pwdata           (pwdata),
        .prdata           (prdata),
        .pready           (pready),
        .pslverr          (pslverr),
        .pic_width_m1     (pic_width_m1),
        .pic_height_m1    (pic_height_m1),
        .win_size_thresh0 (win_size_thresh0),
        .win_size_thresh1 (win_size_thresh1),
        .win_size_thresh2 (win_size_thresh2),
        .win_size_thresh3 (win_size_thresh3),
        .blending_ratio_0 (blending_ratio_0),
        .blending_ratio_1 (blending_ratio_1),
        .blending_ratio_2 (blending_ratio_2),
        .blending_ratio_3 (blending_ratio_3),
        .win_size_clip_y_0(win_size_clip_y_0),
        .win_size_clip_y_1(win_size_clip_y_1),
        .win_size_clip_y_2(win_size_clip_y_2),
        .win_size_clip_y_3(win_size_clip_y_3),
        .win_size_clip_sft_0(win_size_clip_sft_0),
        .win_size_clip_sft_1(win_size_clip_sft_1),
        .win_size_clip_sft_2(win_size_clip_sft_2),
        .win_size_clip_sft_3(win_size_clip_sft_3),
        .mot_protect_0    (mot_protect_0),
        .mot_protect_1    (mot_protect_1),
        .mot_protect_2    (mot_protect_2),
        .mot_protect_3    (mot_protect_3),
        .enable           (enable),
        .bypass           (bypass),
        .regs_updated     (regs_updated)
    );

    //=========================================================================
    // Video Timing Generation
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_d1 <= 1'b0;
            vsync_d2 <= 1'b0;
            hsync_d1 <= 1'b0;
            hsync_d2 <= 1'b0;
            sof_reg  <= 1'b0;
            eol_reg  <= 1'b0;
            pixel_x  <= {PIC_WIDTH_BITS{1'b0}};
            pixel_y  <= {PIC_HEIGHT_BITS{1'b0}};
            pixel_cnt <= {PIC_WIDTH_BITS{1'b0}};
            line_cnt <= {PIC_HEIGHT_BITS{1'b0}};
        end else begin
            vsync_d1 <= vsync;
            vsync_d2 <= vsync_d1;
            hsync_d1 <= hsync;
            hsync_d2 <= hsync_d1;

            // Detect start of frame (rising edge of vsync)
            sof_reg <= vsync_d1 && !vsync_d2;

            // Detect end of line (rising edge of hsync or end of line count)
            eol_reg <= (hsync_d1 && !hsync_d2) || (pixel_cnt >= pic_width_m1);

            // Pixel and line counters
            if (sof_reg) begin
                pixel_cnt <= {PIC_WIDTH_BITS{1'b0}};
                line_cnt <= {PIC_HEIGHT_BITS{1'b0}};
                pixel_x <= {PIC_WIDTH_BITS{1'b0}};
                pixel_y <= {PIC_HEIGHT_BITS{1'b0}};
            end else if (din_valid) begin
                if (pixel_cnt >= pic_width_m1) begin
                    pixel_cnt <= {PIC_WIDTH_BITS{1'b0}};
                    pixel_x <= {PIC_WIDTH_BITS{1'b0}};
                    if (line_cnt < pic_height_m1)
                        line_cnt <= line_cnt + {{PIC_HEIGHT_BITS-1{1'b0}}, 1'b1};
                    pixel_y <= line_cnt + {{PIC_HEIGHT_BITS-1{1'b0}}, 1'b1};
                end else begin
                    pixel_cnt <= pixel_cnt + {{PIC_WIDTH_BITS-1{1'b0}}, 1'b1};
                    pixel_x <= pixel_cnt + {{PIC_WIDTH_BITS-1{1'b0}}, 1'b1};
                end
            end
        end
    end

    //=========================================================================
    // Line Buffer Instance (using original working version)
    //=========================================================================
    isp_csiir_line_buffer #(
        .IMG_WIDTH(IMG_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_ADDR_WIDTH(LINE_ADDR_WIDTH),
        .ROW_CNT_WIDTH(ROW_CNT_WIDTH)
    ) u_line_buffer (
        .clk           (clk),
        .rst_n         (rst_n),
        .enable        (enable && !bypass),
        .sof           (sof_reg),
        .eol           (eol_reg),
        .din           (din),
        .din_valid     (din_valid),
        .window_0_0    (window_0_0),
        .window_0_1    (window_0_1),
        .window_0_2    (window_0_2),
        .window_0_3    (window_0_3),
        .window_0_4    (window_0_4),
        .window_1_0    (window_1_0),
        .window_1_1    (window_1_1),
        .window_1_2    (window_1_2),
        .window_1_3    (window_1_3),
        .window_1_4    (window_1_4),
        .window_2_0    (window_2_0),
        .window_2_1    (window_2_1),
        .window_2_2    (window_2_2),
        .window_2_3    (window_2_3),
        .window_2_4    (window_2_4),
        .window_3_0    (window_3_0),
        .window_3_1    (window_3_1),
        .window_3_2    (window_3_2),
        .window_3_3    (window_3_3),
        .window_3_4    (window_3_4),
        .window_4_0    (window_4_0),
        .window_4_1    (window_4_1),
        .window_4_2    (window_4_2),
        .window_4_3    (window_4_3),
        .window_4_4    (window_4_4),
        .window_valid  (window_valid),
        .window_center_x (window_center_x),
        .window_center_y (window_center_y),
        .boundary_mode (boundary_mode)
    );

    //=========================================================================
    // Stage 1: Gradient Calculation
    //=========================================================================
    stage1_gradient #(
        .DATA_WIDTH(DATA_WIDTH),
        .GRAD_WIDTH(GRAD_WIDTH),
        .WIN_SIZE_WIDTH(WIN_SIZE_WIDTH),
        .PIC_WIDTH_BITS(PIC_WIDTH_BITS),
        .PIC_HEIGHT_BITS(PIC_HEIGHT_BITS)
    ) u_stage1 (
        .clk              (clk),
        .rst_n            (rst_n),
        .enable           (enable && !bypass),
        .window_0_0       (window_0_0),
        .window_0_1       (window_0_1),
        .window_0_2       (window_0_2),
        .window_0_3       (window_0_3),
        .window_0_4       (window_0_4),
        .window_1_0       (window_1_0),
        .window_1_1       (window_1_1),
        .window_1_2       (window_1_2),
        .window_1_3       (window_1_3),
        .window_1_4       (window_1_4),
        .window_2_0       (window_2_0),
        .window_2_1       (window_2_1),
        .window_2_2       (window_2_2),
        .window_2_3       (window_2_3),
        .window_2_4       (window_2_4),
        .window_3_0       (window_3_0),
        .window_3_1       (window_3_1),
        .window_3_2       (window_3_2),
        .window_3_3       (window_3_3),
        .window_3_4       (window_3_4),
        .window_4_0       (window_4_0),
        .window_4_1       (window_4_1),
        .window_4_2       (window_4_2),
        .window_4_3       (window_4_3),
        .window_4_4       (window_4_4),
        .window_valid     (window_valid),
        .win_size_clip_y_0(win_size_clip_y_0),
        .win_size_clip_y_1(win_size_clip_y_1),
        .win_size_clip_y_2(win_size_clip_y_2),
        .win_size_clip_y_3(win_size_clip_y_3),
        .win_size_clip_sft_0(win_size_clip_sft_0),
        .win_size_clip_sft_1(win_size_clip_sft_1),
        .win_size_clip_sft_2(win_size_clip_sft_2),
        .win_size_clip_sft_3(win_size_clip_sft_3),
        .pixel_x          (pixel_x),
        .pixel_y          (pixel_y),
        .pic_width_m1     (pic_width_m1),
        .pic_height_m1    (pic_height_m1),
        .window_center_x  (window_center_x),
        .window_center_y  (window_center_y),
        .grad_h           (grad_h_s1),
        .grad_v           (grad_v_s1),
        .grad             (grad_s1),
        .win_size_clip    (win_size_clip_s1),
        .stage1_valid     (stage1_valid),
        .center_x_out     (center_x_s1),
        .center_y_out     (center_y_s1)
    );

    //=========================================================================
    // Stage 2: Directional Averaging
    //=========================================================================
    stage2_directional_avg #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .WIN_SIZE_WIDTH(WIN_SIZE_WIDTH)
    ) u_stage2 (
        .clk              (clk),
        .rst_n            (rst_n),
        .enable           (enable && !bypass),
        .window_0_0       (window_0_0),
        .window_0_1       (window_0_1),
        .window_0_2       (window_0_2),
        .window_0_3       (window_0_3),
        .window_0_4       (window_0_4),
        .window_1_0       (window_1_0),
        .window_1_1       (window_1_1),
        .window_1_2       (window_1_2),
        .window_1_3       (window_1_3),
        .window_1_4       (window_1_4),
        .window_2_0       (window_2_0),
        .window_2_1       (window_2_1),
        .window_2_2       (window_2_2),
        .window_2_3       (window_2_3),
        .window_2_4       (window_2_4),
        .window_3_0       (window_3_0),
        .window_3_1       (window_3_1),
        .window_3_2       (window_3_2),
        .window_3_3       (window_3_3),
        .window_3_4       (window_3_4),
        .window_4_0       (window_4_0),
        .window_4_1       (window_4_1),
        .window_4_2       (window_4_2),
        .window_4_3       (window_4_3),
        .window_4_4       (window_4_4),
        .window_valid     (window_valid),
        .win_size_clip    (win_size_clip_s1),
        .stage1_valid     (stage1_valid),
        .win_size_thresh0 (win_size_thresh0),
        .win_size_thresh1 (win_size_thresh1),
        .win_size_thresh2 (win_size_thresh2),
        .win_size_thresh3 (win_size_thresh3),
        .avg0_c           (avg0_c),
        .avg0_u           (avg0_u),
        .avg0_d           (avg0_d),
        .avg0_l           (avg0_l),
        .avg0_r           (avg0_r),
        .avg1_c           (avg1_c),
        .avg1_u           (avg1_u),
        .avg1_d           (avg1_d),
        .avg1_l           (avg1_l),
        .avg1_r           (avg1_r),
        .stage2_valid     (stage2_valid),
        .center_pixel_out (center_pixel_s2_out),
        .win_size_out     (win_size_s2_out),
        .pixel_x_in       (center_x_s1),
        .pixel_y_in       (center_y_s1),
        .pixel_x_out      (pixel_x_s2),
        .pixel_y_out      (pixel_y_s2)
    );

    //=========================================================================
    // Stage 3: Gradient Fusion
    //=========================================================================
    stage3_gradient_fusion #(
        .DATA_WIDTH(DATA_WIDTH),
        .GRAD_WIDTH(GRAD_WIDTH)
    ) u_stage3 (
        .clk             (clk),
        .rst_n           (rst_n),
        .enable          (enable && !bypass),
        .avg0_c          (avg0_c),
        .avg0_u          (avg0_u),
        .avg0_d          (avg0_d),
        .avg0_l          (avg0_l),
        .avg0_r          (avg0_r),
        .avg1_c          (avg1_c),
        .avg1_u          (avg1_u),
        .avg1_d          (avg1_d),
        .avg1_l          (avg1_l),
        .avg1_r          (avg1_r),
        .stage2_valid    (stage2_valid),
        .grad            (grad_delay[4]),
        .grad_h          (grad_h_delay[4]),
        .grad_v          (grad_v_delay[4]),
        .pixel_x         (pixel_x_s2),
        .pixel_y         (pixel_y_s2),
        .pic_width_m1    (pic_width_m1),
        .pic_height_m1   (pic_height_m1),
        // Instantaneous signals for line buffer write - use window center position
        .grad_instant    (grad_s1),
        .pixel_x_instant (center_x_s1),
        .pixel_y_instant (center_y_s1),
        .stage1_valid    (stage1_valid),
        // Center pixel and win_size inputs for pipelining
        .center_pixel_in  (center_pixel_s2_out),
        .win_size_clip_in (win_size_s2_out),
        .blend0_dir_avg  (blend0_dir_avg),
        .blend1_dir_avg  (blend1_dir_avg),
        .stage3_valid    (stage3_valid),
        .pixel_x_out     (pixel_x_s3),
        .pixel_y_out     (pixel_y_s3),
        .avg0_u_out      (avg0_u_s3_out),
        .avg1_u_out      (avg1_u_s3_out),
        .center_pixel_out (center_pixel_s3_out),
        .win_size_clip_out (win_size_clip_s3_out)
    );

    //=========================================================================
    // Stage 4: IIR Blend and Output
    //=========================================================================
    stage4_iir_blend #(
        .DATA_WIDTH(DATA_WIDTH),
        .GRAD_WIDTH(GRAD_WIDTH),
        .WIN_SIZE_WIDTH(WIN_SIZE_WIDTH)
    ) u_stage4 (
        .clk              (clk),
        .rst_n            (rst_n),
        .enable           (enable && !bypass),
        .blend0_dir_avg   (blend0_dir_avg),
        .blend1_dir_avg   (blend1_dir_avg),
        .stage3_valid     (stage3_valid),
        .grad_h           (grad_h_delay[4]),
        .grad_v           (grad_v_delay[4]),
        .avg0_u           (avg0_u_s3_out),
        .avg1_u           (avg1_u_s3_out),
        .win_size_clip    (win_size_clip_s3_out),
        .blending_ratio_0 (blending_ratio_0),
        .blending_ratio_1 (blending_ratio_1),
        .blending_ratio_2 (blending_ratio_2),
        .blending_ratio_3 (blending_ratio_3),
        .win_size_thresh0 (win_size_thresh0),
        .win_size_thresh1 (win_size_thresh1),
        .win_size_thresh2 (win_size_thresh2),
        .win_size_thresh3 (win_size_thresh3),
        .center_pixel     (center_pixel_s3_out),
        .pixel_x_in       (pixel_x_s3),
        .pixel_y_in       (pixel_y_s3),
        .dout             (dout_final),
        .dout_valid       (dout_final_valid),
        .pixel_x_out      (pixel_x_final),
        .pixel_y_out      (pixel_y_final)
    );

    //=========================================================================
    // Bypass Path (delay line to match pipeline latency)
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i <= 20; i = i + 1) begin
                din_delay[i]      <= {DATA_WIDTH{1'b0}};
                din_valid_delay[i] <= 1'b0;
                vsync_delay[i]    <= 1'b0;
                hsync_delay[i]    <= 1'b0;
            end
        end else begin
            din_delay[0]      <= din;
            din_valid_delay[0] <= din_valid;
            vsync_delay[0]    <= vsync;
            hsync_delay[0]    <= hsync;

            for (i = 1; i <= 20; i = i + 1) begin
                din_delay[i]      <= din_delay[i-1];
                din_valid_delay[i] <= din_valid_delay[i-1];
                vsync_delay[i]    <= vsync_delay[i-1];
                hsync_delay[i]    <= hsync_delay[i-1];
            end
        end
    end

    //=========================================================================
    // Output Mux (bypass or processed)
    //=========================================================================
    assign dout       = bypass ? din_delay[17] : dout_final;
    assign dout_valid = bypass ? din_valid_delay[17] : dout_final_valid;
    assign dout_vsync = bypass ? vsync_delay[17] : vsync;
    assign dout_hsync = bypass ? hsync_delay[17] : hsync;

endmodule