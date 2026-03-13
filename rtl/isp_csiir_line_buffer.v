//-----------------------------------------------------------------------------
// Module: isp_csiir_line_buffer
// Description: 5x5 sliding window line buffer for ISP-CSIIR
//              Generates a 5x5 pixel window centered on current pixel
//              Pure Verilog-2001 compatible
//              Fully parameterized for resolution and data width
//-----------------------------------------------------------------------------

module isp_csiir_line_buffer #(
    parameter IMG_WIDTH         = 5472,                     // Maximum image width
    parameter DATA_WIDTH        = 10,                       // Pixel data width
    parameter LINE_ADDR_WIDTH   = 14,                       // log2(IMG_WIDTH) + margin
    parameter ROW_CNT_WIDTH     = 13                        // log2(IMG_HEIGHT) + margin
)(
    input  wire                      clk,
    input  wire                      rst_n,

    // Control
    input  wire                      enable,
    input  wire                      sof,          // Start of frame
    input  wire                      eol,          // End of line

    // Data input
    input  wire [DATA_WIDTH-1:0]     din,
    input  wire                      din_valid,

    // 5x5 window output
    output wire [DATA_WIDTH-1:0]     window_0_0, window_0_1, window_0_2, window_0_3, window_0_4,
    output wire [DATA_WIDTH-1:0]     window_1_0, window_1_1, window_1_2, window_1_3, window_1_4,
    output wire [DATA_WIDTH-1:0]     window_2_0, window_2_1, window_2_2, window_2_3, window_2_4,
    output wire [DATA_WIDTH-1:0]     window_3_0, window_3_1, window_3_2, window_3_3, window_3_4,
    output wire [DATA_WIDTH-1:0]     window_4_0, window_4_1, window_4_2, window_4_3, window_4_4,
    output reg                       window_valid,

    // Boundary mode: 00=zero, 01=replicate, 10=mirror
    input  wire [1:0]                boundary_mode
);

    `include "isp_csiir_defines.vh"

    // Local parameters
    localparam NUM_LINES = 4;                                   // Number of line buffers (for 5x5 window)
    localparam ROW_CNT_BITS = ROW_CNT_WIDTH;                    // Row counter width

    //=========================================================================
    // Line Buffer Memory
    //=========================================================================
    // 4 lines of pixels for 5x5 window generation
    // For 8K 10-bit: 4 * 5472 * 10 = 218,880 bits per channel
    reg [DATA_WIDTH-1:0] line_mem_0 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] line_mem_1 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] line_mem_2 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] line_mem_3 [0:IMG_WIDTH-1];

    //=========================================================================
    // Pointers and Counters
    //=========================================================================
    reg [LINE_ADDR_WIDTH-1:0] wr_ptr;
    reg [LINE_ADDR_WIDTH-1:0] col_cnt;
    reg [ROW_CNT_BITS-1:0]    row_cnt;

    // Line valid signals
    reg [NUM_LINES-1:0] line_valid;

    //=========================================================================
    // Shift Registers for 5x5 Window
    //=========================================================================
    // Vertical shift registers (column pipeline)
    reg [DATA_WIDTH-1:0] col_shift_0, col_shift_1, col_shift_2, col_shift_3, col_shift_4;

    // Horizontal shift registers for each row (5 taps per row)
    reg [DATA_WIDTH-1:0] row0_tap0, row0_tap1, row0_tap2, row0_tap3, row0_tap4;
    reg [DATA_WIDTH-1:0] row1_tap0, row1_tap1, row1_tap2, row1_tap3, row1_tap4;
    reg [DATA_WIDTH-1:0] row2_tap0, row2_tap1, row2_tap2, row2_tap3, row2_tap4;
    reg [DATA_WIDTH-1:0] row3_tap0, row3_tap1, row3_tap2, row3_tap3, row3_tap4;
    reg [DATA_WIDTH-1:0] row4_tap0, row4_tap1, row4_tap2, row4_tap3, row4_tap4;

    //=========================================================================
    // Line Buffer Write and Address Logic
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr     <= {LINE_ADDR_WIDTH{1'b0}};
            col_cnt    <= {LINE_ADDR_WIDTH{1'b0}};
            row_cnt    <= {ROW_CNT_BITS{1'b0}};
            line_valid <= 4'b0000;
        end else if (enable) begin
            if (din_valid) begin
                // Write current pixel to line 0
                line_mem_0[wr_ptr] <= din;

                // Propagate through line buffers (FIFO behavior)
                if (line_valid[0])
                    line_mem_1[wr_ptr] <= line_mem_0[wr_ptr];
                if (line_valid[1])
                    line_mem_2[wr_ptr] <= line_mem_1[wr_ptr];
                if (line_valid[2])
                    line_mem_3[wr_ptr] <= line_mem_2[wr_ptr];

                // Update pointers
                if (eol || col_cnt == IMG_WIDTH - 1) begin
                    wr_ptr  <= {LINE_ADDR_WIDTH{1'b0}};
                    col_cnt <= {LINE_ADDR_WIDTH{1'b0}};
                    line_valid <= {line_valid[2:0], 1'b1};
                    if (row_cnt < {ROW_CNT_BITS{1'b1}})
                        row_cnt <= row_cnt + {{ROW_CNT_BITS-1{1'b0}}, 1'b1};
                end else begin
                    wr_ptr  <= wr_ptr + {{LINE_ADDR_WIDTH-1{1'b0}}, 1'b1};
                    col_cnt <= col_cnt + {{LINE_ADDR_WIDTH-1{1'b0}}, 1'b1};
                end
            end

            // Reset on SOF
            if (sof) begin
                wr_ptr     <= {LINE_ADDR_WIDTH{1'b0}};
                col_cnt    <= {LINE_ADDR_WIDTH{1'b0}};
                row_cnt    <= {ROW_CNT_BITS{1'b0}};
                line_valid <= 4'b0000;
            end
        end
    end

    //=========================================================================
    // Column Shift Register (Vertical Pipeline)
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_shift_0   <= {DATA_WIDTH{1'b0}};
            col_shift_1   <= {DATA_WIDTH{1'b0}};
            col_shift_2   <= {DATA_WIDTH{1'b0}};
            col_shift_3   <= {DATA_WIDTH{1'b0}};
            col_shift_4   <= {DATA_WIDTH{1'b0}};
            window_valid  <= 1'b0;
        end else if (enable && din_valid) begin
            // Shift column data (newest at bottom, oldest at top)
            col_shift_0 <= col_shift_1;
            col_shift_1 <= col_shift_2;
            col_shift_2 <= col_shift_3;
            col_shift_3 <= col_shift_4;
            col_shift_4 <= din;

            // Window valid after 2 rows and 2 columns filled
            window_valid <= (row_cnt >= {{ROW_CNT_BITS-2{1'b0}}, 2'd2}) &&
                            (col_cnt >= {{LINE_ADDR_WIDTH-2{1'b0}}, 2'd2});
        end else begin
            window_valid <= 1'b0;
        end
    end

    //=========================================================================
    // Horizontal Shift Registers for Each Row
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Row 0
            row0_tap0 <= {DATA_WIDTH{1'b0}};
            row0_tap1 <= {DATA_WIDTH{1'b0}};
            row0_tap2 <= {DATA_WIDTH{1'b0}};
            row0_tap3 <= {DATA_WIDTH{1'b0}};
            row0_tap4 <= {DATA_WIDTH{1'b0}};
            // Row 1
            row1_tap0 <= {DATA_WIDTH{1'b0}};
            row1_tap1 <= {DATA_WIDTH{1'b0}};
            row1_tap2 <= {DATA_WIDTH{1'b0}};
            row1_tap3 <= {DATA_WIDTH{1'b0}};
            row1_tap4 <= {DATA_WIDTH{1'b0}};
            // Row 2
            row2_tap0 <= {DATA_WIDTH{1'b0}};
            row2_tap1 <= {DATA_WIDTH{1'b0}};
            row2_tap2 <= {DATA_WIDTH{1'b0}};
            row2_tap3 <= {DATA_WIDTH{1'b0}};
            row2_tap4 <= {DATA_WIDTH{1'b0}};
            // Row 3
            row3_tap0 <= {DATA_WIDTH{1'b0}};
            row3_tap1 <= {DATA_WIDTH{1'b0}};
            row3_tap2 <= {DATA_WIDTH{1'b0}};
            row3_tap3 <= {DATA_WIDTH{1'b0}};
            row3_tap4 <= {DATA_WIDTH{1'b0}};
            // Row 4
            row4_tap0 <= {DATA_WIDTH{1'b0}};
            row4_tap1 <= {DATA_WIDTH{1'b0}};
            row4_tap2 <= {DATA_WIDTH{1'b0}};
            row4_tap3 <= {DATA_WIDTH{1'b0}};
            row4_tap4 <= {DATA_WIDTH{1'b0}};
        end else if (enable && din_valid) begin
            // Row 0: shift left, load from col_shift_0
            row0_tap0 <= row0_tap1;
            row0_tap1 <= row0_tap2;
            row0_tap2 <= row0_tap3;
            row0_tap3 <= row0_tap4;
            row0_tap4 <= col_shift_0;

            // Row 1: shift left, load from col_shift_1
            row1_tap0 <= row1_tap1;
            row1_tap1 <= row1_tap2;
            row1_tap2 <= row1_tap3;
            row1_tap3 <= row1_tap4;
            row1_tap4 <= col_shift_1;

            // Row 2: shift left, load from col_shift_2
            row2_tap0 <= row2_tap1;
            row2_tap1 <= row2_tap2;
            row2_tap2 <= row2_tap3;
            row2_tap3 <= row2_tap4;
            row2_tap4 <= col_shift_2;

            // Row 3: shift left, load from col_shift_3
            row3_tap0 <= row3_tap1;
            row3_tap1 <= row3_tap2;
            row3_tap2 <= row3_tap3;
            row3_tap3 <= row3_tap4;
            row3_tap4 <= col_shift_3;

            // Row 4: shift left, load from col_shift_4
            row4_tap0 <= row4_tap1;
            row4_tap1 <= row4_tap2;
            row4_tap2 <= row4_tap3;
            row4_tap3 <= row4_tap4;
            row4_tap4 <= col_shift_4;
        end
    end

    //=========================================================================
    // Output Assignments (window[r][c] = row_r_tap_c)
    //=========================================================================
    // Row 0
    assign window_0_0 = row0_tap0;
    assign window_0_1 = row0_tap1;
    assign window_0_2 = row0_tap2;
    assign window_0_3 = row0_tap3;
    assign window_0_4 = row0_tap4;
    // Row 1
    assign window_1_0 = row1_tap0;
    assign window_1_1 = row1_tap1;
    assign window_1_2 = row1_tap2;
    assign window_1_3 = row1_tap3;
    assign window_1_4 = row1_tap4;
    // Row 2
    assign window_2_0 = row2_tap0;
    assign window_2_1 = row2_tap1;
    assign window_2_2 = row2_tap2;
    assign window_2_3 = row2_tap3;
    assign window_2_4 = row2_tap4;
    // Row 3
    assign window_3_0 = row3_tap0;
    assign window_3_1 = row3_tap1;
    assign window_3_2 = row3_tap2;
    assign window_3_3 = row3_tap3;
    assign window_3_4 = row3_tap4;
    // Row 4
    assign window_4_0 = row4_tap0;
    assign window_4_1 = row4_tap1;
    assign window_4_2 = row4_tap2;
    assign window_4_3 = row4_tap3;
    assign window_4_4 = row4_tap4;

endmodule