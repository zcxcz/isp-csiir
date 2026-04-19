//-----------------------------------------------------------------------------
// Module: common_padding
// Purpose: Boundary padding for 5x5 window operations
//          Applies boundary replication padding to column data
// Author: rtl-impl
// Date: 2026-04-20
//-----------------------------------------------------------------------------
// Description:
//   Takes column data (NUM_ROWS pixels) and applies boundary padding:
//   - When window extends beyond image boundaries, use nearest valid pixel
//   - Padding value = boundary replication (nearest valid pixel)
//
// 5x5 window position mapping (pos = 0 to 4):
//   pos[0]: y = center_y - 2 (oldest)
//   pos[1]: y = center_y - 1
//   pos[2]: y = center_y     (center)
//   pos[3]: y = center_y + 1
//   pos[4]: y = center_y + 2 (newest)
//
// Padding rules:
//   Top boundary (center_y < PAD_SIZE):
//     pos[0]: pad when center_y < 2
//     pos[1]: pad when center_y < 1
//   Bottom boundary (center_y >= img_height - PAD_SIZE):
//     pos[3]: pad when center_y >= img_height - 1
//     pos[4]: pad when center_y >= img_height - 2
//   Left/Right boundary: uses col[2] value (nearest valid column)
//
// Padding value = nearest valid position (pos[2] = center row)
//
// Parameters:
//   DATA_WIDTH   - bits per pixel
//   PACK_PIXELS  - pixels per word
//   NUM_ROWS     - number of rows in column
//   PAD_SIZE     - padding size (default 2)
//-----------------------------------------------------------------------------

module common_padding #(
    parameter DATA_WIDTH   = 10,
    parameter PACK_PIXELS  = 2,
    parameter NUM_ROWS     = 4,
    parameter PAD_SIZE     = 2
)(
    input  wire [$clog2(8192)-1:0]                              center_x,
    input  wire [$clog2(8192)-1:0]                              center_y,
    input  wire [$clog2(8192)-1:0]                              img_width,
    input  wire [$clog2(8192)-1:0]                              img_height,

    // Input column data (from SRAM read)
    input  wire [DATA_WIDTH*PACK_PIXELS*NUM_ROWS-1:0]         rd_data,
    input  wire                                                rd_data_valid,

    // Output padded column (data_wi_fb interface)
    output wire [DATA_WIDTH*PACK_PIXELS*NUM_ROWS-1:0]          dout,
    output wire                                                dout_valid
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam PACK_DW = DATA_WIDTH * PACK_PIXELS;

    //=========================================================================
    // Padding Logic
    //=========================================================================
    //
    // For each row position p in the column:
    //   - Determine if Y-direction padding is needed based on center_y
    //   - Y padding occurs when: center_y - 2 + p < 0 OR >= img_height
    //   - When Y padding needed, use value from row[2] (nearest valid)
    //
    // X-direction padding uses col[2] (nearest valid column)
    //=========================================================================

    genvar p;
    generate
        for (p = 0; p < NUM_ROWS; p = p + 1) begin : gen_pad
            // Extract row p raw data
            wire [PACK_DW-1:0] row_raw = rd_data[p*PACK_DW +: PACK_DW];
            // Nearest valid = center row (row[2])
            wire [PACK_DW-1:0] pad_val = rd_data[2*PACK_DW +: PACK_DW];

            // Y-direction padding: row p needs padding when out of [0, img_height-1]
            // Row p has absolute y = center_y - 2 + p
            // pad when: center_y - 2 + p < 0  OR center_y - 2 + p >= img_height
            //         => center_y < 2 - p     OR center_y >= img_height + 2 - p
            //
            // For PAD_SIZE=2:
            //   p=0: pad when center_y < 2 OR center_y >= img_height + 2
            //   p=1: pad when center_y < 1 OR center_y >= img_height + 1
            //   p=2: never pad
            //   p=3: pad when center_y >= img_height - 1
            //   p=4: pad when center_y >= img_height - 2

            wire pad_y;
            case (p)
                0: pad_y = (center_y < PAD_SIZE) | (center_y >= img_height + PAD_SIZE);
                1: pad_y = (center_y < PAD_SIZE - 1) | (center_y >= img_height + PAD_SIZE - 1);
                2: pad_y = 1'b0;
                3: pad_y = (center_y >= img_height - PAD_SIZE + 1);
                4: pad_y = (center_y >= img_height - PAD_SIZE);
                default: pad_y = 1'b0;
            endcase

            // X-direction padding: all rows use col[2] when at left/right boundary
            wire pad_x = (center_x < PAD_SIZE) | (center_x >= img_width - PAD_SIZE);

            // Combined padding
            wire do_pad = pad_x | pad_y;

            // Output
            assign dout[p*PACK_DW +: PACK_DW] = do_pad ? pad_val : row_raw;
        end
    endgenerate

    // dout_valid follows rd_data_valid (pipelined padding, no additional latency)
    assign dout_valid = rd_data_valid;

endmodule
