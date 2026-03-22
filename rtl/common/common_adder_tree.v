//-----------------------------------------------------------------------------
// Module: common_adder_tree
// Purpose: Balanced adder tree for multi-input summation
// Author: rtl-impl
// Date: 2026-03-22
// Version: v1.0
//-----------------------------------------------------------------------------
// Description:
//   Parameterized balanced adder tree supporting:
//   - Configurable number of inputs
//   - Configurable data width
//   - Optional pipelining
//   - Optimized for timing (logarithmic depth)
//-----------------------------------------------------------------------------

module common_adder_tree #(
    parameter NUM_INPUTS  = 5,
    parameter DATA_WIDTH  = 10,
    parameter PIPELINE    = 0    // 0: no pipeline, 1: pipeline each stage
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,
    input  wire [DATA_WIDTH-1:0]       din [0:NUM_INPUTS-1],
    input  wire                        din_valid,
    output reg  [DATA_WIDTH+$clog2(NUM_INPUTS)-1:0] dout,
    output reg                          dout_valid
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam TREE_DEPTH = $clog2(NUM_INPUTS);
    localparam OUT_WIDTH  = DATA_WIDTH + $clog2(NUM_INPUTS);

    //=========================================================================
    // Internal Signals
    //=========================================================================
    // Tree levels: level 0 = inputs, level TREE_DEPTH = output
    reg [OUT_WIDTH-1:0] tree [0:TREE_DEPTH][0:NUM_INPUTS-1];
    reg                 valid_reg [0:TREE_DEPTH];

    integer level, node;
    integer i;

    //=========================================================================
    // Input Registration
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < NUM_INPUTS; i = i + 1) begin
                tree[0][i] <= {OUT_WIDTH{1'b0}};
            end
            valid_reg[0] <= 1'b0;
        end else if (enable) begin
            for (i = 0; i < NUM_INPUTS; i = i + 1) begin
                tree[0][i] <= {{(OUT_WIDTH-DATA_WIDTH){1'b0}}, din[i]};
            end
            valid_reg[0] <= din_valid;
        end
    end

    //=========================================================================
    // Adder Tree Logic
    //=========================================================================
    genvar g_level, g_node;

    generate
        for (g_level = 1; g_level <= TREE_DEPTH; g_level = g_level + 1) begin : gen_level
            localparam NODES_AT_LEVEL = (NUM_INPUTS + (1 << g_level) - 1) >> g_level;

            if (PIPELINE == 1) begin : gen_pipeline
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (node = 0; node < NODES_AT_LEVEL; node = node + 1) begin
                            tree[g_level][node] <= {OUT_WIDTH{1'b0}};
                        end
                        valid_reg[g_level] <= 1'b0;
                    end else if (enable) begin
                        for (node = 0; node < NODES_AT_LEVEL; node = node + 1) begin
                            if ((node * 2 + 1) < NUM_INPUTS >> (g_level - 1)) begin
                                // Add pair
                                tree[g_level][node] <= tree[g_level-1][node*2] +
                                                      tree[g_level-1][node*2+1];
                            end else begin
                                // Pass through single
                                tree[g_level][node] <= tree[g_level-1][node*2];
                            end
                        end
                        valid_reg[g_level] <= valid_reg[g_level-1];
                    end
                end
            end else begin : gen_comb
                always @(*) begin
                    for (node = 0; node < NODES_AT_LEVEL; node = node + 1) begin
                        if ((node * 2 + 1) < NUM_INPUTS >> (g_level - 1)) begin
                            tree[g_level][node] = tree[g_level-1][node*2] +
                                                  tree[g_level-1][node*2+1];
                        end else begin
                            tree[g_level][node] = tree[g_level-1][node*2];
                        end
                    end
                end
            end
        end
    endgenerate

    //=========================================================================
    // Output Assignment
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout       <= {OUT_WIDTH{1'b0}};
            dout_valid <= 1'b0;
        end else if (enable) begin
            if (PIPELINE == 1) begin
                dout       <= tree[TREE_DEPTH][0];
                dout_valid <= valid_reg[TREE_DEPTH];
            end else begin
                // Combinational path needs output registration
                dout       <= tree[TREE_DEPTH][0];
                dout_valid <= valid_reg[0];
            end
        end
    end

endmodule