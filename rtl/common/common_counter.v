//-----------------------------------------------------------------------------
// Module: common_counter
// Purpose: Up/down counter with configurable range
// Author: rtl-impl
// Date: 2026-03-22
// Version: v1.0
//-----------------------------------------------------------------------------
// Description:
//   Parameterized up/down counter supporting:
//   - Configurable data width
//   - Min/max range limits
//   - Load capability
//   - Count enable
//-----------------------------------------------------------------------------

module common_counter #(
    parameter DATA_WIDTH  = 10,
    parameter COUNT_MIN   = 0,
    parameter COUNT_MAX   = 1023
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      enable,
    input  wire                      count_up,
    input  wire                      count_down,
    input  wire                      load,
    input  wire [DATA_WIDTH-1:0]     load_data,
    output wire [DATA_WIDTH-1:0]     count,
    output wire                      at_min,
    output wire                      at_max
);

    //=========================================================================
    // Internal Signals
    //=========================================================================
    reg [DATA_WIDTH-1:0] count_reg;

    //=========================================================================
    // Counter Logic
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count_reg <= COUNT_MIN[DATA_WIDTH-1:0];
        end else if (load) begin
            count_reg <= load_data;
        end else if (enable) begin
            if (count_up && !at_max) begin
                count_reg <= count_reg + 1'b1;
            end else if (count_down && !at_min) begin
                count_reg <= count_reg - 1'b1;
            end
        end
    end

    //=========================================================================
    // Output Assignment
    //=========================================================================
    assign count  = count_reg;
    assign at_min = (count_reg == COUNT_MIN[DATA_WIDTH-1:0]);
    assign at_max = (count_reg == COUNT_MAX[DATA_WIDTH-1:0]);

endmodule