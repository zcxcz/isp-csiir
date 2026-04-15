//-----------------------------------------------------------------------------
// Module: common_distributor
// Purpose: Route 2P data to linebuffer row based on current pixel y-coordinate
// Author: rtl-impl
// Date: 2026-04-15
//-----------------------------------------------------------------------------
// Description:
//   Routes incoming 2P pixel pairs to the correct linebuffer row.
//
//   Architecture:
//   - Input: 2P pixel stream (u,v per pixel) from upstream FIFO
//   - Each 2P word: {v[9:0], u[9:0]} = 20 bits
//   - Routing key: py (pixel y-coordinate) % NUM_ROWS → wr_row_sel
//   - 2P is unpacked to 1P for linebuffer_core's per-row write interface
//
// Interface Convention:
//   - All input interfaces marked (in): driven by upstream
//   - All output interfaces marked (out): driven by this module
//   - Internal data marked (in): metadata from upstream control path
//
// Parameters:
//   DATA_WIDTH       - Bit width of each component (u or v), default 10
//   NUM_ROWS         - Number of linebuffer rows, default 5
//   LINE_ADDR_WIDTH  - Bit width of pixel x-address, default 14
//   ROW_CNT_WIDTH    - Bit width of pixel y-address, default 13
//   IMG_W_WIDTH      - Bit width of image width config, default 16
//   IMG_H_WIDTH      - Bit width of image height config, default 13
//-----------------------------------------------------------------------------

module common_distributor #(
    parameter DATA_WIDTH       = 10,
    parameter NUM_ROWS         = 5,
    parameter LINE_ADDR_WIDTH  = 14,
    parameter ROW_CNT_WIDTH    = 13,
    parameter IMG_W_WIDTH      = 16,
    parameter IMG_H_WIDTH      = 13
)(
    input  wire                           clk,
    input  wire                           rst_n,
    input  wire                           enable,
    input  wire                           sof,   // Start of frame — reset state

    // Input: 2P data stream with handshake (in)
    input  wire [DATA_WIDTH*2-1:0]        din,
    input  wire                           din_valid,
    output wire                           din_ready,

    // Input: Pixel coordinate (in)
    input  wire [LINE_ADDR_WIDTH-1:0]     px,    // Pixel x-address (PIXEL addr)
    input  wire [ROW_CNT_WIDTH-1:0]       py,    // Pixel y-address (PIXEL addr)

    // Input: Image size (in)
    input  wire [IMG_W_WIDTH-1:0]         img_width_cfg,
    input  wire [IMG_H_WIDTH-1:0]        img_height_cfg,

    // Output: 1P SRAM write interface — 5 independent ports (out)
    // Each port corresponds to one linebuffer row.
    // Linebuffer_core performs 2P packing internally from these 1P inputs.
    //
    // Row semantics (circular buffer):
    //   Row 0: oldest (first row of the 5-row window)
    //   Row 1: second oldest
    //   ...
    //   Row NUM_ROWS-1: newest (most recently written)
    //
    // 2P unpack: based on px[0], split 2P into even/odd pixel
    //   px[0]=1 (even pixel): even = din[0+:DW], odd = padding
    //   px[0]=0 (odd pixel):  odd  = din[DW+:DW], even = padding
    //
    // Linebuffer_core writes: {odd, even} — upper=odd, lower=even
    //
    //--------- Row 0 ---------
    output wire                           wr_row_0_en,
    output wire [DATA_WIDTH-1:0]         wr_row_0_even,
    output wire [DATA_WIDTH-1:0]         wr_row_0_odd,

    //--------- Row 1 ---------
    output wire                           wr_row_1_en,
    output wire [DATA_WIDTH-1:0]         wr_row_1_even,
    output wire [DATA_WIDTH-1:0]         wr_row_1_odd,

    //--------- Row 2 ---------
    output wire                           wr_row_2_en,
    output wire [DATA_WIDTH-1:0]         wr_row_2_even,
    output wire [DATA_WIDTH-1:0]         wr_row_2_odd,

    //--------- Row 3 ---------
    output wire                           wr_row_3_en,
    output wire [DATA_WIDTH-1:0]         wr_row_3_even,
    output wire [DATA_WIDTH-1:0]         wr_row_3_odd,

    //--------- Row 4 ---------
    output wire                           wr_row_4_en,
    output wire [DATA_WIDTH-1:0]         wr_row_4_even,
    output wire [DATA_WIDTH-1:0]         wr_row_4_odd
);

    //=========================================================================
    // Localparam
    //=========================================================================
    localparam ROW_SEL_WIDTH = 3;  // log2(NUM_ROWS), NUM_ROWS=5 → 3 bits

    //=========================================================================
    // Row Selection
    //=========================================================================
    // wr_row_sel = py % NUM_ROWS
    // This determines which row receives the write for this 2P word.
    // py is the pixel's row index; py % NUM_ROWS gives the circular buffer slot.
    //
    // Example (NUM_ROWS=5):
    //   py=0  → row 0  (oldest)
    //   py=1  → row 1
    //   py=4  → row 4
    //   py=5  → row 0  (wraps)
    //   py=6  → row 1
    //   py=10 → row 0  (wraps)
    //
    // For NUM_ROWS=5 (not a power of 2), truncation py[2:0] is NOT equal to py%5.
    // Use subtraction to compute the remainder:
    //   if (py_low >= NUM_ROWS) result = py_low - NUM_ROWS else py_low
    //
    // General formula: py % NUM_ROWS
    //   Step 1: py_low = py % 2^ROW_SEL_WIDTH = py[ROW_SEL_WIDTH-1:0]
    //   Step 2: wr_row_sel = (py_low >= NUM_ROWS) ? py_low - NUM_ROWS : py_low
    //
    // For NUM_ROWS=5, ROW_SEL_WIDTH=3:
    //   py_low = py[2:0]  (values 0-7)
    //   py_low >= 5 only for 5,6,7; subtract 5 → 0,1,2
    //   Results: {0,1,2,3,4,0,1,2} ✓
    wire [ROW_SEL_WIDTH-1:0] py_low = py[ROW_SEL_WIDTH-1:0];
    assign wr_row_sel = (py_low >= NUM_ROWS[ROW_SEL_WIDTH-1:0])
                        ? py_low - NUM_ROWS[ROW_SEL_WIDTH-1:0]
                        : py_low;

    //=========================================================================
    // Handshake
    //=========================================================================
    // Distributor is transparent — it does not introduce backpressure.
    // When upstream data is valid and module is enabled, route it.
    // Linebuffer_core's din_ready is the effective backpressure.
    assign din_ready = enable;

    //=========================================================================
    // 2P → 1P Unpack
    //=========================================================================
    // 2P word format: {odd[9:0], even[9:0]}
    //   even = din[0 +: DATA_WIDTH]  (pixel at px)
    //   odd  = din[DATA_WIDTH +: DATA_WIDTH] (pixel at px+1)
    //
    // din_col_even: 1=writing even pixel (px[0]=1), 0=writing odd pixel (px[0]=0)
    // For each row, even/odd are passed separately.
    // Linebuffer_core packs as: {odd, even} per SRAM word.
    wire [DATA_WIDTH-1:0] din_even = din[0 +: DATA_WIDTH];
    wire [DATA_WIDTH-1:0] din_odd  = din[DATA_WIDTH +: DATA_WIDTH];

    // Padding value for the unused half of the 2P word
    wire [DATA_WIDTH-1:0] din_even_pad = {DATA_WIDTH{1'b0}};
    wire [DATA_WIDTH-1:0] din_odd_pad  = {DATA_WIDTH{1'b0}};

    //=========================================================================
    // Fire Condition
    //=========================================================================
    wire fire = din_valid && din_ready && enable;

    //=========================================================================
    // Per-Row Write Signal Generation
    //=========================================================================
    // Each row's write enable is asserted when:
    //   1. Data is firing (fire)
    //   2. This row is selected (wr_row_sel matches row index)
    //
    // Even/odd data:
    //   The even pixel always goes to the even port (corresponds to px).
    //   The odd pixel always goes to the odd port (corresponds to px+1).
    //   The upper/lower half of the 2P SRAM word is determined by linebuffer_core.

    //--------- Row 0 ---------
    assign wr_row_0_en   = fire && (wr_row_sel == 3'd0);
    assign wr_row_0_even = din_even;
    assign wr_row_0_odd  = din_odd;

    //--------- Row 1 ---------
    assign wr_row_1_en   = fire && (wr_row_sel == 3'd1);
    assign wr_row_1_even = din_even;
    assign wr_row_1_odd  = din_odd;

    //--------- Row 2 ---------
    assign wr_row_2_en   = fire && (wr_row_sel == 3'd2);
    assign wr_row_2_even = din_even;
    assign wr_row_2_odd  = din_odd;

    //--------- Row 3 ---------
    assign wr_row_3_en   = fire && (wr_row_sel == 3'd3);
    assign wr_row_3_even = din_even;
    assign wr_row_3_odd  = din_odd;

    //--------- Row 4 ---------
    assign wr_row_4_en   = fire && (wr_row_sel == 3'd4);
    assign wr_row_4_even = din_even;
    assign wr_row_4_odd  = din_odd;

endmodule
