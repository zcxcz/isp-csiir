//-----------------------------------------------------------------------------
// Module: isp_csiir_reg_block
// Description: Configuration register block for ISP-CSIIR module
//              Pure Verilog-2001 compatible
//              Fully parameterized for resolution and data width
//-----------------------------------------------------------------------------

module isp_csiir_reg_block #(
    parameter APB_ADDR_WIDTH = 8,
    parameter PIC_WIDTH_BITS  = 14,                   // log2(MAX_WIDTH) + 1
    parameter PIC_HEIGHT_BITS = 13,                   // log2(MAX_HEIGHT) + 1
    parameter DATA_WIDTH      = 10                    // Pixel data width
)(
    input  wire                      clk,
    input  wire                      rst_n,

    // APB Interface
    input  wire                      psel,
    input  wire                      penable,
    input  wire                      pwrite,
    input  wire [APB_ADDR_WIDTH-1:0] paddr,
    input  wire [31:0]               pwdata,
    output reg  [31:0]               prdata,
    output wire                      pready,
    output wire                      pslverr,

    // Register outputs
    output reg  [PIC_WIDTH_BITS-1:0]  pic_width_m1,
    output reg  [PIC_HEIGHT_BITS-1:0] pic_height_m1,
    output reg  [15:0] win_size_thresh0,
    output reg  [15:0] win_size_thresh1,
    output reg  [15:0] win_size_thresh2,
    output reg  [15:0] win_size_thresh3,
    output reg  [7:0]  blending_ratio_0,
    output reg  [7:0]  blending_ratio_1,
    output reg  [7:0]  blending_ratio_2,
    output reg  [7:0]  blending_ratio_3,
    output reg  [DATA_WIDTH-1:0] win_size_clip_y_0,   // Extended for DATA_WIDTH
    output reg  [DATA_WIDTH-1:0] win_size_clip_y_1,
    output reg  [DATA_WIDTH-1:0] win_size_clip_y_2,
    output reg  [DATA_WIDTH-1:0] win_size_clip_y_3,
    output reg  [7:0]  win_size_clip_sft_0,
    output reg  [7:0]  win_size_clip_sft_1,
    output reg  [7:0]  win_size_clip_sft_2,
    output reg  [7:0]  win_size_clip_sft_3,
    output reg  [7:0]  mot_protect_0,
    output reg  [7:0]  mot_protect_1,
    output reg  [7:0]  mot_protect_2,
    output reg  [7:0]  mot_protect_3,
    output reg         enable,
    output reg         bypass,
    output reg         regs_updated
);

    `include "isp_csiir_defines.vh"

    //=========================================================================
    // Register Address Map
    //=========================================================================
    localparam [APB_ADDR_WIDTH-1:0] ADDR_ENABLE      = 8'h00;
    localparam [APB_ADDR_WIDTH-1:0] ADDR_PIC_SIZE    = 8'h04;
    localparam [APB_ADDR_WIDTH-1:0] ADDR_PIC_SIZE_HI = 8'h08;  // For resolutions > 16-bit
    localparam [APB_ADDR_WIDTH-1:0] ADDR_THRESH0     = 8'h0C;
    localparam [APB_ADDR_WIDTH-1:0] ADDR_THRESH1     = 8'h10;
    localparam [APB_ADDR_WIDTH-1:0] ADDR_THRESH2     = 8'h14;
    localparam [APB_ADDR_WIDTH-1:0] ADDR_THRESH3     = 8'h18;
    localparam [APB_ADDR_WIDTH-1:0] ADDR_BLEND_RATIO = 8'h1C;
    localparam [APB_ADDR_WIDTH-1:0] ADDR_CLIP_Y      = 8'h20;
    localparam [APB_ADDR_WIDTH-1:0] ADDR_CLIP_SFT    = 8'h24;
    localparam [APB_ADDR_WIDTH-1:0] ADDR_MOT_PROTECT = 8'h28;

    wire write_en;
    wire read_en;

    assign write_en = psel && penable && pwrite;
    assign read_en  = psel && penable && !pwrite;

    // APB ready response
    assign pready  = 1'b1;
    assign pslverr = 1'b0;

    //=========================================================================
    // Register Read Logic
    //=========================================================================
    always @(*) begin
        prdata = 32'h0;
        if (read_en) begin
            case (paddr)
                ADDR_ENABLE: begin
                    prdata = {30'h0, bypass, enable};
                end
                ADDR_PIC_SIZE: begin
                    // Lower 16 bits: width_m1, Upper 16 bits: height_m1 lower bits
                    prdata = {pic_height_m1[15:0], pic_width_m1[15:0]};
                end
                ADDR_PIC_SIZE_HI: begin
                    // Extended bits for 8K resolution
                    // [15:0] = width_m1 upper bits, [31:16] = height_m1 upper bits
                    // For 8K: width needs 14 bits, height needs 13 bits
                    prdata = {16'h0, pic_height_m1[12:0], 3'b0, pic_width_m1[13:0]};
                end
                ADDR_THRESH0: begin
                    prdata = {16'h0, win_size_thresh0};
                end
                ADDR_THRESH1: begin
                    prdata = {16'h0, win_size_thresh1};
                end
                ADDR_THRESH2: begin
                    prdata = {16'h0, win_size_thresh2};
                end
                ADDR_THRESH3: begin
                    prdata = {16'h0, win_size_thresh3};
                end
                ADDR_BLEND_RATIO: begin
                    prdata = {8'h0, blending_ratio_3, blending_ratio_2,
                              blending_ratio_1, blending_ratio_0};
                end
                ADDR_CLIP_Y: begin
                    // Pack DATA_WIDTH values into 32-bit register
                    if (DATA_WIDTH == 10) begin
                        prdata = {2'b0, win_size_clip_y_3,
                                  2'b0, win_size_clip_y_2,
                                  2'b0, win_size_clip_y_1,
                                  2'b0, win_size_clip_y_0};
                    end else begin
                        prdata = {8'h0, win_size_clip_y_3[7:0], win_size_clip_y_2[7:0],
                                  win_size_clip_y_1[7:0], win_size_clip_y_0[7:0]};
                    end
                end
                ADDR_CLIP_SFT: begin
                    prdata = {8'h0, win_size_clip_sft_3, win_size_clip_sft_2,
                              win_size_clip_sft_1, win_size_clip_sft_0};
                end
                ADDR_MOT_PROTECT: begin
                    prdata = {8'h0, mot_protect_3, mot_protect_2,
                              mot_protect_1, mot_protect_0};
                end
                default: begin
                    prdata = 32'h0;
                end
            endcase
        end
    end

    //=========================================================================
    // Register Write Logic
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Default to 8K resolution
            pic_width_m1       <= `MAX_WIDTH_DEFAULT - 1;
            pic_height_m1      <= `MAX_HEIGHT_DEFAULT - 1;
            win_size_thresh0   <= `REG_WIN_SIZE_THRESH0_DEFAULT;
            win_size_thresh1   <= `REG_WIN_SIZE_THRESH1_DEFAULT;
            win_size_thresh2   <= `REG_WIN_SIZE_THRESH2_DEFAULT;
            win_size_thresh3   <= `REG_WIN_SIZE_THRESH3_DEFAULT;
            blending_ratio_0   <= `REG_BLEND_RATIO_DEFAULT;
            blending_ratio_1   <= `REG_BLEND_RATIO_DEFAULT;
            blending_ratio_2   <= `REG_BLEND_RATIO_DEFAULT;
            blending_ratio_3   <= `REG_BLEND_RATIO_DEFAULT;
            win_size_clip_y_0  <= `REG_WIN_CLIP_Y_0_DEFAULT;
            win_size_clip_y_1  <= `REG_WIN_CLIP_Y_1_DEFAULT;
            win_size_clip_y_2  <= `REG_WIN_CLIP_Y_2_DEFAULT;
            win_size_clip_y_3  <= `REG_WIN_CLIP_Y_3_DEFAULT;
            win_size_clip_sft_0 <= `REG_WIN_CLIP_SFT_DEFAULT;
            win_size_clip_sft_1 <= `REG_WIN_CLIP_SFT_DEFAULT;
            win_size_clip_sft_2 <= `REG_WIN_CLIP_SFT_DEFAULT;
            win_size_clip_sft_3 <= `REG_WIN_CLIP_SFT_DEFAULT;
            mot_protect_0      <= 8'd0;
            mot_protect_1      <= 8'd0;
            mot_protect_2      <= 8'd0;
            mot_protect_3      <= 8'd0;
            enable             <= 1'b1;
            bypass             <= 1'b0;
        end else if (write_en) begin
            case (paddr)
                ADDR_ENABLE: begin
                    enable <= pwdata[0];
                    bypass <= pwdata[1];
                end
                ADDR_PIC_SIZE: begin
                    pic_width_m1[15:0]  <= pwdata[15:0];
                    pic_height_m1[15:0] <= pwdata[31:16];
                end
                ADDR_PIC_SIZE_HI: begin
                    // Extended bits for resolutions > 16-bit (not needed for 8K)
                    // Reserved for future use
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
                    if (DATA_WIDTH == 10) begin
                        win_size_clip_y_0 <= pwdata[9:0];
                        win_size_clip_y_1 <= pwdata[19:10];
                        win_size_clip_y_2 <= pwdata[29:20];
                        // win_size_clip_y_3 would need another register
                    end else begin
                        win_size_clip_y_0 <= {2'b0, pwdata[7:0]};
                        win_size_clip_y_1 <= {2'b0, pwdata[15:8]};
                        win_size_clip_y_2 <= {2'b0, pwdata[23:16]};
                        win_size_clip_y_3 <= {2'b0, pwdata[31:24]};
                    end
                end
                ADDR_CLIP_SFT: begin
                    win_size_clip_sft_0 <= pwdata[7:0];
                    win_size_clip_sft_1 <= pwdata[15:8];
                    win_size_clip_sft_2 <= pwdata[23:16];
                    win_size_clip_sft_3 <= pwdata[31:24];
                end
                ADDR_MOT_PROTECT: begin
                    mot_protect_0 <= pwdata[7:0];
                    mot_protect_1 <= pwdata[15:8];
                    mot_protect_2 <= pwdata[23:16];
                    mot_protect_3 <= pwdata[31:24];
                end
                default: ;
            endcase
        end
    end

    //=========================================================================
    // Register Update Pulse
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            regs_updated <= 1'b0;
        else
            regs_updated <= write_en;
    end

endmodule