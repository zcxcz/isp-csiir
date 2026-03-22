//-----------------------------------------------------------------------------
// Module: common_fifo
// Purpose: Synchronous FIFO
// Author: rtl-impl
// Date: 2026-03-22
// Version: v1.0
//-----------------------------------------------------------------------------
// Description:
//   Parameterized synchronous FIFO supporting:
//   - Configurable data width and depth
//   - Full/empty status flags
//   - Overflow/underflow protection
//-----------------------------------------------------------------------------

module common_fifo #(
    parameter DATA_WIDTH  = 10,
    parameter DEPTH       = 16,
    parameter ADDR_WIDTH  = 4  // log2(DEPTH)
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      wr_en,
    input  wire [DATA_WIDTH-1:0]     wr_data,
    input  wire                      rd_en,
    output wire [DATA_WIDTH-1:0]     rd_data,
    output wire                      empty,
    output wire                      full,
    output wire [ADDR_WIDTH:0]       count
);

    //=========================================================================
    // Internal Signals
    //=========================================================================
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_WIDTH:0]   wr_ptr;
    reg [ADDR_WIDTH:0]   rd_ptr;

    wire wr_valid;
    wire rd_valid;

    //=========================================================================
    // Pointer Management
    //=========================================================================
    assign wr_valid = wr_en && !full;
    assign rd_valid = rd_en && !empty;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            if (wr_valid) begin
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (rd_valid) begin
                rd_ptr <= rd_ptr + 1'b1;
            end
        end
    end

    //=========================================================================
    // Memory Write
    //=========================================================================
    always @(posedge clk) begin
        if (wr_valid) begin
            mem[wr_ptr[ADDR_WIDTH-1:0]] <= wr_data;
        end
    end

    //=========================================================================
    // Memory Read
    //=========================================================================
    assign rd_data = mem[rd_ptr[ADDR_WIDTH-1:0]];

    //=========================================================================
    // Status Flags
    //=========================================================================
    assign empty = (wr_ptr == rd_ptr);
    assign full  = (wr_ptr[ADDR_WIDTH] != rd_ptr[ADDR_WIDTH]) &&
                   (wr_ptr[ADDR_WIDTH-1:0] == rd_ptr[ADDR_WIDTH-1:0]);
    assign count = wr_ptr - rd_ptr;

endmodule