//-----------------------------------------------------------------------------
// Module: common_padding
// Purpose: Boundary padding for 5x5 window operations
//          Applies boundary replication padding to column data
// Author: rtl-impl
// Date: 2026-04-20
// Modified: 2026-04-20
//-----------------------------------------------------------------------------
// Description:
//   Takes 5x5 window data and applies boundary padding:
//   - 5 columns, each with 5 pixels (5 rows)
//   - When window extends beyond image boundaries, use nearest valid pixel
//   - Padding value = boundary replication (nearest valid pixel)
//
// 5x5 window position mapping:
//   - Columns: x-2, x-1, x, x+1, x+2 (col 0 = oldest, col 4 = newest)
//   - Rows: y-2, y-1, y, y+1, y+2 (row 0 = oldest, row 4 = newest)
//
// Padding rules:
//   Top boundary (center_y < PAD_SIZE):
//     row 0: pad when center_y < 2
//     row 1: pad when center_y < 1
//   Bottom boundary (center_y >= img_height - PAD_SIZE):
//     row 3: pad when center_y >= img_height - 1
//     row 4: pad when center_y >= img_height - 2
//   Left/Right boundary: uses center column value (col 2)
//
// Padding value = nearest valid position (center = row 2, col 2)
//
// Parameters:
//   DATA_WIDTH   - bits per pixel
//   NUM_COLS     - number of columns in window (5 for 5x5)
//   NUM_ROWS     - number of rows in window (5 for 5x5)
//   PAD_SIZE     - padding size (default 2)
//-----------------------------------------------------------------------------

module common_padding #(
    parameter DATA_WIDTH   = 10,
    parameter NUM_COLS     = 5,
    parameter NUM_ROWS     = 5,
    parameter PAD_SIZE     = 2
)(
    input  wire [$clog2(8192)-1:0]                              center_x,
    input  wire [$clog2(8192)-1:0]                              center_y,
    input  wire [$clog2(8192)-1:0]                              img_width,
    input  wire [$clog2(8192)-1:0]                              img_height,

    // Input 5x5 window data (5 columns, each with NUM_ROWS pixels)
    // Format: {col4, col3, col2, col1, col0} where each col has NUM_ROWS pixels
    // Each pixel is DATA_WIDTH bits
    input  wire [DATA_WIDTH*NUM_COLS*NUM_ROWS-1:0]             rd_data,
    input  wire                                                rd_data_valid,

    // Output padded 5x5 window
    output wire [DATA_WIDTH*NUM_COLS*NUM_ROWS-1:0]            dout,
    output wire                                                dout_valid
);

    //=========================================================================
    // Padding Logic
    //=========================================================================
    // For 5x5 window:
    //   - 5 columns at positions x-2, x-1, x, x+1, x+2
    //   - 5 rows at positions y-2, y-1, y, y+1, y+2
    //
    // Y-direction padding (top boundary):
    //   row 0 (y-2): pad when center_y < 2
    //   row 1 (y-1): pad when center_y < 1
    //   row 2 (y): never pad
    //   row 3 (y+1): pad when center_y >= img_height - 1
    //   row 4 (y+2): pad when center_y >= img_height - 2
    //
    // X-direction padding:
    //   col 0 (x-2): pad when center_x < 2
    //   col 1 (x-1): pad when center_x < 1
    //   col 2 (x): never pad
    //   col 3 (x+1): pad when center_x >= img_width - 1
    //   col 4 (x+2): pad when center_x >= img_width - 2
    //
    // Padding value = nearest valid position (center = row 2, col 2)
    //=========================================================================

    genvar col, row;
    generate
        for (col = 0; col < NUM_COLS; col = col + 1) begin : gen_pad_cols
            for (row = 0; row < NUM_ROWS; row = row + 1) begin : gen_pad_rows
                // Extract pixel at (col, row)
                wire [DATA_WIDTH-1:0] pixel_raw = rd_data[
                    col * NUM_ROWS * DATA_WIDTH + row * DATA_WIDTH +: DATA_WIDTH];

                // Center pixel (col=2, row=2) = padding value
                wire [DATA_WIDTH-1:0] pad_val = rd_data[
                    2 * NUM_ROWS * DATA_WIDTH + 2 * DATA_WIDTH +: DATA_WIDTH];

                // Y-direction padding
                // Row r has absolute y = center_y - 2 + r
                // pad when: center_y - 2 + r < 0  OR center_y - 2 + r >= img_height
                wire pad_y;
                case (row)
                    0: pad_y = (center_y < PAD_SIZE) | (center_y >= img_height + PAD_SIZE);
                    1: pad_y = (center_y < PAD_SIZE - 1) | (center_y >= img_height + PAD_SIZE - 1);
                    2: pad_y = 1'b0;  // center row, never pad in Y
                    3: pad_y = (center_y >= img_height - PAD_SIZE + 1);
                    4: pad_y = (center_y >= img_height - PAD_SIZE);
                    default: pad_y = 1'b0;
                endcase

                // X-direction padding
                // Column c has absolute x = center_x - 2 + c
                // pad when: center_x - 2 + c < 0  OR center_x - 2 + c >= img_width
                wire pad_x;
                case (col)
                    0: pad_x = (center_x < PAD_SIZE) | (center_x >= img_width + PAD_SIZE);
                    1: pad_x = (center_x < PAD_SIZE - 1) | (center_x >= img_width + PAD_SIZE - 1);
                    2: pad_x = 1'b0;  // center column, never pad in X
                    3: pad_x = (center_x >= img_width - PAD_SIZE + 1);
                    4: pad_x = (center_x >= img_width - PAD_SIZE);
                    default: pad_x = 1'b0;
                endcase

                // Combined padding: use padding value if either direction needs padding
                wire do_pad = pad_x | pad_y;

                assign dout[col * NUM_ROWS * DATA_WIDTH + row * DATA_WIDTH +: DATA_WIDTH] =
                       do_pad ? pad_val : pixel_raw;
            end
        end
    endgenerate

    // dout_valid follows rd_data_valid (combinational padding, no additional latency)
    assign dout_valid = rd_data_valid;

endmodule
