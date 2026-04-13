//-----------------------------------------------------------------------------
// Module: common_sram_model
// Purpose: General-purpose single-port SRAM model
// Author: rtl-impl
// Date: 2026-04-13
//-----------------------------------------------------------------------------
// Description:
//   Parameterized SRAM behavioral model with:
//   - Configurable data width per word
//   - Configurable address width
//   - Configurable depth
//   - Optional output register (for pipeline-friendly read)
//
//   This module replaces reg-array based memory descriptions in storage
//   modules. Use when a module needs on-chip SRAM behavior.
//
// Usage:
//   Single-port SRAM (read-during-write behavior: newer data wins):
//     common_sram_model #(.DATA_WIDTH(10), .ADDR_WIDTH(14), .DEPTH(8192)) u_sram (...);
//
// Parameters:
//   DATA_WIDTH - Bit width of each memory word
//   ADDR_WIDTH - Bit width of address bus
//   DEPTH      - Number of memory words
//   OUTPUT_REG - 1=registered read output, 0=combinational read
//-----------------------------------------------------------------------------

module common_sram_model #(
    parameter DATA_WIDTH  = 10,
    parameter ADDR_WIDTH = 14,
    parameter DEPTH      = 8192,
    parameter OUTPUT_REG  = 1      // 1: registered output (read latency=1), 0: combinational
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  enable,

    // Write port
    input  wire                  wr_en,
    input  wire [ADDR_WIDTH-1:0] wr_addr,
    input  wire [DATA_WIDTH-1:0] wr_data,

    // Read port
    input  wire                  rd_en,
    input  wire [ADDR_WIDTH-1:0] rd_addr,
    output wire [DATA_WIDTH-1:0] rd_data
);

    //=========================================================================
    // Memory Array
    //=========================================================================
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    //=========================================================================
    // Write Logic
    //=========================================================================
    always @(posedge clk) begin
        if (enable && wr_en) begin
            mem[wr_addr] <= wr_data;
        end
    end

    //=========================================================================
    // Read Logic
    //=========================================================================
    generate
        if (OUTPUT_REG == 1) begin : gen_reg_output
            reg [DATA_WIDTH-1:0] rd_data_reg;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    rd_data_reg <= {DATA_WIDTH{1'b0}};
                end else if (enable && rd_en) begin
                    rd_data_reg <= mem[rd_addr];
                end
            end
            assign rd_data = rd_data_reg;
        end else begin : gen_comb_output
            assign rd_data = mem[rd_addr];
        end
    endgenerate

endmodule
