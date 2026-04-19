//-----------------------------------------------------------------------------
// Module: common_lb_ctrl
// Purpose: Line buffer control for multi-row storage (circular buffer)
//          Controls write/read pointers for N-row line buffer
//          Integrates boundary padding for 5x5 window operations
// Author: rtl-impl
// Date: 2026-04-18
//-----------------------------------------------------------------------------
// Description:
//   Circular buffer control with independent read/write column pointers:
//   - Write: fills rows progressively with incoming packed data
//   - Read: releases rows to downstream when buffer is full
//   - Tracks valid row count and read/write column pointers
//   - Boundary padding for 5x5 window at image edges
//
// Interface (data_wi_fb style):
//   Write: din_valid/din_ready/din (upstream) -> wr_en/wr_addr/wr_data (to SRAM)
//   Read:  rd_en/rd_addr (to SRAM) -> rd_data/rd_data_valid (from SRAM)
//          -> common_padding -> dout_valid/dout_ready/dout (to downstream)
//
// Write Condition:
//   din_ready = enable AND (
//     valid_row_cnt < NUM_ROWS                          // buffer not full
//     OR valid_row_cnt == NUM_ROWS AND wr_col_ptr < rd_col_ptr  // can overwrite
//   )
//
// Read Condition:
//   rows_ready = (valid_row_cnt == NUM_ROWS)  // buffer full
//   rd_en = rows_ready AND rd_ready
//
// EOL Handling:
//   When EOL fires: if row was started (wr_col_ptr > 0), valid_row_cnt++
//   BUT if buffer already full (valid_row_cnt == NUM_ROWS), EOL does NOT increment
//
// Row Read Completion:
//   When rd_col_ptr reaches img_width-1 and rd_en fires, valid_row_cnt--
//
// Parameters:
//   DATA_WIDTH        - bits per pixel
//   LINE_ADDR_WIDTH   - bits for column address
//   NUM_ROWS          - number of rows in line buffer (default 4)
//   PACK_PIXELS       - pixels per word (default 2)
//   PAD_SIZE          - padding size for 5x5 window (default 2)
//-----------------------------------------------------------------------------

module common_lb_ctrl #(
    parameter DATA_WIDTH        = 10,  // bits per pixel
    parameter LINE_ADDR_WIDTH   = 14,  // IMG_WIDTH/2 depth
    parameter NUM_ROWS          = 4,   // number of rows
    parameter PACK_PIXELS       = 2,    // pixels per word
    parameter PAD_SIZE          = 2     // padding size (2 for 5x5 window)
)(
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire                              enable,

    // Configuration
    input  wire [LINE_ADDR_WIDTH-1:0]       img_width,
    input  wire [LINE_ADDR_WIDTH-1:0]       img_height,

    // Write interface (from upstream, data_wi_fb)
    input  wire [DATA_WIDTH*PACK_PIXELS-1:0] din,
    input  wire                              din_valid,
    output wire                              din_ready,

    // Write control (to SRAM)
    output wire [LINE_ADDR_WIDTH-1:0]        wr_addr,
    output wire [NUM_ROWS-1:0]             wr_row_en,
    output wire [DATA_WIDTH*PACK_PIXELS-1:0] wr_data,
    output wire                              wr_en,

    // Read control (to SRAM)
    output wire                              rd_en,
    output wire [LINE_ADDR_WIDTH-1:0]        rd_addr,

    // Read data (from SRAM)
    input  wire [DATA_WIDTH*PACK_PIXELS*NUM_ROWS-1:0] rd_data,
    input  wire                                              rd_data_valid,

    // Output (to downstream, data_wi_fb with padding applied)
    output wire                              rows_ready,
    output wire [DATA_WIDTH*PACK_PIXELS*NUM_ROWS-1:0] dout,
    output wire                              dout_valid,
    input  wire                              dout_ready,

    // Frame signals
    input  wire                              sof,
    input  wire                              eol
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam CTR_WIDTH = $clog2(NUM_ROWS+1);  // valid_row_cnt width
    localparam PACK_DW   = DATA_WIDTH * PACK_PIXELS;  // packed pixel width
    localparam COL_DW    = PACK_DW * NUM_ROWS;  // full column width

    //=========================================================================
    // Internal Signals - Write Side
    //=========================================================================
    reg [CTR_WIDTH-1:0]            valid_row_cnt;
    reg [$clog2(NUM_ROWS)-1:0]     wr_row_ptr;
    reg [LINE_ADDR_WIDTH-1:0]       wr_col_ptr;
    reg                             row_started;

    //=========================================================================
    // Internal Signals - Read Side
    //=========================================================================
    reg [$clog2(NUM_ROWS)-1:0]     rd_row_ptr;
    reg [LINE_ADDR_WIDTH-1:0]       rd_col_ptr;

    //=========================================================================
    // EOL Edge Detection
    //=========================================================================
    reg  eol_d1;
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
    // Write Column Pointer & Row Started Flag
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
            row_started <= 1'b0;
        end else if (sof) begin
            wr_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
            row_started <= 1'b0;
        end else if (enable && din_valid && din_ready) begin
            wr_col_ptr <= wr_col_ptr + 1'b1;
            row_started <= 1'b1;
        end else if (eol_fire) begin
            wr_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
            row_started <= 1'b0;
        end
    end

    //=========================================================================
    // Write Row Pointer
    //=========================================================================
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

    //=========================================================================
    // Valid Row Count (Write Increment / Read Decrement)
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_row_cnt <= {CTR_WIDTH{1'b0}};
        end else if (sof) begin
            valid_row_cnt <= {CTR_WIDTH{1'b0}};
        end else if (enable) begin
            if (eol_fire && row_started && valid_row_cnt < NUM_ROWS) begin
                valid_row_cnt <= valid_row_cnt + 1'b1;
            end else if (rd_en && rd_col_ptr >= img_width - 1 && valid_row_cnt > 0) begin
                valid_row_cnt <= valid_row_cnt - 1'b1;
            end
        end
    end

    //=========================================================================
    // Read Column Pointer
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
        end else if (sof) begin
            rd_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
        end else if (enable && rd_en) begin
            if (rd_col_ptr >= img_width - 1) begin
                rd_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
            end else begin
                rd_col_ptr <= rd_col_ptr + 1'b1;
            end
        end
    end

    //=========================================================================
    // Read Row Pointer
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_row_ptr <= {$clog2(NUM_ROWS){1'b0}};
        end else if (sof) begin
            rd_row_ptr <= {$clog2(NUM_ROWS){1'b0}};
        end else if (enable && rd_en && rd_col_ptr >= img_width - 1) begin
            rd_row_ptr <= (rd_row_ptr == NUM_ROWS-1) ? {$clog2(NUM_ROWS){1'b0}}
                                                      : rd_row_ptr + 1'b1;
        end
    end

    //=========================================================================
    // common_padding Instance
    //=========================================================================
    common_padding #(
        .DATA_WIDTH    (DATA_WIDTH),
        .PACK_PIXELS   (PACK_PIXELS),
        .NUM_ROWS      (NUM_ROWS),
        .PAD_SIZE      (PAD_SIZE)
    ) u_padding (
        .center_x      (rd_col_ptr),
        .center_y      (rd_row_ptr),
        .img_width     (img_width),
        .img_height    (img_height),
        .rd_data       (rd_data),
        .rd_data_valid (rd_data_valid),
        .dout          (dout),
        .dout_valid    (dout_valid)
    );

    //=========================================================================
    // Output Assignments
    //=========================================================================
    // Din ready: buffer not full, or can overwrite oldest unread data
    assign din_ready = enable &&
                       (valid_row_cnt < NUM_ROWS ||
                        (valid_row_cnt == NUM_ROWS && wr_col_ptr < rd_col_ptr));

    // Write control
    assign wr_en = enable && din_valid && din_ready;
    assign wr_addr = wr_col_ptr;
    assign wr_data = din;

    // One-hot row enable
    genvar g;
    generate
        for (g = 0; g < NUM_ROWS; g = g + 1) begin : gen_wr_row_en
            assign wr_row_en[g] = (wr_row_ptr == g) && wr_en;
        end
    endgenerate

    // Rows ready: buffer is full (all rows have valid data)
    assign rows_ready = (valid_row_cnt == NUM_ROWS);

    // Read enable: buffer full and downstream ready
    assign rd_en = rows_ready && dout_ready;

    // Read address
    assign rd_addr = rd_col_ptr;

endmodule
