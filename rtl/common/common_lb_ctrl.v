//-----------------------------------------------------------------------------
// Module: common_lb_ctrl
// Purpose: Line buffer control with din merging for 5x5 window
//          Integrates: s2p, linebuffer, p2s, fifo_din, padding
// Author: rtl-impl
// Date: 2026-04-18
// Modified: 2026-04-21
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
    parameter LINE_ADDR_WIDTH     = 14,  // IMG_WIDTH/2 depth
    parameter NUM_ROWS            = 4,   // number of rows in line buffer
    parameter PACK_PIXELS         = 2,   // pixels per word
    parameter PAD_SIZE            = 2,   // padding size (2 for 5x5 window)
    parameter READ_START_THRESHOLD = 4    // start reading when valid_row_cnt >= this
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
    localparam PACK_DW       = DATA_WIDTH * PACK_PIXELS;
    localparam FIFO_DEPTH    = 8;
    localparam FIFO_ADDR_W   = $clog2(FIFO_DEPTH);

    //=========================================================================
    // Internal Signals - s2p (1P → 2P)
    //=========================================================================
    wire [PACK_DW-1:0]                        s2p_dout;
    wire                                      s2p_dout_valid;
    wire                                      s2p_din_ready;

    //=========================================================================
    // Internal Signals - fifo_din
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
    // Internal Signals - handshake
    //=========================================================================
    wire                                      wr_shake;
    wire                                      rd_shake;
    wire                                      eol_fire;

    //=========================================================================
    // Internal Signals - wr_col_ptr pipeline
    //=========================================================================
    wire                                      pipe_wr_col_ptr_din_valid;
    wire                                      pipe_wr_col_ptr_din_ready;
    wire [LINE_ADDR_WIDTH-1:0]               pipe_wr_col_ptr_din;
    wire [LINE_ADDR_WIDTH-1:0]               pipe_wr_col_ptr_dout;
    wire                                      pipe_wr_col_ptr_dout_valid;
    wire                                      pipe_wr_col_ptr_dout_ready;

    //=========================================================================
    // Internal Signals - wr_row_ptr pipeline
    //=========================================================================
    wire                                      pipe_wr_row_ptr_din_valid;
    wire                                      pipe_wr_row_ptr_din_ready;
    wire [$clog2(NUM_ROWS)-1:0]             pipe_wr_row_ptr_din;
    wire [$clog2(NUM_ROWS)-1:0]               pipe_wr_row_ptr_dout;
    wire                                      pipe_wr_row_ptr_dout_valid;
    wire                                      pipe_wr_row_ptr_dout_ready;

    //=========================================================================
    // Internal Signals - valid_row_cnt pipeline
    //=========================================================================
    wire                                      pipe_valid_row_cnt_din_valid;
    wire                                      pipe_valid_row_cnt_din_ready;
    wire [CTR_WIDTH-1:0]                    pipe_valid_row_cnt_din;
    wire [CTR_WIDTH-1:0]                    pipe_valid_row_cnt_dout;
    wire                                      pipe_valid_row_cnt_dout_valid;
    wire                                      pipe_valid_row_cnt_dout_ready;

    //=========================================================================
    // Internal Signals - rd_col_ptr pipeline
    //=========================================================================
    wire                                      pipe_rd_col_ptr_din_valid;
    wire                                      pipe_rd_col_ptr_din_ready;
    wire [LINE_ADDR_WIDTH-1:0]               pipe_rd_col_ptr_din;
    wire [LINE_ADDR_WIDTH-1:0]               pipe_rd_col_ptr_dout;
    wire                                      pipe_rd_col_ptr_dout_valid;
    wire                                      pipe_rd_col_ptr_dout_ready;

    //=========================================================================
    // Internal Signals - rd_row_ptr pipeline
    //=========================================================================
    wire                                      pipe_rd_row_ptr_din_valid;
    wire                                      pipe_rd_row_ptr_din_ready;
    wire [$clog2(NUM_ROWS)-1:0]             pipe_rd_row_ptr_din;
    wire [$clog2(NUM_ROWS)-1:0]               pipe_rd_row_ptr_dout;
    wire                                      pipe_rd_row_ptr_dout_valid;
    wire                                      pipe_rd_row_ptr_dout_ready;

    //=========================================================================
    // Internal Signals - rd_active pipeline
    //=========================================================================
    wire                                      pipe_rd_active_din_valid;
    wire                                      pipe_rd_active_din_ready;
    wire                                      pipe_rd_active_din;
    wire                                      pipe_rd_active_dout;
    wire                                      pipe_rd_active_dout_valid;
    wire                                      pipe_rd_active_dout_ready;

    //=========================================================================
    // Internal Signals - row_started pipeline
    //=========================================================================
    wire                                      pipe_row_started_din_valid;
    wire                                      pipe_row_started_din_ready;
    wire                                      pipe_row_started_din;
    wire                                      pipe_row_started_dout;
    wire                                      pipe_row_started_dout_valid;
    wire                                      pipe_row_started_dout_ready;

    //=========================================================================
    // Internal Signals - window assembly
    //=========================================================================
    wire [DATA_WIDTH*5*5-1:0]                window_5x5;

    //=========================================================================
    // Raw signals (registered inputs to pipelines)
    //=========================================================================
    reg [LINE_ADDR_WIDTH-1:0]               wr_col_ptr_raw;
    reg [$clog2(NUM_ROWS)-1:0]             wr_row_ptr_raw;
    reg [CTR_WIDTH-1:0]                    valid_row_cnt_raw;
    reg [LINE_ADDR_WIDTH-1:0]               rd_col_ptr_raw;
    reg [$clog2(NUM_ROWS)-1:0]             rd_row_ptr_raw;
    reg                                      rd_active_raw;
    reg                                      row_started_raw;
    reg                                      eol_d1_raw;

    //=========================================================================
    // p2s buffering
    //=========================================================================
    reg [DATA_WIDTH*NUM_ROWS-1:0]          p2s_buf0;
    reg [DATA_WIDTH*NUM_ROWS-1:0]          p2s_buf1;
    reg [DATA_WIDTH*NUM_ROWS-1:0]          p2s_buf2;
    reg [DATA_WIDTH*NUM_ROWS-1:0]          p2s_buf3;
    reg [DATA_WIDTH-1:0]                   cur_buf [0:3];
    reg [2:0]                              rd_cycle;
    reg                                      buf_valid;

    //=========================================================================
    // Handshake signals
    //=========================================================================
    assign wr_shake = enable && s2p_dout_valid && s2p_din_ready;
    assign rd_shake = enable && p2s_dout_valid && p2s_din_ready;
    assign eol_fire = eol && !eol_d1_raw && enable;

    assign fifo_wr    = din_valid && s2p_din_ready && enable;
    assign fifo_wdata = din;
    assign fifo_rd    = rd_shake;

    //=========================================================================
    // wr_col_ptr pipeline logic
    //=========================================================================
    assign pipe_wr_col_ptr_din_valid = sof || wr_shake || eol_fire;
    assign pipe_wr_col_ptr_din_ready = 1'b1;
    assign pipe_wr_col_ptr_din =
        (sof)       ? {LINE_ADDR_WIDTH{1'b0}} :
        (wr_shake)  ? wr_col_ptr_raw + 1'b1 :
        (eol_fire)  ? {LINE_ADDR_WIDTH{1'b0}} :
        wr_col_ptr_raw;

    //=========================================================================
    // wr_row_ptr pipeline logic
    //=========================================================================
    assign pipe_wr_row_ptr_din_valid = sof || (eol_fire && row_started_raw);
    assign pipe_wr_row_ptr_din_ready = 1'b1;
    assign pipe_wr_row_ptr_din =
        (sof)       ? {$clog2(NUM_ROWS){1'b0}} :
        (eol_fire && row_started_raw) ?
            (wr_row_ptr_raw == NUM_ROWS-1) ? {$clog2(NUM_ROWS){1'b0}} : wr_row_ptr_raw + 1'b1 :
        wr_row_ptr_raw;

    //=========================================================================
    // valid_row_cnt pipeline logic
    //=========================================================================
    assign pipe_valid_row_cnt_din_valid = sof || (eol_fire && row_started_raw);
    assign pipe_valid_row_cnt_din_ready = 1'b1;
    assign pipe_valid_row_cnt_din =
        (sof)       ? {CTR_WIDTH{1'b0}} :
        (eol_fire && row_started_raw && valid_row_cnt_raw < NUM_ROWS) ?
            valid_row_cnt_raw + 1'b1 :
        valid_row_cnt_raw;

    //=========================================================================
    // rd_col_ptr pipeline logic
    //=========================================================================
    assign pipe_rd_col_ptr_din_valid = sof || (buf_valid && dout_ready);
    assign pipe_rd_col_ptr_din_ready = 1'b1;
    assign pipe_rd_col_ptr_din =
        (sof)       ? {LINE_ADDR_WIDTH{1'b0}} :
        (buf_valid && dout_ready) ?
            (rd_col_ptr_raw >= img_width - 1) ? {LINE_ADDR_WIDTH{1'b0}} : rd_col_ptr_raw + 1'b1 :
        rd_col_ptr_raw;

    //=========================================================================
    // rd_row_ptr pipeline logic
    //=========================================================================
    assign pipe_rd_row_ptr_din_valid = sof || (buf_valid && dout_ready && (rd_col_ptr_raw >= img_width - 1));
    assign pipe_rd_row_ptr_din_ready = 1'b1;
    assign pipe_rd_row_ptr_din =
        (sof)       ? {$clog2(NUM_ROWS){1'b0}} :
        (buf_valid && dout_ready && (rd_col_ptr_raw >= img_width - 1)) ?
            (rd_row_ptr_raw == NUM_ROWS-1) ? {$clog2(NUM_ROWS){1'b0}} : rd_row_ptr_raw + 1'b1 :
        rd_row_ptr_raw;

    //=========================================================================
    // rd_active pipeline logic
    //=========================================================================
    assign pipe_rd_active_din_valid = sof || (buf_valid && (rd_col_ptr_raw >= img_width - 1));
    assign pipe_rd_active_din_ready = 1'b1;
    assign pipe_rd_active_din =
        (sof)       ? 1'b0 :
        (buf_valid && (rd_col_ptr_raw >= img_width - 1)) ? 1'b0 :
        (valid_row_cnt_raw >= READ_START_THRESHOLD && !rd_active_raw) ? 1'b1 :
        rd_active_raw;

    //=========================================================================
    // row_started pipeline logic
    //=========================================================================
    assign pipe_row_started_din_valid = sof || wr_shake || eol_fire;
    assign pipe_row_started_din_ready = 1'b1;
    assign pipe_row_started_din =
        (sof)       ? 1'b0 :
        (wr_shake)  ? 1'b1 :
        (eol_fire)  ? 1'b0 :
        row_started_raw;

    //=========================================================================
    // Output assignments
    //=========================================================================
    assign rows_ready = (pipe_valid_row_cnt_dout >= READ_START_THRESHOLD);
    assign din_ready  = s2p_din_ready && enable && !fifo_full;

    assign wr_en   = wr_shake;
    assign wr_addr = pipe_wr_col_ptr_dout;
    assign wr_data = s2p_dout;

    assign rd_en   = pipe_rd_active_dout;
    assign rd_addr = pipe_rd_col_ptr_dout;

    assign dout       = pad_dout;
    assign dout_valid = pad_dout_valid;

    genvar g;
    generate
        for (g = 0; g < NUM_ROWS; g = g + 1) begin : gen_wr_row_en
            assign wr_row_en[g] = (pipe_wr_row_ptr_dout == g) && wr_en;
        end
    endgenerate

    //=========================================================================
    // Window assembly
    //=========================================================================
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
    // wr_col_ptr_raw
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_col_ptr_raw <= {LINE_ADDR_WIDTH{1'b0}};
        end else begin
            wr_col_ptr_raw <= pipe_wr_col_ptr_din;
        end
    end

    //=========================================================================
    // wr_row_ptr_raw
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_row_ptr_raw <= {$clog2(NUM_ROWS){1'b0}};
        end else begin
            wr_row_ptr_raw <= pipe_wr_row_ptr_din;
        end
    end

    //=========================================================================
    // valid_row_cnt_raw
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_row_cnt_raw <= {CTR_WIDTH{1'b0}};
        end else begin
            valid_row_cnt_raw <= pipe_valid_row_cnt_din;
        end
    end

    //=========================================================================
    // rd_col_ptr_raw
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_col_ptr_raw <= {LINE_ADDR_WIDTH{1'b0}};
        end else begin
            rd_col_ptr_raw <= pipe_rd_col_ptr_din;
        end
    end

    //=========================================================================
    // rd_row_ptr_raw
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_row_ptr_raw <= {$clog2(NUM_ROWS){1'b0}};
        end else begin
            rd_row_ptr_raw <= pipe_rd_row_ptr_din;
        end
    end

    //=========================================================================
    // rd_active_raw
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_active_raw <= 1'b0;
        end else begin
            rd_active_raw <= pipe_rd_active_din;
        end
    end

    //=========================================================================
    // row_started_raw
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_started_raw <= 1'b0;
        end else begin
            row_started_raw <= pipe_row_started_din;
        end
    end

    //=========================================================================
    // eol_d1_raw
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eol_d1_raw <= 1'b0;
        end else begin
            eol_d1_raw <= eol;
        end
    end

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
    // Module Instances
    //=========================================================================
    // s2p: 1P → 2P conversion
    common_s2p #(
        .DATA_WIDTH  (DATA_WIDTH),
        .DIN_WIDTH   (DATA_WIDTH),
        .DIN_COUNT   (1),
        .DOUT_WIDTH  (DATA_WIDTH),
        .DOUT_COUNT  (2)
    ) u_s2p_din_1x1to2x1 (
        .clk        (clk),
        .rst_n      (rst_n),
        .enable     (enable),
        .sof        (sof),
        .din        (din),
        .din_valid  (din_valid),
        .din_ready  (s2p_din_ready),
        .dout       (s2p_dout),
        .dout_valid (s2p_dout_valid),
        .dout_ready (1'b1),
        .even_cycle ()
    );

    // fifo_din: buffer current pixel
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

    // p2s: 4 rows 2P → 4 cols 1P
    common_p2s #(
        .DATA_WIDTH  (DATA_WIDTH),
        .PACK_PIXELS (PACK_PIXELS),
        .PACK_WAYS   (NUM_ROWS)
    ) u_p2s (
        .clk        (clk),
        .rst_n      (rst_n),
        .enable     (enable),
        .din        (rd_data),
        .din_valid  (pipe_rd_active_dout),
        .din_ready  (p2s_din_ready),
        .dout       (p2s_dout),
        .dout_valid (p2s_dout_valid),
        .dout_ready (1'b1),
        .sof        (sof)
    );

    // padding: apply boundary padding
    common_padding #(
        .DATA_WIDTH   (DATA_WIDTH),
        .NUM_COLS     (5),
        .NUM_ROWS     (5),
        .PAD_SIZE     (PAD_SIZE)
    ) u_padding (
        .center_x     (pipe_rd_col_ptr_dout),
        .center_y     ({12{1'b0}}),
        .img_width    (img_width),
        .img_height   (img_height),
        .rd_data      (window_5x5),
        .rd_data_valid(buf_valid),
        .dout         (pad_dout),
        .dout_valid   (pad_dout_valid)
    );

    //=========================================================================
    // Pipeline Instances
    //=========================================================================
    // wr_col_ptr pipeline
    common_pipe_slice #(
        .DATA_WIDTH (LINE_ADDR_WIDTH),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_wr_col_ptr (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_wr_col_ptr_din),
        .din_valid  (pipe_wr_col_ptr_din_valid),
        .din_ready  (pipe_wr_col_ptr_din_ready),
        .dout       (pipe_wr_col_ptr_dout),
        .dout_valid (pipe_wr_col_ptr_dout_valid),
        .dout_ready (pipe_wr_col_ptr_dout_ready)
    );

    // wr_row_ptr pipeline
    common_pipe_slice #(
        .DATA_WIDTH ($clog2(NUM_ROWS)),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_wr_row_ptr (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_wr_row_ptr_din),
        .din_valid  (pipe_wr_row_ptr_din_valid),
        .din_ready  (pipe_wr_row_ptr_din_ready),
        .dout       (pipe_wr_row_ptr_dout),
        .dout_valid (pipe_wr_row_ptr_dout_valid),
        .dout_ready (pipe_wr_row_ptr_dout_ready)
    );

    // valid_row_cnt pipeline
    common_pipe_slice #(
        .DATA_WIDTH (CTR_WIDTH),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_valid_row_cnt (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_valid_row_cnt_din),
        .din_valid  (pipe_valid_row_cnt_din_valid),
        .din_ready  (pipe_valid_row_cnt_din_ready),
        .dout       (pipe_valid_row_cnt_dout),
        .dout_valid (pipe_valid_row_cnt_dout_valid),
        .dout_ready (pipe_valid_row_cnt_dout_ready)
    );

    // rd_col_ptr pipeline
    common_pipe_slice #(
        .DATA_WIDTH (LINE_ADDR_WIDTH),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_rd_col_ptr (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_rd_col_ptr_din),
        .din_valid  (pipe_rd_col_ptr_din_valid),
        .din_ready  (pipe_rd_col_ptr_din_ready),
        .dout       (pipe_rd_col_ptr_dout),
        .dout_valid (pipe_rd_col_ptr_dout_valid),
        .dout_ready (pipe_rd_col_ptr_dout_ready)
    );

    // rd_row_ptr pipeline
    common_pipe_slice #(
        .DATA_WIDTH ($clog2(NUM_ROWS)),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_rd_row_ptr (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_rd_row_ptr_din),
        .din_valid  (pipe_rd_row_ptr_din_valid),
        .din_ready  (pipe_rd_row_ptr_din_ready),
        .dout       (pipe_rd_row_ptr_dout),
        .dout_valid (pipe_rd_row_ptr_dout_valid),
        .dout_ready (pipe_rd_row_ptr_dout_ready)
    );

    // rd_active pipeline
    common_pipe_slice #(
        .DATA_WIDTH (1),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_rd_active (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_rd_active_din),
        .din_valid  (pipe_rd_active_din_valid),
        .din_ready  (pipe_rd_active_din_ready),
        .dout       (pipe_rd_active_dout),
        .dout_valid (pipe_rd_active_dout_valid),
        .dout_ready (pipe_rd_active_dout_ready)
    );

    // row_started pipeline
    common_pipe_slice #(
        .DATA_WIDTH (1),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_row_started (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_row_started_din),
        .din_valid  (pipe_row_started_din_valid),
        .din_ready  (pipe_row_started_din_ready),
        .dout       (pipe_row_started_dout),
        .dout_valid (pipe_row_started_dout_valid),
        .dout_ready (pipe_row_started_dout_ready)
    );

endmodule
