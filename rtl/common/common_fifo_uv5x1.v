//-----------------------------------------------------------------------------
// Module: common_fifo_uv5x1
// Purpose: Assemble 5 rows of 2P data into UV5x1 format
//          Collects linebuffer column data and current 2P din
// Author: rtl-impl
// Date: 2026-04-15
//-----------------------------------------------------------------------------
// Description:
//   When linebuffer outputs a column (5 rows of 2P data), this module
//   combines them with buffered 2P din to form UV5x1 matrix.
//
//   UV5x1 assembly (5 pixels, u and v):
//   - Row 0 (oldest): from linebuffer row 0
//   - Row 1: from linebuffer row 1
//   - Row 2: from linebuffer row 2
//   - Row 3: from linebuffer row 3
//   - Row 4 (newest): current 2P din (most recent sample)
//
//   Each 2P word format: {v[9:0], u[9:0]} (20 bits total)
//
//   Assembly happens when col_read_fire signal is asserted.
//   Output is a 100-bit word: 5 pixels * 2 components * 10 bits
//
// Parameters:
//   DATA_WIDTH - Bit width of each component (default 10)
//-----------------------------------------------------------------------------

module common_fifo_uv5x1 #(
    parameter DATA_WIDTH = 10
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  enable,
    input  wire                  sof,

    // Current 2P din (from s2p)
    input  wire [DATA_WIDTH*2-1:0] din_2p,
    input  wire                  din_valid,
    output wire                  din_ready,

    // Linebuffer column read interface
    input  wire [DATA_WIDTH*2-1:0] lb_row_0,  // row 0 (oldest)
    input  wire [DATA_WIDTH*2-1:0] lb_row_1,
    input  wire [DATA_WIDTH*2-1:0] lb_row_2,
    input  wire [DATA_WIDTH*2-1:0] lb_row_3,
    input  wire [DATA_WIDTH*2-1:0] lb_row_4,  // row 4 (newest in linebuffer)
    input  wire                  col_valid,   // column data valid
    input  wire                  col_ready,    // column data consumed

    // UV5x1 output
    output wire [DATA_WIDTH*10-1:0] uv5x1_out,  // 5 pixels * 2 components
    output wire                  uv5x1_valid,
    input  wire                  uv5x1_ready
);

    // UV5x1 format: 5 pixels, each with u and v
    // uv5x1_out bit layout (100 bits total):
    // [95:90] = u4, [89:80] = v4  (newest, from current din)
    // [79:70] = u3, [69:60] = v3
    // [59:50] = u2, [49:40] = v2
    // [39:30] = u1, [29:20] = v1
    // [19:10] = u0, [9:0] = v0  (oldest, from linebuffer)

    localparam FIFO_DEPTH = 4;

    //=========================================================================
    // FIFO for current 2P din (buffered until column read)
    //=========================================================================
    localparam CNT_WIDTH = 3;

    reg [DATA_WIDTH*2-1:0] fifo_mem [0:FIFO_DEPTH-1];
    reg [CNT_WIDTH-1:0] wr_ptr;
    reg [CNT_WIDTH-1:0] rd_ptr;
    reg [CNT_WIDTH-1:0] count;

    wire fifo_empty = (count == 0);
    wire fifo_full = (count >= FIFO_DEPTH);

    assign din_ready = !fifo_full;

    // Column read fire when column data is consumed
    wire col_read_fire = col_valid && col_ready;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            count <= 0;
        end else if (sof) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
            count <= 0;
        end else if (enable) begin
            if (din_valid && !fifo_full) begin
                fifo_mem[wr_ptr] <= din_2p;
                wr_ptr <= wr_ptr + 1'b1;
                count <= count + 1'b1;
            end

            if (col_read_fire && !fifo_empty) begin
                rd_ptr <= rd_ptr + 1'b1;
                count <= count - 1'b1;
            end
        end
    end

    wire [DATA_WIDTH*2-1:0] din_from_fifo = fifo_mem[rd_ptr];

    //=========================================================================
    // UV5x1 Assembly Register
    //=========================================================================
    // When col_read_fire, assemble 5 rows into UV5x1:
    // - Row 0 (oldest): lb_row_0
    // - Row 1: lb_row_1
    // - Row 2: lb_row_2
    // - Row 3: lb_row_3
    // - Row 4 (newest): din_from_fifo (current 2P)
    //
    // UV5x1 bit layout (100 bits total):
    // - bit [99:90] = u4, bit [89:80] = v4  (row 4, newest)
    // - bit [79:70] = u3, bit [69:60] = v3  (row 3)
    // - bit [59:50] = u2, bit [49:40] = v2  (row 2)
    // - bit [39:30] = u1, bit [29:20] = v1  (row 1)
    // - bit [19:10] = u0, bit [9:0] = v0    (row 0, oldest)
    //
    // Each 2P = {v[9:0], u[9:0]}, so:
    // - upper 10 bits = v
    // - lower 10 bits = u

    reg [DATA_WIDTH*10-1:0] uv5x1_reg;
    reg uv5x1_valid_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uv5x1_valid_reg <= 1'b0;
        end else if (sof) begin
            uv5x1_valid_reg <= 1'b0;
        end else if (enable) begin
            if (col_read_fire && !fifo_empty) begin
                // Assemble UV5x1
                // Format: {u4, v4, u3, v3, u2, v2, u1, v1, u0, v0}
                uv5x1_reg <= {
                    // Row 4 (newest): current 2P din
                    din_from_fifo[0 +: DATA_WIDTH],              // u4 = lower bits
                    din_from_fifo[DATA_WIDTH +: DATA_WIDTH],     // v4 = upper bits
                    // Row 3: lb_row_4 (newest in LB)
                    lb_row_4[0 +: DATA_WIDTH],
                    lb_row_4[DATA_WIDTH +: DATA_WIDTH],
                    // Row 2: lb_row_3
                    lb_row_3[0 +: DATA_WIDTH],
                    lb_row_3[DATA_WIDTH +: DATA_WIDTH],
                    // Row 1: lb_row_2
                    lb_row_2[0 +: DATA_WIDTH],
                    lb_row_2[DATA_WIDTH +: DATA_WIDTH],
                    // Row 0 (oldest): lb_row_1
                    lb_row_1[0 +: DATA_WIDTH],
                    lb_row_1[DATA_WIDTH +: DATA_WIDTH]
                };
                uv5x1_valid_reg <= 1'b1;
            end else if (uv5x1_valid_reg && uv5x1_ready) begin
                uv5x1_valid_reg <= 1'b0;
            end
        end
    end

    assign uv5x1_out = uv5x1_reg;
    assign uv5x1_valid = uv5x1_valid_reg;

endmodule
