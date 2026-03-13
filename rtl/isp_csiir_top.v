//-----------------------------------------------------------------------------
// Module: isp_csiir_top
// Description: Top module integrating all ISP-CSIIR pipeline stages
//              Pure Verilog-2001 compatible
//-----------------------------------------------------------------------------

module isp_csiir_top #(
    parameter IMG_WIDTH  = 1920,
    parameter IMG_HEIGHT = 1080,
    parameter DATA_WIDTH = 8
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

    // Register block signals
    wire [15:0] pic_width_m1;
    wire [15:0] pic_height_m1;
    wire [15:0] win_size_thresh0;
    wire [15:0] win_size_thresh1;
    wire [15:0] win_size_thresh2;
    wire [15:0] win_size_thresh3;
    wire [7:0]  blending_ratio_0;
    wire [7:0]  blending_ratio_1;
    wire [7:0]  blending_ratio_2;
    wire [7:0]  blending_ratio_3;
    wire [7:0]  win_size_clip_y_0;
    wire [7:0]  win_size_clip_y_1;
    wire [7:0]  win_size_clip_y_2;
    wire [7:0]  win_size_clip_y_3;
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

    // Line buffer window outputs
    wire [DATA_WIDTH-1:0] window_0_0, window_0_1, window_0_2, window_0_3, window_0_4;
    wire [DATA_WIDTH-1:0] window_1_0, window_1_1, window_1_2, window_1_3, window_1_4;
    wire [DATA_WIDTH-1:0] window_2_0, window_2_1, window_2_2, window_2_3, window_2_4;
    wire [DATA_WIDTH-1:0] window_3_0, window_3_1, window_3_2, window_3_3, window_3_4;
    wire [DATA_WIDTH-1:0] window_4_0, window_4_1, window_4_2, window_4_3, window_4_4;
    wire                  window_valid;

    // Stage 1 outputs
    wire [11:0]          grad_h_s1;
    wire [11:0]          grad_v_s1;
    wire [11:0]          grad_s1;
    wire [5:0]           win_size_clip_s1;
    wire                 stage1_valid;

    // Stage 2 outputs
    wire [DATA_WIDTH-1:0] avg0_c, avg0_u, avg0_d, avg0_l, avg0_r;
    wire [DATA_WIDTH-1:0] avg1_c, avg1_u, avg1_d, avg1_l, avg1_r;
    wire                  stage2_valid;

    // Stage 3 outputs
    wire [DATA_WIDTH-1:0] blend0_dir_avg;
    wire [DATA_WIDTH-1:0] blend1_dir_avg;
    wire                  stage3_valid;

    // Stage 4 outputs (final output)
    wire [DATA_WIDTH-1:0] dout_final;
    wire                  dout_final_valid;

    // Video timing signals
    reg                   sof_reg;  // Start of frame
    reg                   eol_reg;  // End of line
    reg [15:0]            pixel_x;
    reg [15:0]            pixel_y;
    reg [15:0]            pixel_cnt;
    reg [15:0]            line_cnt;
    reg                   vsync_d1, vsync_d2;
    reg                   hsync_d1, hsync_d2;

    // Bypass path
    reg [DATA_WIDTH-1:0]  din_delay [0:20];  // Pipeline delay for bypass
    reg [20:0]            din_valid_delay;
    reg                   vsync_delay [0:20];
    reg                   hsync_delay [0:20];
    integer               i;

    // Boundary mode
    wire [1:0]            boundary_mode = 2'b01;  // Replicate mode

    //--------------------------------------------------------------------------
    // Register Block Instance
    //--------------------------------------------------------------------------
    isp_csiir_reg_block #(
        .APB_ADDR_WIDTH(8)
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

    //--------------------------------------------------------------------------
    // Video Timing Generation
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vsync_d1 <= 1'b0;
            vsync_d2 <= 1'b0;
            hsync_d1 <= 1'b0;
            hsync_d2 <= 1'b0;
            sof_reg  <= 1'b0;
            eol_reg  <= 1'b0;
            pixel_x  <= 16'd0;
            pixel_y  <= 16'd0;
            pixel_cnt <= 16'd0;
            line_cnt <= 16'd0;
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
                pixel_cnt <= 16'd0;
                line_cnt <= 16'd0;
                pixel_x <= 16'd0;
                pixel_y <= 16'd0;
            end else if (din_valid) begin
                if (pixel_cnt >= pic_width_m1) begin
                    pixel_cnt <= 16'd0;
                    pixel_x <= 16'd0;
                    if (line_cnt < pic_height_m1)
                        line_cnt <= line_cnt + 16'd1;
                    pixel_y <= line_cnt + 16'd1;
                end else begin
                    pixel_cnt <= pixel_cnt + 16'd1;
                    pixel_x <= pixel_cnt + 16'd1;
                end
            end
        end
    end

    //--------------------------------------------------------------------------
    // Line Buffer Instance
    //--------------------------------------------------------------------------
    isp_csiir_line_buffer #(
        .IMG_WIDTH (IMG_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
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
        .boundary_mode (boundary_mode)
    );

    //--------------------------------------------------------------------------
    // Stage 1: Gradient Calculation
    //--------------------------------------------------------------------------
    stage1_gradient #(
        .DATA_WIDTH    (DATA_WIDTH),
        .GRAD_WIDTH    (12),
        .WIN_SIZE_WIDTH(6)
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
        .grad_h           (grad_h_s1),
        .grad_v           (grad_v_s1),
        .grad             (grad_s1),
        .win_size_clip    (win_size_clip_s1),
        .stage1_valid     (stage1_valid)
    );

    //--------------------------------------------------------------------------
    // Stage 2: Directional Averaging
    //--------------------------------------------------------------------------
    stage2_directional_avg #(
        .DATA_WIDTH    (DATA_WIDTH),
        .ACC_WIDTH     (20),
        .WIN_SIZE_WIDTH(6)
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
        .stage2_valid     (stage2_valid)
    );

    //--------------------------------------------------------------------------
    // Stage 3: Gradient Fusion
    //--------------------------------------------------------------------------
    stage3_gradient_fusion #(
        .DATA_WIDTH (DATA_WIDTH),
        .GRAD_WIDTH (12)
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
        .grad            (grad_s1),
        .grad_h          (grad_h_s1),
        .grad_v          (grad_v_s1),
        .pixel_x         (pixel_x),
        .pixel_y         (pixel_y),
        .pic_width_m1    (pic_width_m1),
        .pic_height_m1   (pic_height_m1),
        .blend0_dir_avg  (blend0_dir_avg),
        .blend1_dir_avg  (blend1_dir_avg),
        .stage3_valid    (stage3_valid)
    );

    //--------------------------------------------------------------------------
    // Stage 4: IIR Blend and Output
    //--------------------------------------------------------------------------
    stage4_iir_blend #(
        .DATA_WIDTH    (DATA_WIDTH),
        .WIN_SIZE_WIDTH(6)
    ) u_stage4 (
        .clk              (clk),
        .rst_n            (rst_n),
        .enable           (enable && !bypass),
        .blend0_dir_avg   (blend0_dir_avg),
        .blend1_dir_avg   (blend1_dir_avg),
        .stage3_valid     (stage3_valid),
        .grad_h           (grad_h_s1),
        .grad_v           (grad_v_s1),
        .avg0_u           (avg0_u),
        .avg1_u           (avg1_u),
        .win_size_clip    (win_size_clip_s1),
        .blending_ratio_0 (blending_ratio_0),
        .blending_ratio_1 (blending_ratio_1),
        .blending_ratio_2 (blending_ratio_2),
        .blending_ratio_3 (blending_ratio_3),
        .win_size_thresh0 (win_size_thresh0),
        .win_size_thresh1 (win_size_thresh1),
        .win_size_thresh2 (win_size_thresh2),
        .win_size_thresh3 (win_size_thresh3),
        .center_pixel     (window_2_2),
        .dout             (dout_final),
        .dout_valid       (dout_final_valid)
    );

    //--------------------------------------------------------------------------
    // Bypass Path (delay line to match pipeline latency)
    //--------------------------------------------------------------------------
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

    //--------------------------------------------------------------------------
    // Output Mux (bypass or processed)
    //--------------------------------------------------------------------------
    assign dout       = bypass ? din_delay[17] : dout_final;
    assign dout_valid = bypass ? din_valid_delay[17] : dout_final_valid;
    assign dout_vsync = bypass ? vsync_delay[17] : vsync;  // Simplified
    assign dout_hsync = bypass ? hsync_delay[17] : hsync;  // Simplified

endmodule