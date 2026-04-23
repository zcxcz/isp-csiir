//-----------------------------------------------------------------------------
// Module: common_lb_ctrl
// Purpose: Line buffer control with din merging for 5x5 window
//          Integrates: s2p, linebuffer, p2s, fifo_din
//          Output: col5x1 (5 columns, 5 pixels per column) with padding mask
// Author: rtl-impl
// Date: 2026-04-18
// Modified: 2026-04-23
//-----------------------------------------------------------------------------
// Description:
//   5x5 Window Data Path:
//     - Linebuffer stores 4 rows × 2P (past pixel history)
//     - Current pixel (din) stored in fifo_din
//     - p2s converts 4 rows × 2P → 2 columns × 4 pixels (per cycle)
//     - Need to buffer across cycles to form full 5 columns
//     - Current pixel (col 4) duplicated to fill 5th row position
//
//   Output: col5x1 (5 columns, 5 pixels per column)
//     - Each column = 5 pixels (rows y-2 to y+2 at that column position)
//     - Columns 0-3: from p2s output (buffered across cycles)
//     - Column 4: current pixel (duplicated 5 times)
//     - Plus boundary padding metadata
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
    parameter READ_START_THRESHOLD = 4,   // start reading when valid_row_cnt >= this
    parameter OUTPUT_MODE          = "LB_PLUS_DIN"  // "LB_ONLY" or "LB_PLUS_DIN"
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

    // Output (col5x1: 5 columns, each column = 5 pixels = 5 rows)
    // Format: {col4, col3, col2, col1, col0} where each col = {row4, row3, row2, row1, row0}
    output wire                              rows_ready,
    output wire [DATA_WIDTH*5-1:0]          dout,          // col5x1: 5 pixels
    output wire [5-1:0]                      dout_pad_mask, // which pixels need padding
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
    // Internal Signals - handshake
    //=========================================================================
    wire                                      wr_shake;
    wire                                      rd_shake;
    wire                                      eol_fire;
    wire                                      eol_d1;

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
    // Internal Signals - p2s_buf0 pipeline
    //=========================================================================
    wire                                      pipe_p2s_buf0_din_valid;
    wire                                      pipe_p2s_buf0_din_ready;
    wire [DATA_WIDTH*NUM_ROWS-1:0]          pipe_p2s_buf0_din;
    wire [DATA_WIDTH*NUM_ROWS-1:0]            pipe_p2s_buf0_dout;
    wire                                      pipe_p2s_buf0_dout_valid;
    wire                                      pipe_p2s_buf0_dout_ready;

    //=========================================================================
    // Internal Signals - p2s_buf1 pipeline
    //=========================================================================
    wire                                      pipe_p2s_buf1_din_valid;
    wire                                      pipe_p2s_buf1_din_ready;
    wire [DATA_WIDTH*NUM_ROWS-1:0]          pipe_p2s_buf1_din;
    wire [DATA_WIDTH*NUM_ROWS-1:0]            pipe_p2s_buf1_dout;
    wire                                      pipe_p2s_buf1_dout_valid;
    wire                                      pipe_p2s_buf1_dout_ready;

    //=========================================================================
    // Internal Signals - p2s_buf2 pipeline
    //=========================================================================
    wire                                      pipe_p2s_buf2_din_valid;
    wire                                      pipe_p2s_buf2_din_ready;
    wire [DATA_WIDTH*NUM_ROWS-1:0]          pipe_p2s_buf2_din;
    wire [DATA_WIDTH*NUM_ROWS-1:0]            pipe_p2s_buf2_dout;
    wire                                      pipe_p2s_buf2_dout_valid;
    wire                                      pipe_p2s_buf2_dout_ready;

    //=========================================================================
    // Internal Signals - p2s_buf3 pipeline
    //=========================================================================
    wire                                      pipe_p2s_buf3_din_valid;
    wire                                      pipe_p2s_buf3_din_ready;
    wire [DATA_WIDTH*NUM_ROWS-1:0]          pipe_p2s_buf3_din;
    wire [DATA_WIDTH*NUM_ROWS-1:0]            pipe_p2s_buf3_dout;
    wire                                      pipe_p2s_buf3_dout_valid;
    wire                                      pipe_p2s_buf3_dout_ready;

    //=========================================================================
    // Internal Signals - cur_buf[0] pipeline
    //=========================================================================
    wire                                      pipe_cur_buf0_din_valid;
    wire                                      pipe_cur_buf0_din_ready;
    wire [DATA_WIDTH-1:0]                    pipe_cur_buf0_din;
    wire [DATA_WIDTH-1:0]                     pipe_cur_buf0_dout;
    wire                                      pipe_cur_buf0_dout_valid;
    wire                                      pipe_cur_buf0_dout_ready;

    //=========================================================================
    // Internal Signals - cur_buf[1] pipeline
    //=========================================================================
    wire                                      pipe_cur_buf1_din_valid;
    wire                                      pipe_cur_buf1_din_ready;
    wire [DATA_WIDTH-1:0]                    pipe_cur_buf1_din;
    wire [DATA_WIDTH-1:0]                     pipe_cur_buf1_dout;
    wire                                      pipe_cur_buf1_dout_valid;
    wire                                      pipe_cur_buf1_dout_ready;

    //=========================================================================
    // Internal Signals - cur_buf[2] pipeline
    //=========================================================================
    wire                                      pipe_cur_buf2_din_valid;
    wire                                      pipe_cur_buf2_din_ready;
    wire [DATA_WIDTH-1:0]                    pipe_cur_buf2_din;
    wire [DATA_WIDTH-1:0]                     pipe_cur_buf2_dout;
    wire                                      pipe_cur_buf2_dout_valid;
    wire                                      pipe_cur_buf2_dout_ready;

    //=========================================================================
    // Internal Signals - cur_buf[3] pipeline
    //=========================================================================
    wire                                      pipe_cur_buf3_din_valid;
    wire                                      pipe_cur_buf3_din_ready;
    wire [DATA_WIDTH-1:0]                    pipe_cur_buf3_din;
    wire [DATA_WIDTH-1:0]                     pipe_cur_buf3_dout;
    wire                                      pipe_cur_buf3_dout_valid;
    wire                                      pipe_cur_buf3_dout_ready;

    //=========================================================================
    // Internal Signals - rd_cycle pipeline
    //=========================================================================
    wire                                      pipe_rd_cycle_din_valid;
    wire                                      pipe_rd_cycle_din_ready;
    wire [2:0]                              pipe_rd_cycle_din;
    wire [2:0]                                pipe_rd_cycle_dout;
    wire                                      pipe_rd_cycle_dout_valid;
    wire                                      pipe_rd_cycle_dout_ready;

    //=========================================================================
    // Internal Signals - buf_valid pipeline
    //=========================================================================
    wire                                      pipe_buf_valid_din_valid;
    wire                                      pipe_buf_valid_din_ready;
    wire                                      pipe_buf_valid_din;
    wire                                      pipe_buf_valid_dout;
    wire                                      pipe_buf_valid_dout_valid;
    wire                                      pipe_buf_valid_dout_ready;

    //=========================================================================
    // Internal Signals - col5x1 output
    //=========================================================================
    wire [DATA_WIDTH*5-1:0]                  col5x1;         // 5 pixels
    wire [5-1:0]                              col5x1_pad_mask; // padding mask per pixel

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
    reg [DATA_WIDTH*NUM_ROWS-1:0]          p2s_buf0_raw;
    reg [DATA_WIDTH*NUM_ROWS-1:0]          p2s_buf1_raw;
    reg [DATA_WIDTH*NUM_ROWS-1:0]          p2s_buf2_raw;
    reg [DATA_WIDTH*NUM_ROWS-1:0]          p2s_buf3_raw;
    reg [DATA_WIDTH-1:0]                    cur_buf0_raw;
    reg [DATA_WIDTH-1:0]                    cur_buf1_raw;
    reg [DATA_WIDTH-1:0]                    cur_buf2_raw;
    reg [DATA_WIDTH-1:0]                    cur_buf3_raw;
    reg [2:0]                              rd_cycle_raw;
    reg                                      buf_valid_raw;

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
    assign pipe_rd_col_ptr_din_valid = sof || (pipe_buf_valid_dout && dout_ready);
    assign pipe_rd_col_ptr_din_ready = 1'b1;
    assign pipe_rd_col_ptr_din =
        (sof)       ? {LINE_ADDR_WIDTH{1'b0}} :
        (pipe_buf_valid_dout && dout_ready) ?
            (rd_col_ptr_raw >= img_width - 1) ? {LINE_ADDR_WIDTH{1'b0}} : rd_col_ptr_raw + 1'b1 :
        rd_col_ptr_raw;

    //=========================================================================
    // rd_row_ptr pipeline logic
    //=========================================================================
    assign pipe_rd_row_ptr_din_valid = sof || (pipe_buf_valid_dout && dout_ready && (rd_col_ptr_raw >= img_width - 1));
    assign pipe_rd_row_ptr_din_ready = 1'b1;
    assign pipe_rd_row_ptr_din =
        (sof)       ? {$clog2(NUM_ROWS){1'b0}} :
        (pipe_buf_valid_dout && dout_ready && (rd_col_ptr_raw >= img_width - 1)) ?
            (rd_row_ptr_raw == NUM_ROWS-1) ? {$clog2(NUM_ROWS){1'b0}} : rd_row_ptr_raw + 1'b1 :
        rd_row_ptr_raw;

    //=========================================================================
    // rd_active pipeline logic
    //=========================================================================
    assign pipe_rd_active_din_valid = sof || (pipe_buf_valid_dout && (rd_col_ptr_raw >= img_width - 1));
    assign pipe_rd_active_din_ready = 1'b1;
    assign pipe_rd_active_din =
        (sof)       ? 1'b0 :
        (pipe_buf_valid_dout && (rd_col_ptr_raw >= img_width - 1)) ? 1'b0 :
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
    // p2s_buf0 pipeline logic
    //=========================================================================
    assign pipe_p2s_buf0_din_valid = sof || 1'b1;
    assign pipe_p2s_buf0_din_ready = 1'b1;
    assign pipe_p2s_buf0_din =
        (sof)       ? {DATA_WIDTH*NUM_ROWS{1'b0}} :
        (rd_shake && rd_cycle_raw == 3'd0) ? p2s_dout :
        p2s_buf0_raw;

    //=========================================================================
    // p2s_buf1 pipeline logic
    //=========================================================================
    assign pipe_p2s_buf1_din_valid = sof || 1'b1;
    assign pipe_p2s_buf1_din_ready = 1'b1;
    assign pipe_p2s_buf1_din =
        (sof)       ? {DATA_WIDTH*NUM_ROWS{1'b0}} :
        (rd_shake && rd_cycle_raw == 3'd1) ? p2s_dout :
        p2s_buf1_raw;

    //=========================================================================
    // p2s_buf2 pipeline logic
    //=========================================================================
    assign pipe_p2s_buf2_din_valid = sof || 1'b1;
    assign pipe_p2s_buf2_din_ready = 1'b1;
    assign pipe_p2s_buf2_din =
        (sof)       ? {DATA_WIDTH*NUM_ROWS{1'b0}} :
        (rd_shake && rd_cycle_raw == 3'd2) ? p2s_dout :
        p2s_buf2_raw;

    //=========================================================================
    // p2s_buf3 pipeline logic
    //=========================================================================
    assign pipe_p2s_buf3_din_valid = sof || 1'b1;
    assign pipe_p2s_buf3_din_ready = 1'b1;
    assign pipe_p2s_buf3_din =
        (sof)       ? {DATA_WIDTH*NUM_ROWS{1'b0}} :
        (rd_shake && rd_cycle_raw == 3'd3) ? p2s_dout :
        p2s_buf3_raw;

    //=========================================================================
    // cur_buf[0] pipeline logic
    //=========================================================================
    assign pipe_cur_buf0_din_valid = sof || 1'b1;
    assign pipe_cur_buf0_din_ready = 1'b1;
    assign pipe_cur_buf0_din =
        (sof)       ? {DATA_WIDTH{1'b0}} :
        (rd_shake && rd_cycle_raw == 3'd0) ? fifo_rdata :
        cur_buf0_raw;

    //=========================================================================
    // cur_buf[1] pipeline logic
    //=========================================================================
    assign pipe_cur_buf1_din_valid = sof || 1'b1;
    assign pipe_cur_buf1_din_ready = 1'b1;
    assign pipe_cur_buf1_din =
        (sof)       ? {DATA_WIDTH{1'b0}} :
        (rd_shake && rd_cycle_raw == 3'd1) ? fifo_rdata :
        cur_buf1_raw;

    //=========================================================================
    // cur_buf[2] pipeline logic
    //=========================================================================
    assign pipe_cur_buf2_din_valid = sof || 1'b1;
    assign pipe_cur_buf2_din_ready = 1'b1;
    assign pipe_cur_buf2_din =
        (sof)       ? {DATA_WIDTH{1'b0}} :
        (rd_shake && rd_cycle_raw == 3'd2) ? fifo_rdata :
        cur_buf2_raw;

    //=========================================================================
    // cur_buf[3] pipeline logic
    //=========================================================================
    assign pipe_cur_buf3_din_valid = sof || 1'b1;
    assign pipe_cur_buf3_din_ready = 1'b1;
    assign pipe_cur_buf3_din =
        (sof)       ? {DATA_WIDTH{1'b0}} :
        (rd_shake && rd_cycle_raw == 3'd3) ? fifo_rdata :
        cur_buf3_raw;

    //=========================================================================
    // rd_cycle pipeline logic
    //=========================================================================
    assign pipe_rd_cycle_din_valid = sof || 1'b1;
    assign pipe_rd_cycle_din_ready = 1'b1;
    assign pipe_rd_cycle_din =
        (sof)       ? 3'd0 :
        (rd_shake)  ? rd_cycle_raw + 1'b1 :
        rd_cycle_raw;

    //=========================================================================
    // buf_valid pipeline logic
    //=========================================================================
    assign pipe_buf_valid_din_valid = sof || 1'b1;
    assign pipe_buf_valid_din_ready = 1'b1;
    assign pipe_buf_valid_din =
        (sof)       ? 1'b0 :
        (rd_shake && rd_cycle_raw == 3'd3) ? 1'b1 :
        (pipe_buf_valid_dout && dout_ready) ? 1'b0 :
        buf_valid_raw;

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

    assign dout       = col5x1;
    assign dout_valid = pipe_buf_valid_dout;
    assign dout_pad_mask = col5x1_pad_mask;

    genvar g;
    generate
        for (g = 0; g < NUM_ROWS; g = g + 1) begin : gen_wr_row_en
            assign wr_row_en[g] = (pipe_wr_row_ptr_dout == g) && wr_en;
        end
    endgenerate

    //=========================================================================
    // col5x1 assembly (5 pixels, each column = 5 rows)
    //=========================================================================
    // Data flow:
    //   - 4 LBs, each outputs 2P per read
    //   - P2S converts 2P → 1P (parallel to serial), outputting 1 pixel per cycle
    //   - Total input: 4×2P (from LBs) + 1×2P (din) = 5×2P
    //   - P2S outputs 5 pixels per cycle (one column), over 2 cycles per column
    //   - rd_cycle[1:0] selects which pixel within the 2P to output
    //
    // col5x1 format: 5 pixels (one per row in 5x5 window)
    //   pixel[4] = row y+2 (newest row)
    //   pixel[3] = row y+1
    //   pixel[2] = row y   (center row)
    //   pixel[1] = row y-1
    //   pixel[0] = row y-2 (oldest row)
    //
    // Mapping based on rd_cycle:
    //   rd_cycle=0: first pixel from each 2P word
    //     col5x1 = {cur_buf0, p2s_buf0[0], p2s_buf1[0], p2s_buf2[0], p2s_buf3[0]}
    //   rd_cycle=1: second pixel from each 2P word
    //     col5x1 = {cur_buf1, p2s_buf0[1], p2s_buf1[1], p2s_buf2[1], p2s_buf3[1]}
    //=========================================================================

    // col5x1: 5 pixels for current column (at x = rd_col_ptr)
    // p2s_buf stores 2P per row, indexed by rd_cycle[0] (0=first pixel, 1=second pixel)
    wire [DATA_WIDTH-1:0] p2s_col_pixel [0:3];
    assign p2s_col_pixel[0] = (~rd_cycle_raw[0]) ?
                              pipe_p2s_buf0_dout[0 * DATA_WIDTH +: DATA_WIDTH] :
                              pipe_p2s_buf0_dout[1 * DATA_WIDTH +: DATA_WIDTH];
    assign p2s_col_pixel[1] = (~rd_cycle_raw[0]) ?
                              pipe_p2s_buf1_dout[0 * DATA_WIDTH +: DATA_WIDTH] :
                              pipe_p2s_buf1_dout[1 * DATA_WIDTH +: DATA_WIDTH];
    assign p2s_col_pixel[2] = (~rd_cycle_raw[0]) ?
                              pipe_p2s_buf2_dout[0 * DATA_WIDTH +: DATA_WIDTH] :
                              pipe_p2s_buf2_dout[1 * DATA_WIDTH +: DATA_WIDTH];
    assign p2s_col_pixel[3] = (~rd_cycle_raw[0]) ?
                              pipe_p2s_buf3_dout[0 * DATA_WIDTH +: DATA_WIDTH] :
                              pipe_p2s_buf3_dout[1 * DATA_WIDTH +: DATA_WIDTH];

    wire [DATA_WIDTH-1:0] cur_col_pixel;
    assign cur_col_pixel = (~rd_cycle_raw[0]) ?
                           pipe_cur_buf0_dout : pipe_cur_buf1_dout;

    // Output mode selection
    generate
        if (OUTPUT_MODE == "LB_ONLY") begin : gen_lb_only
            assign col5x1 = {
                p2s_col_pixel[0],  // pixel[4] = row y+2
                p2s_col_pixel[1],  // pixel[3] = row y+1
                p2s_col_pixel[2],  // pixel[2] = row y
                p2s_col_pixel[3],  // pixel[1] = row y-1
                {DATA_WIDTH{1'b0}}  // pixel[0] = row y-2 (not available)
            };
        end else begin : gen_lb_plus_din
            assign col5x1 = {
                cur_col_pixel,     // pixel[4] = row y+2 (current din)
                p2s_col_pixel[0],  // pixel[3] = row y+1
                p2s_col_pixel[1],  // pixel[2] = row y
                p2s_col_pixel[2],  // pixel[1] = row y-1
                p2s_col_pixel[3]   // pixel[0] = row y-2
            };
        end
    endgenerate

    //=========================================================================
    // col5x1_pad_mask: indicates which pixels need boundary padding
    // For a 5x5 window centered at (center_x, center_y):
    //   - pixel[4] at y+2: valid if center_y < img_height - 2
    //   - pixel[3] at y+1: valid if center_y < img_height - 1
    //   - pixel[2] at y:   always valid if within image (center pixel)
    //   - pixel[1] at y-1: valid if center_y >= 1
    //   - pixel[0] at y-2: valid if center_y >= 2
    //=========================================================================
    wire [$clog2(NUM_ROWS)-1:0] center_y;
    assign center_y = pipe_rd_row_ptr_dout;  // current y position

    assign col5x1_pad_mask = {
        (center_y < img_height - PAD_SIZE),  // pixel[4] row y+2
        (center_y < img_height - 1),          // pixel[3] row y+1
        1'b1,                                  // pixel[2] row y (always valid)
        (center_y >= 1),                       // pixel[1] row y-1
        (center_y >= PAD_SIZE)                 // pixel[0] row y-2
    };

    //=========================================================================
    // Raw signal assignments (registered inputs to pipelines)
    //=========================================================================
    assign wr_col_ptr_raw = pipe_wr_col_ptr_dout;
    assign wr_row_ptr_raw = pipe_wr_row_ptr_dout;
    assign valid_row_cnt_raw = pipe_valid_row_cnt_dout;
    assign rd_col_ptr_raw = pipe_rd_col_ptr_dout;
    assign rd_row_ptr_raw = pipe_rd_row_ptr_dout;
    assign rd_active_raw = pipe_rd_active_dout;
    assign row_started_raw = pipe_row_started_dout;
    assign eol_d1_raw = eol_d1;
    assign p2s_buf0_raw = pipe_p2s_buf0_dout;
    assign p2s_buf1_raw = pipe_p2s_buf1_dout;
    assign p2s_buf2_raw = pipe_p2s_buf2_dout;
    assign p2s_buf3_raw = pipe_p2s_buf3_dout;
    assign cur_buf0_raw = pipe_cur_buf0_dout;
    assign cur_buf1_raw = pipe_cur_buf1_dout;
    assign cur_buf2_raw = pipe_cur_buf2_dout;
    assign cur_buf3_raw = pipe_cur_buf3_dout;
    assign rd_cycle_raw = pipe_rd_cycle_dout;
    assign buf_valid_raw = pipe_buf_valid_dout;

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

    //=========================================================================
    // eol_d1 pipeline instance
    //=========================================================================
    common_pipe_slice #(
        .DATA_WIDTH (1),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_eol_d1 (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (eol),
        .din_valid  (1'b1),
        .din_ready  (),
        .dout       (eol_d1),
        .dout_valid (),
        .dout_ready (1'b1)
    );

    //=========================================================================
    // Pipeline Instances - Control Signals
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

    //=========================================================================
    // Pipeline Instances - Data Path
    //=========================================================================
    // p2s_buf0 pipeline
    common_pipe_slice #(
        .DATA_WIDTH (DATA_WIDTH * NUM_ROWS),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_p2s_buf0 (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_p2s_buf0_din),
        .din_valid  (pipe_p2s_buf0_din_valid),
        .din_ready  (pipe_p2s_buf0_din_ready),
        .dout       (pipe_p2s_buf0_dout),
        .dout_valid (pipe_p2s_buf0_dout_valid),
        .dout_ready (pipe_p2s_buf0_dout_ready)
    );

    // p2s_buf1 pipeline
    common_pipe_slice #(
        .DATA_WIDTH (DATA_WIDTH * NUM_ROWS),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_p2s_buf1 (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_p2s_buf1_din),
        .din_valid  (pipe_p2s_buf1_din_valid),
        .din_ready  (pipe_p2s_buf1_din_ready),
        .dout       (pipe_p2s_buf1_dout),
        .dout_valid (pipe_p2s_buf1_dout_valid),
        .dout_ready (pipe_p2s_buf1_dout_ready)
    );

    // p2s_buf2 pipeline
    common_pipe_slice #(
        .DATA_WIDTH (DATA_WIDTH * NUM_ROWS),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_p2s_buf2 (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_p2s_buf2_din),
        .din_valid  (pipe_p2s_buf2_din_valid),
        .din_ready  (pipe_p2s_buf2_din_ready),
        .dout       (pipe_p2s_buf2_dout),
        .dout_valid (pipe_p2s_buf2_dout_valid),
        .dout_ready (pipe_p2s_buf2_dout_ready)
    );

    // p2s_buf3 pipeline
    common_pipe_slice #(
        .DATA_WIDTH (DATA_WIDTH * NUM_ROWS),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_p2s_buf3 (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_p2s_buf3_din),
        .din_valid  (pipe_p2s_buf3_din_valid),
        .din_ready  (pipe_p2s_buf3_din_ready),
        .dout       (pipe_p2s_buf3_dout),
        .dout_valid (pipe_p2s_buf3_dout_valid),
        .dout_ready (pipe_p2s_buf3_dout_ready)
    );

    // cur_buf[0] pipeline
    common_pipe_slice #(
        .DATA_WIDTH (DATA_WIDTH),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_cur_buf0 (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_cur_buf0_din),
        .din_valid  (pipe_cur_buf0_din_valid),
        .din_ready  (pipe_cur_buf0_din_ready),
        .dout       (pipe_cur_buf0_dout),
        .dout_valid (pipe_cur_buf0_dout_valid),
        .dout_ready (pipe_cur_buf0_dout_ready)
    );

    // cur_buf[1] pipeline
    common_pipe_slice #(
        .DATA_WIDTH (DATA_WIDTH),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_cur_buf1 (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_cur_buf1_din),
        .din_valid  (pipe_cur_buf1_din_valid),
        .din_ready  (pipe_cur_buf1_din_ready),
        .dout       (pipe_cur_buf1_dout),
        .dout_valid (pipe_cur_buf1_dout_valid),
        .dout_ready (pipe_cur_buf1_dout_ready)
    );

    // cur_buf[2] pipeline
    common_pipe_slice #(
        .DATA_WIDTH (DATA_WIDTH),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_cur_buf2 (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_cur_buf2_din),
        .din_valid  (pipe_cur_buf2_din_valid),
        .din_ready  (pipe_cur_buf2_din_ready),
        .dout       (pipe_cur_buf2_dout),
        .dout_valid (pipe_cur_buf2_dout_valid),
        .dout_ready (pipe_cur_buf2_dout_ready)
    );

    // cur_buf[3] pipeline
    common_pipe_slice #(
        .DATA_WIDTH (DATA_WIDTH),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_cur_buf3 (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_cur_buf3_din),
        .din_valid  (pipe_cur_buf3_din_valid),
        .din_ready  (pipe_cur_buf3_din_ready),
        .dout       (pipe_cur_buf3_dout),
        .dout_valid (pipe_cur_buf3_dout_valid),
        .dout_ready (pipe_cur_buf3_dout_ready)
    );

    // rd_cycle pipeline
    common_pipe_slice #(
        .DATA_WIDTH (3),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_rd_cycle (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_rd_cycle_din),
        .din_valid  (pipe_rd_cycle_din_valid),
        .din_ready  (pipe_rd_cycle_din_ready),
        .dout       (pipe_rd_cycle_dout),
        .dout_valid (pipe_rd_cycle_dout_valid),
        .dout_ready (pipe_rd_cycle_dout_ready)
    );

    // buf_valid pipeline
    common_pipe_slice #(
        .DATA_WIDTH (1),
        .RESET_VAL  (0),
        .PIPE_TYPE  (0)
    ) u_pipe_buf_valid (
        .clk        (clk),
        .rst_n      (rst_n),
        .din        (pipe_buf_valid_din),
        .din_valid  (pipe_buf_valid_din_valid),
        .din_ready  (pipe_buf_valid_din_ready),
        .dout       (pipe_buf_valid_dout),
        .dout_valid (pipe_buf_valid_dout_valid),
        .dout_ready (pipe_buf_valid_dout_ready)
    );

endmodule
