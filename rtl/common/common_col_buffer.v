//-----------------------------------------------------------------------------
// Module: common_col_buffer
// Purpose: Buffer 1P stream into column format (col_0~col_4)
//         Collects 5 pixels from p2s stream, presents as parallel column
// Author: rtl-impl
// Date: 2026-04-15
//-----------------------------------------------------------------------------
// Description:
//   Receives 1P pixel stream from p2s and buffers into column format.
//   - Collects 5 pixels (forming one column)
//   - When buffer full, presents col_0~col_4 simultaneously
//   - After column consumed, collects next 5 pixels
//
//   Used between p2s (1P output) and gradient (column input).
//
// Data Flow:
//   p2s dout (1P/cycle) → [buffer] → gradient col_0~col_4 (5 pixels parallel)
//
// Parameters:
//   DATA_WIDTH - Bit width of each pixel
//-----------------------------------------------------------------------------

module common_col_buffer #(
    parameter DATA_WIDTH = 10,
    parameter LINE_ADDR_WIDTH = 14,
    parameter ROW_CNT_WIDTH = 13
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  enable,
    input  wire                  sof,        // Start of frame - reset buffer

    // 1P Input (from p2s)
    input  wire [DATA_WIDTH-1:0] din,
    input  wire                  din_valid,
    output wire                  din_ready,

    // Column Output (to gradient)
    output wire [DATA_WIDTH-1:0] col_0,
    output wire [DATA_WIDTH-1:0] col_1,
    output wire [DATA_WIDTH-1:0] col_2,
    output wire [DATA_WIDTH-1:0] col_3,
    output wire [DATA_WIDTH-1:0] col_4,
    output wire                  column_valid,
    input  wire                  column_ready,

    // Column position metadata (passthrough)
    input  wire [LINE_ADDR_WIDTH-1:0] center_x,
    input  wire [ROW_CNT_WIDTH-1:0]   center_y,
    output wire [LINE_ADDR_WIDTH-1:0] col_center_x,
    output wire [ROW_CNT_WIDTH-1:0]   col_center_y
);

    localparam CNT_WIDTH = 3;  // log2(5)

    // Column buffer registers
    reg [DATA_WIDTH-1:0] col_buf [0:4];
    reg [CNT_WIDTH-1:0] col_count;  // 0-4
    reg                  col_valid_reg;
    reg [LINE_ADDR_WIDTH-1:0] center_x_reg;
    reg [ROW_CNT_WIDTH-1:0]   center_y_reg;

    // State
    localparam ST_IDLE  = 1'b0;
    localparam ST_COLLECT = 1'b1;

    reg state;
    reg next_state;

    // Buffer is full when we have 5 pixels
    wire buffer_full = (col_count >= 3'd5);

    // Ready to accept new pixel when not full
    assign din_ready = !buffer_full;

    // Column output assignment
    assign col_0 = col_buf[0];
    assign col_1 = col_buf[1];
    assign col_2 = col_buf[2];
    assign col_3 = col_buf[3];
    assign col_4 = col_buf[4];
    assign column_valid = col_valid_reg;
    assign col_center_x = center_x_reg;
    assign col_center_y = center_y_reg;

    //=========================================================================
    // State Transition
    //=========================================================================
    always @(*) begin
        next_state = state;
        case (state)
            ST_IDLE: begin
                if (din_valid && !buffer_full)
                    next_state = ST_COLLECT;
            end

            ST_COLLECT: begin
                if (buffer_full && column_ready)
                    next_state = ST_IDLE;  // Column consumed, back to idle
                else if (buffer_full && !column_ready)
                    next_state = ST_COLLECT;  // Stay, waiting for column_ready
            end

            default: next_state = ST_IDLE;
        endcase
    end

    //=========================================================================
    // State Register
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
        end else if (sof) begin
            state <= ST_IDLE;
        end else if (enable) begin
            state <= next_state;
        end
    end

    //=========================================================================
    // Column Buffer Logic
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_count <= 0;
            col_valid_reg <= 1'b0;
            col_buf[0] <= {DATA_WIDTH{1'b0}};
            col_buf[1] <= {DATA_WIDTH{1'b0}};
            col_buf[2] <= {DATA_WIDTH{1'b0}};
            col_buf[3] <= {DATA_WIDTH{1'b0}};
            col_buf[4] <= {DATA_WIDTH{1'b0}};
        end else if (sof) begin
            col_count <= 0;
            col_valid_reg <= 1'b0;
            col_buf[0] <= {DATA_WIDTH{1'b0}};
            col_buf[1] <= {DATA_WIDTH{1'b0}};
            col_buf[2] <= {DATA_WIDTH{1'b0}};
            col_buf[3] <= {DATA_WIDTH{1'b0}};
            col_buf[4] <= {DATA_WIDTH{1'b0}};
        end else if (enable) begin
            case (state)
                ST_IDLE: begin
                    if (din_valid && !buffer_full) begin
                        // Start collecting
                        col_buf[0] <= din;
                        col_buf[1] <= {DATA_WIDTH{1'b0}};
                        col_buf[2] <= {DATA_WIDTH{1'b0}};
                        col_buf[3] <= {DATA_WIDTH{1'b0}};
                        col_buf[4] <= {DATA_WIDTH{1'b0}};
                        col_count <= 1;
                        center_x_reg <= center_x;
                        center_y_reg <= center_y;
                        col_valid_reg <= 1'b0;
                    end
                end

                ST_COLLECT: begin
                    if (buffer_full && column_ready) begin
                        // Column consumed
                        col_valid_reg <= 1'b0;
                        col_count <= 0;
                    end else if (din_valid && !buffer_full) begin
                        // Collect pixel
                        case (col_count)
                            3'd0: col_buf[0] <= din;
                            3'd1: col_buf[1] <= din;
                            3'd2: col_buf[2] <= din;
                            3'd3: col_buf[3] <= din;
                            3'd4: col_buf[4] <= din;
                        endcase
                        col_count <= col_count + 1'b1;

                        // When buffer becomes full, assert column_valid
                        if (col_count >= 3'd4) begin
                            col_valid_reg <= 1'b1;
                        end
                    end
                end
            endcase
        end
    end

endmodule
