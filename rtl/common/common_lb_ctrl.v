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
//   READ_START_THRESHOLD - gradient path starts reading when valid_row_cnt >= this
//-----------------------------------------------------------------------------

module common_lb_ctrl #(
    parameter DATA_WIDTH            = 10,  // bits per pixel
    parameter LINE_ADDR_WIDTH       = 14,  // IMG_WIDTH/2 depth
    parameter NUM_ROWS              = 4,   // number of rows in line buffer
    parameter PACK_PIXELS           = 2,   // pixels per word
    parameter PAD_SIZE              = 2,   // padding size (2 for 5x5 window)
    parameter READ_START_THRESHOLD  = 4    // start reading when valid_row_cnt >= this
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
    output wire [DATA_WIDTH*5*5-1:0]        dout,
    output wire                              dout_valid,
    input  wire                              dout_ready,

    // Frame signals
    input  wire                              sof,
    input  wire                              eol
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam CTR_WIDTH     = $clog2(NUM_ROWS+1);
    localparam PACK_DW       = DATA_WIDTH * PACK_PIXELS;           // 2P width
    localparam FIFO_DEPTH    = 8;
    localparam FIFO_ADDR_W   = $clog2(FIFO_DEPTH);

    //=========================================================================
    // Internal Signals - s2p (1P → 2P)
    //=========================================================================
    wire [PACK_DW-1:0]                        s2p_dout;
    wire                                      s2p_dout_valid;
    wire                                      s2p_din_ready;

    //=========================================================================
    // Internal Signals - fifo_din (buffer current 1P pixel)
    //=========================================================================
    wire                                      fifo_wr;
    wire [DATA_WIDTH-1:0]                    fifo_wdata;
    wire                                      fifo_rd;
    wire [DATA_WIDTH-1:0]                    fifo_rdata;
    wire                                      fifo_empty;
    wire                                      fifo_full;

    //=========================================================================
    // Internal Signals - p2s (4 rows 2P → 4 cols 1P)
    //=========================================================================
    wire [DATA_WIDTH*NUM_ROWS-1:0]          p2s_dout;
    wire                                      p2s_dout_valid;
    wire                                      p2s_din_ready;

    //=========================================================================
    // Internal Signals - padding
    //=========================================================================
    wire [DATA_WIDTH*5*5-1:0]                pad_dout;
    wire                                      pad_dout_valid;

    //=========================================================================
    // Handshake indicators
    //=========================================================================
    wire                                      wr_shake;
    wire                                      rd_shake;

    //=========================================================================
    // Write Side
    //=========================================================================
    reg [CTR_WIDTH-1:0]                    valid_row_cnt;
    reg [$clog2(NUM_ROWS)-1:0]             wr_row_ptr;
    reg [LINE_ADDR_WIDTH-1:0]               wr_col_ptr;
    reg                                      row_started;

    //=========================================================================
    // Read Side
    //=========================================================================
    reg [$clog2(NUM_ROWS)-1:0]             rd_row_ptr;
    reg [LINE_ADDR_WIDTH-1:0]               rd_col_ptr;
    reg                                      rd_active;

    //=========================================================================
    // p2s buffering (5x5 window assembly)
    //=========================================================================
    // p2s outputs PACK_PIXELS columns per cycle, each column has NUM_ROWS pixels
    // For 5x5 window: we need 5 columns, so we need to buffer across cycles
    //=========================================================================
    reg [DATA_WIDTH*NUM_ROWS-1:0]          p2s_buf0;
    reg [DATA_WIDTH*NUM_ROWS-1:0]          p2s_buf1;
    reg [DATA_WIDTH*NUM_ROWS-1:0]          p2s_buf2;
    reg [DATA_WIDTH*NUM_ROWS-1:0]          p2s_buf3;
    reg [DATA_WIDTH-1:0]                   cur_buf [0:3];
    reg [2:0]                              rd_cycle;
    reg                                      buf_valid;

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

    //=========================================================================
    // Handshake signals
    //=========================================================================
    assign wr_shake = enable && s2p_dout_valid && s2p_din_ready;
    assign rd_shake = enable && p2s_dout_valid && p2s_din_ready;

    assign fifo_wr    = din_valid && s2p_din_ready && enable;
    assign fifo_wdata = din;
    assign fifo_rd    = rd_shake;

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
    // wr_col_ptr
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
        end else if (sof) begin
            wr_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
        end else if (wr_shake) begin
            wr_col_ptr <= wr_col_ptr + 1'b1;
        end else if (eol_fire) begin
            wr_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
        end
    end

    //=========================================================================
    // row_started
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_started <= 1'b0;
        end else if (sof) begin
            row_started <= 1'b0;
        end else if (wr_shake) begin
            row_started <= 1'b1;
        end else if (eol_fire) begin
            row_started <= 1'b0;
        end
    end

    //=========================================================================
    // wr_row_ptr
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_row_ptr <= {$clog2(NUM_ROWS){1'b0}};
        end else if (sof) begin
            wr_row_ptr <= {$clog2(NUM_ROWS){1'b0}};
        end else if (eol_fire && row_started) begin
            wr_row_ptr <= (wr_row_ptr == NUM_ROWS-1) ? {$clog2(NUM_ROWS){1'b0}}
                                                      : wr_row_ptr + 1'b1;
        end
    end

    //=========================================================================
    // valid_row_cnt
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_row_cnt <= {CTR_WIDTH{1'b0}};
        end else if (sof) begin
            valid_row_cnt <= {CTR_WIDTH{1'b0}};
        end else if (enable) begin
            if (eol_fire && row_started && valid_row_cnt < NUM_ROWS) begin
                valid_row_cnt <= valid_row_cnt + 1'b1;
            end
        end
    end

    //=========================================================================
    // rd_col_ptr
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
        end else if (sof) begin
            rd_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
        end else if (buf_valid && dout_ready) begin
            if (rd_col_ptr >= img_width - 1) begin
                rd_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
            end else begin
                rd_col_ptr <= rd_col_ptr + 1'b1;
            end
        end
    end

    //=========================================================================
    // rd_row_ptr
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_row_ptr <= {$clog2(NUM_ROWS){1'b0}};
        end else if (sof) begin
            rd_row_ptr <= {$clog2(NUM_ROWS){1'b0}};
        end else if (buf_valid && dout_ready && rd_col_ptr >= img_width - 1) begin
            rd_row_ptr <= (rd_row_ptr == NUM_ROWS-1) ? {$clog2(NUM_ROWS){1'b0}}
                                                      : rd_row_ptr + 1'b1;
        end
    end

    //=========================================================================
    // rd_active
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_active <= 1'b0;
        end else if (sof) begin
            rd_active <= 1'b0;
        end else if (enable) begin
            if (valid_row_cnt >= READ_START_THRESHOLD && !rd_active) begin
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

    //=========================================================================
    // p2s_buf0
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p2s_buf0 <= {DATA_WIDTH*NUM_ROWS{1'b0}};
        end else if (sof) begin
            p2s_buf0 <= {DATA_WIDTH*NUM_ROWS{1'b0}};
        end else if (rd_shake && rd_cycle == 3'd0) begin
            p2s_buf0 <= p2s_dout;
        end
    end

    //=========================================================================
    // p2s_buf1
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p2s_buf1 <= {DATA_WIDTH*NUM_ROWS{1'b0}};
        end else if (sof) begin
            p2s_buf1 <= {DATA_WIDTH*NUM_ROWS{1'b0}};
        end else if (rd_shake && rd_cycle == 3'd1) begin
            p2s_buf1 <= p2s_dout;
        end
    end

    //=========================================================================
    // p2s_buf2
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p2s_buf2 <= {DATA_WIDTH*NUM_ROWS{1'b0}};
        end else if (sof) begin
            p2s_buf2 <= {DATA_WIDTH*NUM_ROWS{1'b0}};
        end else if (rd_shake && rd_cycle == 3'd2) begin
            p2s_buf2 <= p2s_dout;
        end
    end

    //=========================================================================
    // p2s_buf3
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p2s_buf3 <= {DATA_WIDTH*NUM_ROWS{1'b0}};
        end else if (sof) begin
            p2s_buf3 <= {DATA_WIDTH*NUM_ROWS{1'b0}};
        end else if (rd_shake && rd_cycle == 3'd3) begin
            p2s_buf3 <= p2s_dout;
        end
    end

    //=========================================================================
    // cur_buf[0]
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_buf[0] <= {DATA_WIDTH{1'b0}};
        end else if (sof) begin
            cur_buf[0] <= {DATA_WIDTH{1'b0}};
        end else if (rd_shake && rd_cycle == 3'd0) begin
            cur_buf[0] <= fifo_rdata;
        end
    end

    //=========================================================================
    // cur_buf[1]
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_buf[1] <= {DATA_WIDTH{1'b0}};
        end else if (sof) begin
            cur_buf[1] <= {DATA_WIDTH{1'b0}};
        end else if (rd_shake && rd_cycle == 3'd1) begin
            cur_buf[1] <= fifo_rdata;
        end
    end

    //=========================================================================
    // cur_buf[2]
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_buf[2] <= {DATA_WIDTH{1'b0}};
        end else if (sof) begin
            cur_buf[2] <= {DATA_WIDTH{1'b0}};
        end else if (rd_shake && rd_cycle == 3'd2) begin
            cur_buf[2] <= fifo_rdata;
        end
    end

    //=========================================================================
    // cur_buf[3]
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_buf[3] <= {DATA_WIDTH{1'b0}};
        end else if (sof) begin
            cur_buf[3] <= {DATA_WIDTH{1'b0}};
        end else if (rd_shake && rd_cycle == 3'd3) begin
            cur_buf[3] <= fifo_rdata;
        end
    end

    //=========================================================================
    // rd_cycle
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_cycle <= 3'd0;
        end else if (sof) begin
            rd_cycle <= 3'd0;
        end else if (rd_shake) begin
            rd_cycle <= rd_cycle + 1'b1;
        end
    end

    //=========================================================================
    // buf_valid
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf_valid <= 1'b0;
        end else if (sof) begin
            buf_valid <= 1'b0;
        end else if (rd_shake && rd_cycle == 3'd3) begin
            buf_valid <= 1'b1;
        end else if (buf_valid && dout_ready) begin
            buf_valid <= 1'b0;
        end
    end

    //=========================================================================
    // Assemble 5x5 window from buffered columns for padding
    //=========================================================================
    // 5 columns, each with 5 pixels (rows 0-4)
    // rows 0-3 from p2s_buf, row 4 from cur_buf (current pixel duplicated)
    //
    // Window format: {col4, col3, col2, col1, col0} where colX = {p4, p3, p2, p1, p0}
    //=========================================================================
    wire [DATA_WIDTH*5*5-1:0] window_5x5;

    genvar row_idx;
    generate
        for (row_idx = 0; row_idx < NUM_ROWS; row_idx = row_idx + 1) begin : gen_window_rows
            assign window_5x5[row_idx * DATA_WIDTH +: DATA_WIDTH] =
                   p2s_buf0[row_idx * DATA_WIDTH +: DATA_WIDTH];
            assign window_5x5[5 * DATA_WIDTH + row_idx * DATA_WIDTH +: DATA_WIDTH] =
                   p2s_buf1[row_idx * DATA_WIDTH +: DATA_WIDTH];
            assign window_5x5[2 * 5 * DATA_WIDTH + row_idx * DATA_WIDTH +: DATA_WIDTH] =
                   p2s_buf2[row_idx * DATA_WIDTH +: DATA_WIDTH];
            assign window_5x5[3 * 5 * DATA_WIDTH + row_idx * DATA_WIDTH +: DATA_WIDTH] =
                   p2s_buf3[row_idx * DATA_WIDTH +: DATA_WIDTH];
        end
    endgenerate

    genvar col_idx;
    generate
        for (col_idx = 0; col_idx < 5; col_idx = col_idx + 1) begin : gen_cur_row
            assign window_5x5[4 * DATA_WIDTH + col_idx * 5 * DATA_WIDTH +: DATA_WIDTH] =
                   cur_buf[col_idx % 4];
        end
    endgenerate

    //=========================================================================
    // Padding Instance
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
    // Output assignments
    //=========================================================================
    assign dout       = pad_dout;
    assign dout_valid = pad_dout_valid;
    assign rows_ready = (valid_row_cnt >= READ_START_THRESHOLD);
    assign din_ready  = s2p_din_ready && enable && !fifo_full;

    //=========================================================================
    // Write control
    //=========================================================================
    assign wr_en   = wr_shake;
    assign wr_addr = wr_col_ptr;
    assign wr_data = s2p_dout;

    genvar g;
    generate
        for (g = 0; g < NUM_ROWS; g = g + 1) begin : gen_wr_row_en
            assign wr_row_en[g] = (wr_row_ptr == g) && wr_en;
        end
    endgenerate

    //=========================================================================
    // Read control
    //=========================================================================
    assign rd_en   = rd_active;
    assign rd_addr = rd_col_ptr;

endmodule
