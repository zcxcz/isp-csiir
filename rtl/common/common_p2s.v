//-----------------------------------------------------------------------------
// Module: common_p2s
// Purpose: UV5x1 to column deserializer
//          Splits UV5x1 matrix into u-column and v-column outputs
// Author: rtl-impl
// Date: 2026-04-15
//-----------------------------------------------------------------------------
// Description:
//   Receives UV5x1 matrix (5 rows × 2 components packed),
//   outputs column format (5 pixels parallel).
//
//   UV5x1 input format (100 bits total):
//   - bit [99:90] = u4, bit [89:80] = v4  (row 4, newest)
//   - bit [79:70] = u3, bit [69:60] = v3  (row 3)
//   - bit [59:50] = u2, bit [49:40] = v2  (row 2)
//   - bit [39:30] = u1, bit [29:20] = v1  (row 1)
//   - bit [19:10] = u0, bit [9:0] = v0    (row 0, oldest)
//
//   Each component is 10 bits (DATA_WIDTH).
//
//   Output sequence:
//   - Cycle 1: u column (col_0~col_4 = u0~u4)
//   - Cycle 2: v column (col_0~col_4 = v0~v4)
//
// Parameters:
//   DATA_WIDTH - Bit width of each component (u or v)
//-----------------------------------------------------------------------------

module common_p2s #(
    parameter DATA_WIDTH = 10,
    parameter LINE_ADDR_WIDTH = 14,
    parameter ROW_CNT_WIDTH = 13
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    enable,
    input  wire                    sof,        // Start of frame - reset state

    // UV5x1 input (5 rows × 2 components, packed)
    // Format: {u4, v4, u3, v3, u2, v2, u1, v1, u0, v0} = 100 bits
    input  wire [DATA_WIDTH*10-1:0] uv5x1_in,
    input  wire                    din_valid,
    output wire                    din_ready,

    // Column output (5 pixels parallel)
    output wire [DATA_WIDTH-1:0] col_0,
    output wire [DATA_WIDTH-1:0] col_1,
    output wire [DATA_WIDTH-1:0] col_2,
    output wire [DATA_WIDTH-1:0] col_3,
    output wire [DATA_WIDTH-1:0] col_4,
    output wire                    column_valid,
    input  wire                    column_ready,

    // UV column indicator: 0=u column, 1=v column
    output wire                    is_v_column,

    // Metadata passthrough
    input  wire [LINE_ADDR_WIDTH-1:0] center_x,
    input  wire [ROW_CNT_WIDTH-1:0]   center_y,
    output wire [LINE_ADDR_WIDTH-1:0] col_center_x,
    output wire [ROW_CNT_WIDTH-1:0]   col_center_y
);

    // State machine
    localparam ST_IDLE   = 2'b00;
    localparam ST_OUTPUT_U = 2'b01;  // Outputting u column
    localparam ST_OUTPUT_V = 2'b10;  // Outputting v column

    reg [1:0] state;
    reg [1:0] next_state;

    // Metadata registers
    reg [LINE_ADDR_WIDTH-1:0] center_x_reg;
    reg [ROW_CNT_WIDTH-1:0]   center_y_reg;

    // UV5x1 buffer
    reg [DATA_WIDTH*10-1:0] uv5x1_buf;

    // Output valid
    reg column_valid_reg;

    //=========================================================================
    // State Transition
    //=========================================================================
    always @(*) begin
        next_state = state;
        case (state)
            ST_IDLE: begin
                if (din_valid && enable)
                    next_state = ST_OUTPUT_U;
            end

            ST_OUTPUT_U: begin
                if (column_ready)
                    next_state = ST_OUTPUT_V;
            end

            ST_OUTPUT_V: begin
                if (column_ready) begin
                    if (din_valid && enable)
                        next_state = ST_OUTPUT_U;
                    else
                        next_state = ST_IDLE;
                end
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
    // UV5x1 Buffer Latch
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uv5x1_buf <= {DATA_WIDTH*10{1'b0}};
        end else if (sof) begin
            uv5x1_buf <= {DATA_WIDTH*10{1'b0}};
        end else if (enable) begin
            if (state == ST_IDLE && din_valid) begin
                uv5x1_buf <= uv5x1_in;
            end
        end
    end

    //=========================================================================
    // Metadata Latch
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            center_x_reg <= {LINE_ADDR_WIDTH{1'b0}};
            center_y_reg <= {ROW_CNT_WIDTH{1'b0}};
        end else if (sof) begin
            center_x_reg <= {LINE_ADDR_WIDTH{1'b0}};
            center_y_reg <= {ROW_CNT_WIDTH{1'b0}};
        end else if (enable) begin
            if (state == ST_IDLE && din_valid) begin
                center_x_reg <= center_x;
                center_y_reg <= center_y;
            end
        end
    end

    //=========================================================================
    // Output Logic
    //=========================================================================
    // UV5x1 bit layout:
    // bit [99:90] = u4, bit [89:80] = v4  (row 4)
    // bit [79:70] = u3, bit [69:60] = v3  (row 3)
    // bit [59:50] = u2, bit [49:40] = v2  (row 2)
    // bit [39:30] = u1, bit [29:20] = v1  (row 1)
    // bit [19:10] = u0, bit [9:0] = v0    (row 0)

    // Column output: col_0 = oldest (row 0), col_4 = newest (row 4)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            column_valid_reg <= 1'b0;
        end else if (sof) begin
            column_valid_reg <= 1'b0;
        end else if (enable) begin
            case (state)
                ST_IDLE: begin
                    column_valid_reg <= 1'b0;
                end

                ST_OUTPUT_U: begin
                    if (column_ready)
                        column_valid_reg <= 1'b0;
                    else
                        column_valid_reg <= 1'b1;
                end

                ST_OUTPUT_V: begin
                    if (column_ready)
                        column_valid_reg <= 1'b0;
                end

                default: column_valid_reg <= 1'b0;
            endcase
        end
    end

    //=========================================================================
    // Output Assignment
    //=========================================================================
    // UV5x1 bit layout:
    // bit [99:90] = u4, bit [89:80] = v4  (row 4)
    // bit [79:70] = u3, bit [69:60] = v3  (row 3)
    // bit [59:50] = u2, bit [49:40] = v2  (row 2)
    // bit [39:30] = u1, bit [29:20] = v1  (row 1)
    // bit [19:10] = u0, bit [9:0] = v0    (row 0)

    wire [DATA_WIDTH-1:0] u0 = uv5x1_buf[10 +: DATA_WIDTH];  // bit [19:10]
    wire [DATA_WIDTH-1:0] u1 = uv5x1_buf[30 +: DATA_WIDTH];  // bit [39:30]
    wire [DATA_WIDTH-1:0] u2 = uv5x1_buf[50 +: DATA_WIDTH];  // bit [59:50]
    wire [DATA_WIDTH-1:0] u3 = uv5x1_buf[70 +: DATA_WIDTH];  // bit [79:70]
    wire [DATA_WIDTH-1:0] u4 = uv5x1_buf[90 +: DATA_WIDTH];  // bit [99:90]

    wire [DATA_WIDTH-1:0] v0 = uv5x1_buf[0 +: DATA_WIDTH];   // bit [9:0]
    wire [DATA_WIDTH-1:0] v1 = uv5x1_buf[20 +: DATA_WIDTH];  // bit [29:20]
    wire [DATA_WIDTH-1:0] v2 = uv5x1_buf[40 +: DATA_WIDTH];  // bit [49:40]
    wire [DATA_WIDTH-1:0] v3 = uv5x1_buf[60 +: DATA_WIDTH];  // bit [69:60]
    wire [DATA_WIDTH-1:0] v4 = uv5x1_buf[80 +: DATA_WIDTH];  // bit [89:80]

    // Column output: col_0 = row 0 (oldest), col_4 = row 4 (newest)
    assign col_0 = (state == ST_OUTPUT_V) ? v0 : u0;
    assign col_1 = (state == ST_OUTPUT_V) ? v1 : u1;
    assign col_2 = (state == ST_OUTPUT_V) ? v2 : u2;
    assign col_3 = (state == ST_OUTPUT_V) ? v3 : u3;
    assign col_4 = (state == ST_OUTPUT_V) ? v4 : u4;

    assign is_v_column = (state == ST_OUTPUT_V);

    assign column_valid = column_valid_reg;
    assign col_center_x = center_x_reg;
    assign col_center_y = center_y_reg;

    //=========================================================================
    // Ready Signal
    //=========================================================================
    assign din_ready = (state == ST_IDLE) ||
                      (state == ST_OUTPUT_V && column_ready);

endmodule
