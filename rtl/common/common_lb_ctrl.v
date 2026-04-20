//-----------------------------------------------------------------------------
// Module: common_lb_ctrl
// Purpose: Line buffer control with din merging for 5x5 window
//          Integrates: s2p, linebuffer, p2s, fifo_din, padding
// Author: rtl-impl
// Date: 2026-04-18
// Modified: 2026-04-20
//-----------------------------------------------------------------------------
// Description:
//   5x5 Window Data Path:
//     - Linebuffer stores 4 rows × 2P (past pixel history)
//     - Current pixel (din) stored in fifo_din
//     - p2s converts 4 rows × 2P → 2 columns × 4 pixels (per cycle)
//     - Need to buffer across cycles to form full 5 columns
//     - Current pixel (col 4) duplicated to fill 5th row position
//
//   Output: 5 columns (each column = 5 pixels = 5 rows)
//     - Columns 0-3: from p2s output (buffered across cycles)
//     - Column 4: current pixel (duplicated 5 times)
//
//   Padding is applied to each column (5 pixels) based on position
//
// Parameters:
//   DATA_WIDTH        - bits per pixel
//   LINE_ADDR_WIDTH   - bits for column address
//   NUM_ROWS          - number of rows in line buffer (default 4)
//   PACK_PIXELS       - pixels per word (default 2)
//   PAD_SIZE          - padding size (default 2)
//-----------------------------------------------------------------------------

module common_lb_ctrl #(
    parameter DATA_WIDTH        = 10,  // bits per pixel
    parameter LINE_ADDR_WIDTH   = 14,  // IMG_WIDTH/2 depth
    parameter NUM_ROWS          = 4,   // number of rows in line buffer
    parameter PACK_PIXELS       = 2,   // pixels per word
    parameter PAD_SIZE          = 2    // padding size (2 for 5x5 window)
)(
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire                              enable,

    // Configuration
    input  wire [LINE_ADDR_WIDTH-1:0]       img_width,
    input  wire [LINE_ADDR_WIDTH-1:0]       img_height,

    // Write interface (1P data from upstream)
    input  wire [DATA_WIDTH-1:0]             din,
    input  wire                              din_valid,
    output wire                              din_ready,

    // SRAM interfaces
    output wire [LINE_ADDR_WIDTH-1:0]       wr_addr,
    output wire [NUM_ROWS-1:0]               wr_row_en,
    output wire [DATA_WIDTH*PACK_PIXELS-1:0] wr_data,
    output wire                              wr_en,

    output wire                              rd_en,
    output wire [LINE_ADDR_WIDTH-1:0]       rd_addr,
    input  wire [DATA_WIDTH*PACK_PIXELS*NUM_ROWS-1:0] rd_data,

    // Output (5 columns, each column = 5 pixels = 5 rows)
    // Format: {col4, col3, col2, col1, col0} where colX = {p4, p3, p2, p1, p0}
    output wire                              rows_ready,
    output wire [DATA_WIDTH*5*5-1:0]        dout,  // 5 cols × 5 pixels
    output wire                              dout_valid,
    input  wire                              dout_ready,

    // Frame signals
    input  wire                              sof,
    input  wire                              eol
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam CTR_WIDTH = $clog2(NUM_ROWS+1);
    localparam PACK_DW   = DATA_WIDTH * PACK_PIXELS;           // 2P width
    localparam LB_DW     = PACK_DW * NUM_ROWS;                 // 4 rows × 2P
    localparam FIFO_DEPTH = 8;
    localparam FIFO_ADDR_W = $clog2(FIFO_DEPTH);

    //=========================================================================
    // Internal Signals - s2p (1P → 2P)
    //=========================================================================
    wire [PACK_DW-1:0]            s2p_dout;
    wire                              s2p_dout_valid;
    wire                              s2p_din_ready;

    //=========================================================================
    // Internal Signals - fifo_din (buffer current 1P pixel)
    //=========================================================================
    wire                              fifo_wr;
    wire [DATA_WIDTH-1:0]            fifo_wdata;
    wire                              fifo_rd;
    wire [DATA_WIDTH-1:0]            fifo_rdata;
    wire                              fifo_empty;
    wire                              fifo_full;

    //=========================================================================
    // Internal Signals - p2s (4 rows 2P → 4 cols 1P)
    //=========================================================================
    wire [DATA_WIDTH*NUM_ROWS-1:0] p2s_dout;  // 4 pixels (1 per row)
    wire                              p2s_dout_valid;
    wire                              p2s_din_ready;

    //=========================================================================
    // Internal Signals - padding
    //=========================================================================
    wire [DATA_WIDTH*5*5-1:0]        pad_dout;
    wire                              pad_dout_valid;

    //=========================================================================
    // Write Side
    //=========================================================================
    reg [CTR_WIDTH-1:0]            valid_row_cnt;
    reg [$clog2(NUM_ROWS)-1:0]     wr_row_ptr;
    reg [LINE_ADDR_WIDTH-1:0]       wr_col_ptr;
    reg                             row_started;

    //=========================================================================
    // Read Side
    //=========================================================================
    reg [$clog2(NUM_ROWS)-1:0]     rd_row_ptr;
    reg [LINE_ADDR_WIDTH-1:0]       rd_col_ptr;
    reg                              rd_active;

    //=========================================================================
    // p2s and cur pixel buffering for 5x5 window assembly
    //=========================================================================
    // p2s outputs PACK_PIXELS columns per cycle, each column has NUM_ROWS pixels
    // For 5x5 window: we need 5 columns, so we need to buffer across cycles
    //
    // With PACK_PIXELS=2, p2s outputs 2 columns per cycle:
    //   - p2s_dout[DATA_WIDTH*0 +: DATA_WIDTH] = col0_row0
    //   - p2s_dout[DATA_WIDTH*1 +: DATA_WIDTH] = col0_row1
    //   - ...
    //   - p2s_dout[DATA_WIDTH*PACK_PIXELS*0 +: DATA_WIDTH] = col0_rowN
    //   - p2s_dout[DATA_WIDTH*PACK_PIXELS*1 +: DATA_WIDTH] = col1_rowN
    //
    // For a 5x5 window at position x, we need columns x-2, x-1, x, x+1, x+2
    // With 2P packing: 2 consecutive columns share one SRAM address
    // So we need to read at multiple addresses and buffer p2s outputs
    //
    // Current design limitation: PACK_PIXELS=2 gives only 2 columns per cycle
    // To get 5 columns, we need to read across multiple SRAM addresses
    // and buffer the p2s outputs across cycles.
    //=========================================================================
    // Buffer for p2s outputs (stores NUM_ROWS pixels per column)
    reg [DATA_WIDTH*NUM_ROWS-1:0] p2s_buf0;  // Column 0 from first SRAM read
    reg [DATA_WIDTH*NUM_ROWS-1:0] p2s_buf1;  // Column 1 from first SRAM read
    reg [DATA_WIDTH*NUM_ROWS-1:0] p2s_buf2;  // Column 2 from second SRAM read
    reg [DATA_WIDTH*NUM_ROWS-1:0] p2s_buf3;  // Column 3 from second SRAM read
    reg [DATA_WIDTH-1:0]          cur_buf [0:3];  // Current pixel for each column
    reg [1:0]                     buf_filled;  // Track which buffer slots have data
    reg                              buf_valid;
    reg [2:0]                       rd_cycle;   // Track which read cycle we're in

    //=========================================================================
    // s2p Instance (1P → 2P)
    //=========================================================================
    common_s2p #(.DATA_WIDTH (DATA_WIDTH)) u_s2p (
        .clk        (clk),
        .rst_n      (rst_n),
        .enable     (enable),
        .sof        (sof),
        .din        (din),
        .din_valid  (din_valid),
        .din_ready  (s2p_din_ready),
        .dout       (s2p_dout),
        .dout_valid (s2p_dout_valid)
    );

    //=========================================================================
    // fifo_din Instance
    //=========================================================================
    common_fifo #(
        .DATA_WIDTH (DATA_WIDTH),
        .DEPTH      (FIFO_DEPTH),
        .ADDR_WIDTH (FIFO_ADDR_W)
    ) u_fifo_din (
        .clk        (clk),
        .rst_n      (rst_n),
        .wr_en      (fifo_wr),
        .wr_data    (fifo_wdata),
        .rd_en      (fifo_rd),
        .rd_data    (fifo_rdata),
        .empty      (fifo_empty),
        .full       (fifo_full),
        .count      ()
    );

    assign fifo_wr = din_valid && s2p_din_ready && enable;
    assign fifo_wdata = din;

    //=========================================================================
    // EOL Edge Detection
    //=========================================================================
    reg eol_d1;
    wire eol_fire;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eol_d1 <= 1'b0;
        end else if (sof) begin
            eol_d1 <= 1'b0;
        end else begin
            eol_d1 <= eol;
        end
    end

    assign eol_fire = eol && !eol_d1 && enable;

    //=========================================================================
    // Write Side Logic
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
            row_started <= 1'b0;
        end else if (sof) begin
            wr_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
            row_started <= 1'b0;
        end else if (enable && s2p_dout_valid && s2p_din_ready) begin
            wr_col_ptr <= wr_col_ptr + 1'b1;
            row_started <= 1'b1;
        end else if (eol_fire) begin
            wr_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
            row_started <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_row_ptr <= {$clog2(NUM_ROWS){1'b0}};
        end else if (sof) begin
            wr_row_ptr <= {$clog2(NUM_ROWS){1'b0}};
        end else if (enable && eol_fire && row_started) begin
            wr_row_ptr <= (wr_row_ptr == NUM_ROWS-1) ? {$clog2(NUM_ROWS){1'b0}}
                                                      : wr_row_ptr + 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_row_cnt <= {CTR_WIDTH{1'b0}};
        end else if (sof) begin
            valid_row_cnt <= {CTR_WIDTH{1'b0}};
        end else if (enable) begin
            if (eol_fire && row_started && valid_row_cnt < NUM_ROWS) begin
                valid_row_cnt <= valid_row_cnt + 1'b1;
            end else if (buf_valid && dout_ready && rd_col_ptr >= img_width - 1 && valid_row_cnt > 0) begin
                valid_row_cnt <= valid_row_cnt - 1'b1;
            end
        end
    end

    //=========================================================================
    // Read Side Logic
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
        end else if (sof) begin
            rd_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
        end else if (enable && buf_valid && dout_ready) begin
            if (rd_col_ptr >= img_width - 1) begin
                rd_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
            end else begin
                rd_col_ptr <= rd_col_ptr + 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_row_ptr <= {$clog2(NUM_ROWS){1'b0}};
        end else if (sof) begin
            rd_row_ptr <= {$clog2(NUM_ROWS){1'b0}};
        end else if (enable && buf_valid && dout_ready && rd_col_ptr >= img_width - 1) begin
            rd_row_ptr <= (rd_row_ptr == NUM_ROWS-1) ? {$clog2(NUM_ROWS){1'b0}}
                                                      : rd_row_ptr + 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_active <= 1'b0;
        end else if (sof) begin
            rd_active <= 1'b0;
        end else if (enable) begin
            if (valid_row_cnt == NUM_ROWS && !rd_active) begin
                rd_active <= 1'b1;
            end else if (buf_valid && rd_col_ptr >= img_width - 1) begin
                rd_active <= 1'b0;
            end
        end
    end

    //=========================================================================
    // p2s Instance (4 rows 2P → 4 cols 1P)
    //=========================================================================
    common_p2s #(
        .DATA_WIDTH  (DATA_WIDTH),
        .PACK_PIXELS (PACK_PIXELS),
        .PACK_WAYS   (NUM_ROWS)
    ) u_p2s (
        .clk        (clk),
        .rst_n      (rst_n),
        .enable     (enable),
        .din        (rd_data),
        .din_valid  (rd_active),
        .din_ready  (p2s_din_ready),
        .dout       (p2s_dout),
        .dout_valid (p2s_dout_valid),
        .dout_ready (1'b1),
        .sof        (sof)
    );

    assign fifo_rd = p2s_dout_valid && p2s_din_ready && enable;

    //=========================================================================
    // Buffer Management - Assemble 5 columns from p2s output + current pixel
    //=========================================================================
    // For 5x5 window with PACK_PIXELS=2, p2s outputs 2 columns per cycle.
    // We need 5 columns, so we buffer across multiple cycles.
    //
    // Each p2s_buf stores NUM_ROWS (4) pixels representing one column.
    // The current pixel (from fifo_din) is duplicated to fill row 4.
    //
    // The 5 columns for 5x5 window at position x:
    //   col0: from p2s_buf0 (column x-2)
    //   col1: from p2s_buf1 (column x-1)
    //   col2: from p2s_buf2 (column x)
    //   col3: from p2s_buf3 (column x+1)
    //   col4: cur_buf (current pixel, duplicated for all rows)
    //=========================================================================
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p2s_buf0 <= {DATA_WIDTH*NUM_ROWS{1'b0}};
            p2s_buf1 <= {DATA_WIDTH*NUM_ROWS{1'b0}};
            p2s_buf2 <= {DATA_WIDTH*NUM_ROWS{1'b0}};
            p2s_buf3 <= {DATA_WIDTH*NUM_ROWS{1'b0}};
            for (i = 0; i < 4; i = i + 1) begin
                cur_buf[i] <= {DATA_WIDTH{1'b0}};
            end
            buf_filled <= 2'b00;
            buf_valid <= 1'b0;
            rd_cycle <= 3'd0;
        end else if (sof) begin
            p2s_buf0 <= {DATA_WIDTH*NUM_ROWS{1'b0}};
            p2s_buf1 <= {DATA_WIDTH*NUM_ROWS{1'b0}};
            p2s_buf2 <= {DATA_WIDTH*NUM_ROWS{1'b0}};
            p2s_buf3 <= {DATA_WIDTH*NUM_ROWS{1'b0}};
            for (i = 0; i < 4; i = i + 1) begin
                cur_buf[i] <= {DATA_WIDTH{1'b0}};
            end
            buf_filled <= 2'b00;
            buf_valid <= 1'b0;
            rd_cycle <= 3'd0;
        end else if (enable) begin
            // Capture p2s output and current pixel when rd is active
            if (p2s_dout_valid && p2s_din_ready) begin
                case (rd_cycle)
                    3'd0: begin
                        // First read: columns x-2, x-1
                        p2s_buf0 <= p2s_dout;  // column x-2 (first pixel pair)
                        cur_buf[0] <= fifo_rdata;
                        rd_cycle <= 3'd1;
                    end
                    3'd1: begin
                        // Second read: columns x, x+1
                        p2s_buf1 <= p2s_dout;  // column x-1 (first pixel pair)
                        cur_buf[1] <= fifo_rdata;
                        rd_cycle <= 3'd2;
                    end
                    3'd2: begin
                        // Third read: columns x+2, x+3 (only need x+2)
                        p2s_buf2 <= p2s_dout;  // column x (second pixel pair)
                        cur_buf[2] <= fifo_rdata;
                        rd_cycle <= 3'd3;
                    end
                    3'd3: begin
                        // Fourth read: columns x+4, x+5 (only need x+2)
                        p2s_buf3 <= p2s_dout;  // column x+1 (second pixel pair)
                        cur_buf[3] <= fifo_rdata;
                        rd_cycle <= 3'd0;
                        buf_valid <= 1'b1;  // All columns buffered
                    end
                endcase
            end

            // Clear buffer when output is consumed
            if (buf_valid && dout_ready) begin
                buf_valid <= 1'b0;
                buf_filled <= 2'b00;
            end
        end
    end

    //=========================================================================
    // Assemble 5x5 window from buffered columns for padding
    //=========================================================================
    // 5 columns, each with 5 pixels (rows 0-4)
    // rows 0-3 from p2s_buf, row 4 from cur_buf (current pixel duplicated)
    //
    // Window format: {col4, col3, col2, col1, col0} where colX = {p4, p3, p2, p1, p0}
    // Each pixel is DATA_WIDTH bits
    //=========================================================================
    wire [DATA_WIDTH*5*5-1:0] window_5x5;  // 5 cols × 5 rows

    genvar row_idx;
    generate
        for (row_idx = 0; row_idx < NUM_ROWS; row_idx = row_idx + 1) begin : gen_window_rows
            // Column 0 (oldest, from p2s_buf0)
            assign window_5x5[row_idx * DATA_WIDTH +: DATA_WIDTH] =
                   p2s_buf0[row_idx * DATA_WIDTH +: DATA_WIDTH];
            // Column 1 (from p2s_buf1)
            assign window_5x5[5 * DATA_WIDTH + row_idx * DATA_WIDTH +: DATA_WIDTH] =
                   p2s_buf1[row_idx * DATA_WIDTH +: DATA_WIDTH];
            // Column 2 (from p2s_buf2)
            assign window_5x5[2 * 5 * DATA_WIDTH + row_idx * DATA_WIDTH +: DATA_WIDTH] =
                   p2s_buf2[row_idx * DATA_WIDTH +: DATA_WIDTH];
            // Column 3 (from p2s_buf3)
            assign window_5x5[3 * 5 * DATA_WIDTH + row_idx * DATA_WIDTH +: DATA_WIDTH] =
                   p2s_buf3[row_idx * DATA_WIDTH +: DATA_WIDTH];
        end
    endgenerate

    // Row 4 (current pixel, duplicated for all 5 columns)
    genvar col_idx;
    generate
        for (col_idx = 0; col_idx < 5; col_idx = col_idx + 1) begin : gen_cur_row
            assign window_5x5[4 * DATA_WIDTH + col_idx * 5 * DATA_WIDTH +: DATA_WIDTH] =
                   cur_buf[col_idx % 4];  // Cycle through cur_buf entries
        end
    endgenerate

    //=========================================================================
    // Padding Instance - Apply boundary padding to 5x5 window
    //=========================================================================
    common_padding #(
        .DATA_WIDTH   (DATA_WIDTH),
        .NUM_COLS     (5),
        .NUM_ROWS     (5),
        .PAD_SIZE     (PAD_SIZE)
    ) u_padding (
        .center_x     (rd_col_ptr),
        .center_y     ({12{1'b0}}),  // TODO: proper y coordinate tracking
        .img_width    (img_width),
        .img_height   (img_height),
        .rd_data      (window_5x5),
        .rd_data_valid(buf_valid),
        .dout         (pad_dout),
        .dout_valid   (pad_dout_valid)
    );

    //=========================================================================
    // Output: Connect padded output to dout
    //=========================================================================
    // The padding module outputs the properly padded 5x5 window
    assign dout = pad_dout;
    assign dout_valid = pad_dout_valid;

    // rows_ready indicates window is ready (4 rows + current pixel available)
    assign rows_ready = (valid_row_cnt == NUM_ROWS);

    // Input ready: s2p ready and not full
    assign din_ready = s2p_din_ready && enable && !fifo_full;

    // Write control
    assign wr_en = enable && s2p_dout_valid && s2p_din_ready;
    assign wr_addr = wr_col_ptr;
    assign wr_data = s2p_dout;

    genvar g;
    generate
        for (g = 0; g < NUM_ROWS; g = g + 1) begin : gen_wr_row_en
            assign wr_row_en[g] = (wr_row_ptr == g) && wr_en;
        end
    endgenerate

    // Read control
    assign rd_en = rd_active;
    assign rd_addr = rd_col_ptr;

endmodule
