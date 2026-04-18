//-----------------------------------------------------------------------------
// Module: common_lb
// Purpose: Multi-row line buffer with configurable packing
//          Stores incoming packed data in N SRAM rows
// Author: rtl-impl
// Date: 2026-04-18
//-----------------------------------------------------------------------------
// Description:
//   N-row line buffer with configurable PACK_PIXELS per row:
//   - DATA_WIDTH = bits per pixel
//   - PACK_PIXELS = number of pixels packed per word (e.g., 2P = 2)
//   - PACK_ROWS = number of rows (e.g., 4)
//   - Each row stores PACK_PIXELS pixels at each column address
//
// Storage Format:
//   - Each row stores PACK_PIXELS pixels at each column address
//   - Rows are independent SRAM instances
//   - Output is PACK_ROWS × PACK_PIXELS × DATA_WIDTH bits
//
// Parameters:
//   IMG_WIDTH      - image width in pixels
//   DATA_WIDTH     - bits per pixel (default 10)
//   LINE_ADDR_WIDTH - address width (log2(IMG_WIDTH/PACK_PIXELS))
//   PACK_PIXELS    - pixels per word/packing factor (default 2)
//   PACK_ROWS      - number of rows (default 4)
//-----------------------------------------------------------------------------

module common_lb #(
    parameter IMG_WIDTH        = 5472,
    parameter DATA_WIDTH       = 10,
    parameter LINE_ADDR_WIDTH  = 14,  // log2(IMG_WIDTH/PACK_PIXELS)
    parameter PACK_PIXELS      = 2,   // pixels per word (2P)
    parameter PACK_ROWS        = 4    // rows in line buffer
)(
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire                              enable,

    // Configuration
    input  wire [LINE_ADDR_WIDTH-1:0]       img_width,

    // Write side
    input  wire [LINE_ADDR_WIDTH-1:0]       wr_addr,         // column address
    input  wire [PACK_ROWS-1:0]             wr_row_en,       // which rows to write (one-hot)
    input  wire [DATA_WIDTH*PACK_PIXELS-1:0] wr_data,         // packed data input
    input  wire                              wr_en,           // write enable

    // Read side
    input  wire [LINE_ADDR_WIDTH-1:0]       rd_addr,          // column address
    input  wire                              rd_en,           // read enable
    output wire [DATA_WIDTH*PACK_PIXELS*PACK_ROWS-1:0] dout   // packed data output
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam SRAM_DW = DATA_WIDTH * PACK_PIXELS;  // bits per word
    localparam SRAM_AW = LINE_ADDR_WIDTH;           // IMG_WIDTH/PACK_PIXELS depth

    //=========================================================================
    // SRAM Instances (PACK_ROWS rows)
    //=========================================================================
    genvar i;
    generate
        for (i = 0; i < PACK_ROWS; i = i + 1) begin : gen_sram_rows
            wire [DATA_WIDTH*PACK_PIXELS-1:0] sram_dout;
            common_sram_model #(
                .DATA_WIDTH (SRAM_DW),
                .ADDR_WIDTH (SRAM_AW),
                .DEPTH      (IMG_WIDTH/PACK_PIXELS),
                .OUTPUT_REG (1)
            ) u_sram (
                .clk      (clk),
                .rst_n    (rst_n),
                .enable   (enable),
                .wr_en    (wr_en && wr_row_en[i]),
                .wr_addr  (wr_addr),
                .wr_data  (wr_data),
                .rd_en    (rd_en),
                .rd_addr  (rd_addr),
                .rd_data  (sram_dout)
            );
            // Assign to output
            assign dout[(i+1)*SRAM_DW-1 -: SRAM_DW] = sram_dout;
        end
    endgenerate

endmodule
