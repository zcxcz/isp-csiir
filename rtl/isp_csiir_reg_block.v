//-----------------------------------------------------------------------------
// Module: isp_csiir_reg_block
// Purpose: APB register configuration block
// Author: rtl-impl
// Date: 2026-03-22
// Version: v1.0
//-----------------------------------------------------------------------------
// Description:
//   Implements APB slave interface for configuration registers.
//   Supports 32-bit read/write access to configuration parameters.
//-----------------------------------------------------------------------------

module isp_csiir_reg_block #(
    parameter DATA_WIDTH     = 10,
    parameter GRAD_WIDTH     = 14,
    parameter WIN_SIZE_WIDTH = 6
)(
    input  wire                clk,
    input  wire                rst_n,

    // APB Interface
    input  wire                psel,
    input  wire                penable,
    input  wire                pwrite,
    input  wire [7:0]          paddr,
    input  wire [31:0]         pwdata,
    output reg  [31:0]         prdata,
    output wire                pready,
    output wire                pslverr,

    // Configuration outputs
    output reg                 enable,
    output reg                 bypass,

    output reg  [15:0]         img_width,
    output reg  [15:0]         img_height,

    output reg  [15:0]         win_size_thresh0,
    output reg  [15:0]         win_size_thresh1,
    output reg  [15:0]         win_size_thresh2,
    output reg  [15:0]         win_size_thresh3,

    output reg  [7:0]          blending_ratio_0,
    output reg  [7:0]          blending_ratio_1,
    output reg  [7:0]          blending_ratio_2,
    output reg  [7:0]          blending_ratio_3,

    output reg  [DATA_WIDTH-1:0] win_size_clip_y_0,
    output reg  [DATA_WIDTH-1:0] win_size_clip_y_1,
    output reg  [DATA_WIDTH-1:0] win_size_clip_y_2,
    output reg  [DATA_WIDTH-1:0] win_size_clip_y_3,

    output reg  [7:0]          win_size_clip_sft_0,
    output reg  [7:0]          win_size_clip_sft_1,
    output reg  [7:0]          win_size_clip_sft_2,
    output reg  [7:0]          win_size_clip_sft_3,

    output reg  [31:0]         mot_protect
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    // Register addresses
    localparam ADDR_CTRL          = 8'h00;
    localparam ADDR_PIC_SIZE      = 8'h04;
    localparam ADDR_PIC_SIZE_HI   = 8'h08;
    localparam ADDR_THRESH0       = 8'h0C;
    localparam ADDR_THRESH1       = 8'h10;
    localparam ADDR_THRESH2       = 8'h14;
    localparam ADDR_THRESH3       = 8'h18;
    localparam ADDR_BLEND_RATIO   = 8'h1C;
    localparam ADDR_CLIP_Y        = 8'h20;
    localparam ADDR_CLIP_SFT      = 8'h24;
    localparam ADDR_MOT_PROTECT   = 8'h28;
    localparam ADDR_CLIP_Y_3      = 8'h2C;

    //=========================================================================
    // Internal Signals
    //=========================================================================
    wire apb_write = psel && penable && pwrite;
    wire apb_read  = psel && penable && !pwrite;

    //=========================================================================
    // Default Configuration Values
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enable           <= 1'b0;
            bypass           <= 1'b0;
            img_width        <= 16'd5472;
            img_height       <= 16'd3076;
            win_size_thresh0 <= 16'd16;
            win_size_thresh1 <= 16'd24;
            win_size_thresh2 <= 16'd32;
            win_size_thresh3 <= 16'd40;
            blending_ratio_0 <= 8'd32;
            blending_ratio_1 <= 8'd32;
            blending_ratio_2 <= 8'd32;
            blending_ratio_3 <= 8'd32;
            win_size_clip_y_0 <= 10'd15;
            win_size_clip_y_1 <= 10'd23;
            win_size_clip_y_2 <= 10'd31;
            win_size_clip_y_3 <= 10'd39;
            win_size_clip_sft_0 <= 8'd2;
            win_size_clip_sft_1 <= 8'd2;
            win_size_clip_sft_2 <= 8'd2;
            win_size_clip_sft_3 <= 8'd2;
            mot_protect      <= 32'd0;
        end else if (apb_write) begin
            case (paddr)
                ADDR_CTRL: begin
                    enable <= pwdata[0];
                    bypass <= pwdata[1];
                end
                ADDR_PIC_SIZE: begin
                    img_width  <= pwdata[15:0];
                    img_height <= pwdata[31:16];
                end
                ADDR_THRESH0: begin
                    win_size_thresh0 <= pwdata[15:0];
                end
                ADDR_THRESH1: begin
                    win_size_thresh1 <= pwdata[15:0];
                end
                ADDR_THRESH2: begin
                    win_size_thresh2 <= pwdata[15:0];
                end
                ADDR_THRESH3: begin
                    win_size_thresh3 <= pwdata[15:0];
                end
                ADDR_BLEND_RATIO: begin
                    blending_ratio_0 <= pwdata[7:0];
                    blending_ratio_1 <= pwdata[15:8];
                    blending_ratio_2 <= pwdata[23:16];
                    blending_ratio_3 <= pwdata[31:24];
                end
                ADDR_CLIP_Y: begin
                    win_size_clip_y_0 <= pwdata[9:0];
                    win_size_clip_y_1 <= pwdata[25:16];
                end
                ADDR_CLIP_SFT: begin
                    win_size_clip_sft_0 <= pwdata[7:0];
                    win_size_clip_sft_1 <= pwdata[15:8];
                    win_size_clip_sft_2 <= pwdata[23:16];
                    win_size_clip_sft_3 <= pwdata[31:24];
                end
                ADDR_MOT_PROTECT: begin
                    mot_protect <= pwdata;
                end
                ADDR_CLIP_Y_3: begin
                    win_size_clip_y_2 <= pwdata[9:0];
                    win_size_clip_y_3 <= pwdata[25:16];
                end
                default: begin
                    // No action for undefined addresses
                end
            endcase
        end
    end

    //=========================================================================
    // APB Read Logic
    //=========================================================================
    always @(*) begin
        prdata = 32'd0;
        case (paddr)
            ADDR_CTRL: begin
                prdata = {30'd0, bypass, enable};
            end
            ADDR_PIC_SIZE: begin
                prdata = {img_height, img_width};
            end
            ADDR_THRESH0: begin
                prdata = {16'd0, win_size_thresh0};
            end
            ADDR_THRESH1: begin
                prdata = {16'd0, win_size_thresh1};
            end
            ADDR_THRESH2: begin
                prdata = {16'd0, win_size_thresh2};
            end
            ADDR_THRESH3: begin
                prdata = {16'd0, win_size_thresh3};
            end
            ADDR_BLEND_RATIO: begin
                prdata = {blending_ratio_3, blending_ratio_2,
                          blending_ratio_1, blending_ratio_0};
            end
            ADDR_CLIP_Y: begin
                prdata = {6'd0, win_size_clip_y_1, 6'd0, win_size_clip_y_0};
            end
            ADDR_CLIP_SFT: begin
                prdata = {win_size_clip_sft_3, win_size_clip_sft_2,
                          win_size_clip_sft_1, win_size_clip_sft_0};
            end
            ADDR_MOT_PROTECT: begin
                prdata = mot_protect;
            end
            ADDR_CLIP_Y_3: begin
                prdata = {6'd0, win_size_clip_y_3, 6'd0, win_size_clip_y_2};
            end
            default: begin
                prdata = 32'd0;
            end
        endcase
    end

    //=========================================================================
    // APB Response
    //=========================================================================
    assign pready  = 1'b1;  // Always ready
    assign pslverr = 1'b0;  // No error response

endmodule