//-----------------------------------------------------------------------------
// Module: common_p2s
// Purpose: Parallel to Serial converter with configurable dimensions
//          Converts PACK_WAYS×PACK_PIXELS block to PACK_WAYS columns
// Author: rtl-impl
// Date: 2026-04-18
//-----------------------------------------------------------------------------
// Description:
//   Takes a PACK_WAYS×PACK_PIXELS block and outputs PACK_WAYS columns serially:
//   - Outputs one column per cycle
//   - Each column contains PACK_WAYS pixels
//
// Input Format:
//   {row(PACK_WAYS-1), ..., row1, row0} where each row has PACK_PIXELS pixels
//
// Output Format:
//   Each cycle outputs one column: {pixel(WAYS-1), ..., pixel1, pixel0}
//
// Design: Simple counter-based, no explicit state machine
//   - pixel_idx: counts 0 to PACK_PIXELS-1
//   - din_buf: latches input when accepting new block
//
// Parameters:
//   DATA_WIDTH   - bits per pixel (default 10)
//   PACK_PIXELS  - pixels per row in input block (default 2)
//   PACK_WAYS    - number of rows/columns (default 4)
//-----------------------------------------------------------------------------

module common_p2s #(
    parameter DATA_WIDTH  = 10,
    parameter PACK_PIXELS = 2,   // pixels per row
    parameter PACK_WAYS   = 4   // rows in input block
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // Input (PACK_WAYS×PACK_PIXELS block)
    input  wire [DATA_WIDTH*PACK_PIXELS*PACK_WAYS-1:0] din,
    input  wire                                din_valid,
    output wire                                din_ready,

    // Output (one column per cycle)
    output wire [DATA_WIDTH*PACK_WAYS-1:0]   dout,
    output wire                                dout_valid,
    input  wire                                dout_ready,

    // Frame signals
    input  wire                                sof
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam INPUT_WIDTH  = DATA_WIDTH * PACK_PIXELS * PACK_WAYS;
    localparam OUTPUT_WIDTH = DATA_WIDTH * PACK_WAYS;
    localparam IDX_WIDTH    = $clog2(PACK_PIXELS+1);

    //=========================================================================
    // Internal Signals
    //=========================================================================
    reg [INPUT_WIDTH-1:0] din_buf;           // Latched input data
    reg                           din_buf_valid; // 1 = din_buf has valid data
    reg [IDX_WIDTH-1:0]          pixel_idx;    // 0 to PACK_PIXELS-1

    //=========================================================================
    // pixel_idx Counter
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_idx <= {IDX_WIDTH{1'b0}};
        end else if (sof) begin
            pixel_idx <= {IDX_WIDTH{1'b0}};
        end else if (enable) begin
            if (din_ready && din_valid) begin
                // New block accepted, reset index
                pixel_idx <= {IDX_WIDTH{1'b0}};
            end else if (dout_valid && dout_ready) begin
                // Output consumed, advance index
                if (pixel_idx < PACK_PIXELS - 1) begin
                    pixel_idx <= pixel_idx + 1'b1;
                end
            end
        end
    end

    //=========================================================================
    // din_buf and din_buf_valid
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            din_buf <= {INPUT_WIDTH{1'b0}};
            din_buf_valid <= 1'b0;
        end else if (sof) begin
            din_buf <= {INPUT_WIDTH{1'b0}};
            din_buf_valid <= 1'b0;
        end else if (enable) begin
            if (din_ready && din_valid) begin
                din_buf <= din;
                din_buf_valid <= 1'b1;
            end else if (dout_valid && dout_ready && pixel_idx >= PACK_PIXELS - 1) begin
                // Output complete for this block
                din_buf_valid <= 1'b0;
            end
        end
    end

    //=========================================================================
    // Output Data Selection
    //=========================================================================
    // Input format: {row(PACK_WAYS-1)[PACK_PIXELS-1:0], ..., row1[PACK_PIXELS-1:0], row0[PACK_PIXELS-1:0]}
    // Each row has PACK_PIXELS pixels, pixel_idx selects which pixel from each row

    genvar g;
    wire [OUTPUT_WIDTH-1:0] col_data;

    generate
        for (g = 0; g < PACK_WAYS; g = g + 1) begin : gen_col_extract
            // Each row occupies PACK_PIXELS*DATA_WIDTH bits
            // Row g: din_buf[(g*PACK_PIXELS*DATA_WIDTH) +: (PACK_PIXELS*DATA_WIDTH)]
            // Pixel p from row g: din_buf[(g*PACK_PIXELS*DATA_WIDTH) + p*DATA_WIDTH +: DATA_WIDTH]
            wire [DATA_WIDTH*PACK_PIXELS-1:0] row_g = din_buf[g*PACK_PIXELS*DATA_WIDTH +: PACK_PIXELS*DATA_WIDTH];
            // Extract pixel at pixel_idx from row g
            assign col_data[g*DATA_WIDTH +: DATA_WIDTH] = row_g[pixel_idx*DATA_WIDTH +: DATA_WIDTH];
        end
    endgenerate

    //=========================================================================
    // Output Register
    //=========================================================================
    reg [OUTPUT_WIDTH-1:0] dout_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout_r <= {OUTPUT_WIDTH{1'b0}};
        end else if (sof) begin
            dout_r <= {OUTPUT_WIDTH{1'b0}};
        end else if (enable) begin
            if (din_buf_valid)
                dout_r <= col_data;
        end
    end

    assign dout = dout_r;

    //=========================================================================
    // Valid/Ready Signals
    //=========================================================================
    // dout_valid: buffer has data and we're in output phase
    assign dout_valid = din_buf_valid;

    // din_ready: no data in buffer, or current block fully output and consumed
    assign din_ready = enable && (~din_buf_valid ||
                                  (dout_valid && dout_ready && pixel_idx >= PACK_PIXELS - 1));

endmodule
