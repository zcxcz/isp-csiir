//-----------------------------------------------------------------------------
// Module: common_fifo
// Description: Parameterized synchronous FIFO
//              Supports configurable depth, data width, and almost full/empty flags
//              Pure Verilog-2001 compatible
//-----------------------------------------------------------------------------

module common_fifo #(
    parameter DATA_WIDTH = 8,
    parameter DEPTH      = 16,
    parameter ALMOST_FULL_THRESH  = DEPTH - 2,
    parameter ALMOST_EMPTY_THRESH = 2,
    parameter OUTPUT_REG = 1       // 1 = registered output, 0 = combinational
)(
    input  wire                      clk,
    input  wire                      rst_n,

    // Write interface
    input  wire                      wr_en,
    input  wire [DATA_WIDTH-1:0]     din,

    // Read interface
    input  wire                      rd_en,
    output wire [DATA_WIDTH-1:0]     dout,

    // Status flags
    output wire                      full,
    output wire                      empty,
    output wire                      almost_full,
    output wire                      almost_empty,
    output wire [$clog2(DEPTH):0]    count
);

    // Local parameters
    localparam ADDR_WIDTH = $clog2(DEPTH);

    // Memory array
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // Read and write pointers
    reg [ADDR_WIDTH:0] wr_ptr;
    reg [ADDR_WIDTH:0] rd_ptr;

    // Gray-coded pointers for comparison (optional, for async clock crossing)
    wire [ADDR_WIDTH:0] wr_ptr_gray;
    wire [ADDR_WIDTH:0] rd_ptr_gray;

    // Full and empty detection
    wire wr_ptr_msb = wr_ptr[ADDR_WIDTH];
    wire rd_ptr_msb = rd_ptr[ADDR_WIDTH];
    wire [ADDR_WIDTH-1:0] wr_ptr_lsb = wr_ptr[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0] rd_ptr_lsb = rd_ptr[ADDR_WIDTH-1:0];

    // Memory write
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset memory (optional, for simulation)
        end else if (wr_en && !full) begin
            mem[wr_ptr_lsb] <= din;
        end
    end

    // Pointer update
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= {(ADDR_WIDTH+1){1'b0}};
            rd_ptr <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            if (wr_en && !full)
                wr_ptr <= wr_ptr + 1'b1;
            if (rd_en && !empty)
                rd_ptr <= rd_ptr + 1'b1;
        end
    end

    // Status signals
    assign full  = (wr_ptr_msb != rd_ptr_msb) && (wr_ptr_lsb == rd_ptr_lsb);
    assign empty = (wr_ptr == rd_ptr);

    // Count calculation
    assign count = wr_ptr - rd_ptr;

    // Almost full/empty
    assign almost_full  = (count >= ALMOST_FULL_THRESH);
    assign almost_empty = (count <= ALMOST_EMPTY_THRESH);

    // Data output (registered or combinational)
    generate
        if (OUTPUT_REG) begin : gen_reg_output
            reg [DATA_WIDTH-1:0] dout_reg;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    dout_reg <= {DATA_WIDTH{1'b0}};
                else if (rd_en && !empty)
                    dout_reg <= mem[rd_ptr_lsb];
            end
            assign dout = dout_reg;
        end else begin : gen_comb_output
            assign dout = mem[rd_ptr_lsb];
        end
    endgenerate

endmodule