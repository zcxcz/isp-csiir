//-----------------------------------------------------------------------------
// Module: common_lb_ctrl
// Purpose: Line buffer control for multi-row storage (circular buffer)
//          Controls write/read pointers for N-row line buffer
// Author: rtl-impl
// Date: 2026-04-18
//-----------------------------------------------------------------------------
// Description:
//   Circular buffer control with independent read/write column pointers:
//   - Write: fills rows progressively with incoming packed data
//   - Read: releases rows to downstream when buffer is full
//   - Tracks valid row count and read/write column pointers
//
// Design Principles:
//   1. Separate always blocks for logically unrelated signals
//   2. No state machine for simple logic (use direct combinational where possible)
//   3. Two-segment state machine only when needed (not three-segment)
//
// Write Condition:
//   din_ready = enable AND (
//     valid_row_cnt < NUM_ROWS                          // buffer not full
//     OR valid_row_cnt == NUM_ROWS AND wr_col_ptr < rd_col_ptr  // can overwrite
//   )
//
// Read Condition:
//   rd_en = rows_ready AND rd_ready
//   rows_ready = (valid_row_cnt == NUM_ROWS) AND 后级无反压
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
//-----------------------------------------------------------------------------

module common_lb_ctrl #(
    parameter DATA_WIDTH        = 10,  // bits per pixel
    parameter LINE_ADDR_WIDTH   = 14,  // IMG_WIDTH/2 depth
    parameter NUM_ROWS          = 4,   // number of rows
    parameter PACK_PIXELS        = 2    // pixels per word
)(
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire                              enable,

    // Configuration
    input  wire [LINE_ADDR_WIDTH-1:0]       img_width,

    // Write side (from upstream, to common_lb)
    input  wire [DATA_WIDTH*PACK_PIXELS-1:0] din,
    input  wire                              din_valid,
    output wire                              din_ready,
    output wire [LINE_ADDR_WIDTH-1:0]        wr_addr,
    output wire [NUM_ROWS-1:0]               wr_row_en,
    output wire [DATA_WIDTH*PACK_PIXELS-1:0] wr_data,
    output wire                              wr_en,

    // Read side (to downstream)
    output wire                              rd_en,
    output wire [LINE_ADDR_WIDTH-1:0]         rd_addr,
    output wire                              rows_ready,
    input  wire                              rd_ready,

    // Frame signals
    input  wire                              sof,
    input  wire                              eol
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam CTR_WIDTH = $clog2(NUM_ROWS+1);  // valid_row_cnt width

    //=========================================================================
    // Internal Signals - Write Side
    //=========================================================================
    reg [CTR_WIDTH-1:0]            valid_row_cnt;  // 0 to NUM_ROWS
    reg [$clog2(NUM_ROWS)-1:0]     wr_row_ptr;    // 0 to NUM_ROWS-1 cycling
    reg [LINE_ADDR_WIDTH-1:0]       wr_col_ptr;    // column write pointer
    reg                             row_started;    // current row has data

    //=========================================================================
    // Internal Signals - Read Side
    //=========================================================================
    reg [$clog2(NUM_ROWS)-1:0]     rd_row_ptr;    // 0 to NUM_ROWS-1 cycling
    reg [LINE_ADDR_WIDTH-1:0]       rd_col_ptr;    // column read pointer

    //=========================================================================
    // EOL Edge Detection (Write Side)
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
    // These two are tightly coupled - both update on din_valid && din_ready
    // EOL resets wr_col_ptr and marks row as complete
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
    // Advances on EOL (if row was started), cycles 0→1→2→3→0
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
    // Valid Row Count (Single Block for Write and Read)
    //=========================================================================
    // Write: EOL fires and row was started -> increment (if not already full)
    // Read:  rd_en fires and row completed -> decrement
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_row_cnt <= {CTR_WIDTH{1'b0}};
        end else if (sof) begin
            valid_row_cnt <= {CTR_WIDTH{1'b0}};
        end else if (enable) begin
            // EOL fires: row write completed, increment valid_row_cnt if not full
            if (eol_fire && row_started && valid_row_cnt < NUM_ROWS) begin
                valid_row_cnt <= valid_row_cnt + 1'b1;
            end
            // Read row completed: rd_col_ptr reached end and rd_en fires
            else if (rd_en && rd_col_ptr >= img_width - 1 && valid_row_cnt > 0) begin
                valid_row_cnt <= valid_row_cnt - 1'b1;
            end
        end
    end

    //=========================================================================
    // Read Column Pointer
    //=========================================================================
    // Advances on each read cycle
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
    // Advances when rd_col_ptr wraps (row completed)
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
    // Output Assignments
    //=========================================================================
    // Din ready: buffer not full, or can overwrite oldest unread data
    // Can write when: buffer not full OR (full but wr_ptr < rd_ptr)
    assign din_ready = enable &&
                       (valid_row_cnt < NUM_ROWS ||
                        (valid_row_cnt == NUM_ROWS && wr_col_ptr < rd_col_ptr));

    // Write enable
    assign wr_en = enable && din_valid && din_ready;

    // Write address
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
    assign rd_en = rows_ready && rd_ready;

    // Read address
    assign rd_addr = rd_col_ptr;

endmodule
