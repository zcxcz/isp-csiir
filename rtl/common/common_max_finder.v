//-----------------------------------------------------------------------------
// Module: common_max_finder
// Purpose: Tree-structured maximum finder
// Author: rtl-impl
// Date: 2026-03-22
// Version: v1.0
//-----------------------------------------------------------------------------
// Description:
//   Parameterized maximum finder supporting:
//   - Configurable number of inputs
//   - Configurable data width
//   - Tree structure for logarithmic comparison depth
//-----------------------------------------------------------------------------

module common_max_finder #(
    parameter NUM_INPUTS  = 5,
    parameter DATA_WIDTH  = 10
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,
    input  wire [DATA_WIDTH-1:0]       din [0:NUM_INPUTS-1],
    input  wire                        din_valid,
    output reg  [DATA_WIDTH-1:0]       dout,
    output reg                         dout_valid
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam TREE_DEPTH = $clog2(NUM_INPUTS);

    //=========================================================================
    // Internal Signals
    //=========================================================================
    reg [DATA_WIDTH-1:0] tree [0:TREE_DEPTH][0:NUM_INPUTS-1];
    reg                  valid_reg;

    integer level, node;
    integer i;

    //=========================================================================
    // Input Registration
    //=========================================================================
    integer init_i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (init_i = 0; init_i < NUM_INPUTS; init_i = init_i + 1) begin
                tree[0][init_i] <= {DATA_WIDTH{1'b0}};
            end
            valid_reg <= 1'b0;
        end else if (enable) begin
            for (init_i = 0; init_i < NUM_INPUTS; init_i = init_i + 1) begin
                tree[0][init_i] <= din[init_i];
            end
            valid_reg <= din_valid;
        end
    end

    //=========================================================================
    // Max Finder Tree Logic
    //=========================================================================
    // Combinational comparison tree
    always @(*) begin
        // Level 0 is already registered input
        for (level = 1; level <= TREE_DEPTH; level = level + 1) begin
            for (node = 0; node < NUM_INPUTS; node = node + 1) begin
                if ((node * 2 + 1) < NUM_INPUTS) begin
                    // Compare pair
                    tree[level][node] = (tree[level-1][node*2] >=
                                         tree[level-1][node*2+1]) ?
                                         tree[level-1][node*2] :
                                         tree[level-1][node*2+1];
                end else if ((node * 2) < NUM_INPUTS) begin
                    // Pass through single
                    tree[level][node] = tree[level-1][node*2];
                end else begin
                    tree[level][node] = {DATA_WIDTH{1'b0}};
                end
            end
        end
    end

    //=========================================================================
    // Output Assignment
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout       <= {DATA_WIDTH{1'b0}};
            dout_valid <= 1'b0;
        end else if (enable) begin
            dout       <= tree[TREE_DEPTH][0];
            dout_valid <= valid_reg;
        end
    end

endmodule