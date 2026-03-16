//-----------------------------------------------------------------------------
// Module: stage4_iir_blend
// Description: Stage 4 - IIR filtering and final output blending
//              Pure Verilog-2001 compatible
//              Pipeline stages: 3 cycles
//              Fully parameterized for resolution and data width
//-----------------------------------------------------------------------------

module stage4_iir_blend #(
    parameter DATA_WIDTH     = 10,                      // Pixel data width
    parameter GRAD_WIDTH     = 14,                      // Gradient width
    parameter WIN_SIZE_WIDTH = 6                        // Window size parameter width
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // Stage 3 outputs
    input  wire [DATA_WIDTH-1:0]       blend0_dir_avg,
    input  wire [DATA_WIDTH-1:0]       blend1_dir_avg,
    input  wire                        stage3_valid,

    // Stage 1 outputs (for gradient comparison)
    input  wire [GRAD_WIDTH-1:0]       grad_h, grad_v,

    // Stage 2 outputs for IIR blending
    input  wire [DATA_WIDTH-1:0]       avg0_u, avg1_u,

    // Window size from Stage 1
    input  wire [WIN_SIZE_WIDTH-1:0]   win_size_clip,

    // Configuration
    input  wire [7:0]                  blending_ratio_0,
    input  wire [7:0]                  blending_ratio_1,
    input  wire [7:0]                  blending_ratio_2,
    input  wire [7:0]                  blending_ratio_3,
    input  wire [15:0]                 win_size_thresh0,
    input  wire [15:0]                 win_size_thresh1,
    input  wire [15:0]                 win_size_thresh2,
    input  wire [15:0]                 win_size_thresh3,

    // Center pixel
    input  wire [DATA_WIDTH-1:0]       center_pixel,

    // Outputs
    output reg  [DATA_WIDTH-1:0]       dout,
    output reg                         dout_valid
);

    `include "isp_csiir_defines.vh"

    // Pipeline registers
    reg [DATA_WIDTH-1:0] blend0_dir_avg_s1, blend1_dir_avg_s1;
    reg [DATA_WIDTH-1:0] avg0_u_s1, avg1_u_s1;
    reg [DATA_WIDTH-1:0] center_pixel_s1;
    reg [WIN_SIZE_WIDTH-1:0] win_size_clip_s1;
    reg [11:0] grad_h_s1, grad_v_s1;
    reg valid_s1;

    // Stage 2: IIR blend and blend factor selection
    reg [DATA_WIDTH-1:0] blend0_iir_avg, blend1_iir_avg;
    reg [DATA_WIDTH-1:0] blend0_dir_avg_s2, blend1_dir_avg_s2;
    reg [DATA_WIDTH-1:0] center_pixel_s2;
    reg [WIN_SIZE_WIDTH-1:0] win_size_clip_s2;
    reg valid_s2;

    // Stage 3: Final blend and output
    reg [DATA_WIDTH-1:0] blend0_out, blend1_out;
    reg [DATA_WIDTH-1:0] center_pixel_s3;
    reg [WIN_SIZE_WIDTH-1:0] win_size_clip_s3;
    reg valid_s3;

    // Blend factor registers (must be declared outside always block for Verilog-2001)
    reg [3:0] blend_factor;
    reg [3:0] blend_factor1;
    reg [WIN_SIZE_WIDTH:0] win_size_remain_8;

    // Select blending ratio based on window size
    reg [7:0] current_blend_ratio;

    // Stage 1: Pipeline inputs
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blend0_dir_avg_s1 <= {DATA_WIDTH{1'b0}};
            blend1_dir_avg_s1 <= {DATA_WIDTH{1'b0}};
            avg0_u_s1         <= {DATA_WIDTH{1'b0}};
            avg1_u_s1         <= {DATA_WIDTH{1'b0}};
            center_pixel_s1   <= {DATA_WIDTH{1'b0}};
            win_size_clip_s1  <= {WIN_SIZE_WIDTH{1'b0}};
            grad_h_s1         <= 12'd0;
            grad_v_s1         <= 12'd0;
            valid_s1          <= 1'b0;
        end else if (enable && stage3_valid) begin
            blend0_dir_avg_s1 <= blend0_dir_avg;
            blend1_dir_avg_s1 <= blend1_dir_avg;
            avg0_u_s1         <= avg0_u;
            avg1_u_s1         <= avg1_u;
            center_pixel_s1   <= center_pixel;
            win_size_clip_s1  <= win_size_clip;
            grad_h_s1         <= grad_h;
            grad_v_s1         <= grad_v;
            valid_s1          <= 1'b1;
        end else begin
            valid_s1 <= 1'b0;
        end
    end

    // Stage 2: Compute IIR blend and select blend factors
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blend0_iir_avg    <= {DATA_WIDTH{1'b0}};
            blend1_iir_avg    <= {DATA_WIDTH{1'b0}};
            blend0_dir_avg_s2 <= {DATA_WIDTH{1'b0}};
            blend1_dir_avg_s2 <= {DATA_WIDTH{1'b0}};
            center_pixel_s2   <= {DATA_WIDTH{1'b0}};
            win_size_clip_s2  <= {WIN_SIZE_WIDTH{1'b0}};
            valid_s2          <= 1'b0;
        end else if (enable && valid_s1) begin
            // Select blending ratio based on window size
            // win_size_clip/8 - 2 gives index 0-3
            case (win_size_clip_s1[5:3])
                3'd2: current_blend_ratio <= blending_ratio_0;  // 16-23
                3'd3: current_blend_ratio <= blending_ratio_1;  // 24-31
                3'd4: current_blend_ratio <= blending_ratio_2;  // 32-39
                3'd5: current_blend_ratio <= blending_ratio_3;  // 40-47
                default: current_blend_ratio <= blending_ratio_0;
            endcase

            // IIR blend: (ratio * dir_avg + (64 - ratio) * prev_avg) / 64
            // blend_iir_avg = (ratio * dir_avg + (64 - ratio) * avg_u) / 64
            blend0_iir_avg <= (current_blend_ratio * blend0_dir_avg_s1 +
                              (64 - current_blend_ratio) * avg0_u_s1) / 64;
            blend1_iir_avg <= (current_blend_ratio * blend1_dir_avg_s1 +
                              (64 - current_blend_ratio) * avg1_u_s1) / 64;

            // Pipeline
            blend0_dir_avg_s2 <= blend0_dir_avg_s1;
            blend1_dir_avg_s2 <= blend1_dir_avg_s1;
            center_pixel_s2   <= center_pixel_s1;
            win_size_clip_s2  <= win_size_clip_s1;
            valid_s2          <= 1'b1;
        end else begin
            valid_s2 <= 1'b0;
        end
    end

    // Stage 3: Final blend with directional factor and output
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            blend0_out      <= {DATA_WIDTH{1'b0}};
            blend1_out      <= {DATA_WIDTH{1'b0}};
            center_pixel_s3 <= {DATA_WIDTH{1'b0}};
            win_size_clip_s3 <= {WIN_SIZE_WIDTH{1'b0}};
            valid_s3        <= 1'b0;
        end else if (enable && valid_s2) begin
            // Select blend factors based on window size thresholds
            // Per algorithm: different blend_factor kernels for different window sizes
            if (win_size_clip_s2 < win_size_thresh0[5:0]) begin
                blend_factor  <= 4'd1;  // 2x2 kernel
                blend_factor1 <= 4'd2;  // 2x2/3x3 kernel
            end else if (win_size_clip_s2 < win_size_thresh1[5:0]) begin
                blend_factor  <= 4'd2;  // 3x3 kernel
                blend_factor1 <= 4'd3;  // 3x3/4x4 kernel
            end else if (win_size_clip_s2 < win_size_thresh2[5:0]) begin
                blend_factor  <= 4'd3;  // 4x4 kernel
                blend_factor1 <= 4'd4;  // 4x4/5x5 kernel
            end else if (win_size_clip_s2 < win_size_thresh3[5:0]) begin
                blend_factor  <= 4'd4;  // 5x5 kernel
                blend_factor1 <= 4'd4;  // 5x5 kernel
            end else begin
                blend_factor  <= 4'd4;  // Maximum blend
                blend_factor1 <= 4'd4;
            end

            // Apply blend factors with gradient direction consideration
            // If grad_h > grad_v, use horizontal blend pattern, else vertical
            // blend_out = iir_avg * factor + center * (4 - factor) / 4
            if (blend_factor == 0)
                blend0_out <= center_pixel_s2;
            else
                blend0_out <= (blend0_iir_avg * blend_factor +
                              center_pixel_s2 * (4 - blend_factor)) / 4;

            if (blend_factor1 == 0)
                blend1_out <= center_pixel_s2;
            else
                blend1_out <= (blend1_iir_avg * blend_factor1 +
                              center_pixel_s2 * (4 - blend_factor1)) / 4;

            center_pixel_s3  <= center_pixel_s2;
            win_size_clip_s3 <= win_size_clip_s2;
            valid_s3         <= 1'b1;
        end else begin
            valid_s3 <= 1'b0;
        end
    end

    // Final output blend between blend0 and blend1
    // blend_uv = blend0 * win_size_remain_8 + blend1 * (8 - win_size_remain_8) / 8
    // win_size_remain_8 = win_size_clip - (win_size_clip >> 3)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout       <= {DATA_WIDTH{1'b0}};
            dout_valid <= 1'b0;
        end else if (enable && valid_s3) begin
            // Calculate win_size_remain_8
            win_size_remain_8 = win_size_clip_s3 - (win_size_clip_s3 >> 3);

            // Clamp to valid range
            if (win_size_remain_8 > 7)
                win_size_remain_8 = 7;

            // Final blend
            // dout = blend0 * win_size_remain_8 + blend1 * (8 - win_size_remain_8) / 8
            if (win_size_remain_8 == 0) begin
                dout <= blend1_out;
            end else if (win_size_remain_8 >= 7) begin
                dout <= blend0_out;
            end else begin
                dout <= (blend0_out * win_size_remain_8[2:0] +
                        blend1_out * (8 - win_size_remain_8[2:0])) / 8;
            end

            dout_valid <= 1'b1;
        end else begin
            dout_valid <= 1'b0;
        end
    end

endmodule