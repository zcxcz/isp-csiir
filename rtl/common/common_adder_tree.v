//-----------------------------------------------------------------------------
// Module: common_adder_tree
// Description: Balanced adder tree for multi-input summation
//              Optimized for timing by using tree structure
//              Pure Verilog-2001 compatible (flattened input bus)
//-----------------------------------------------------------------------------

module common_adder_tree #(
    parameter NUM_INPUTS  = 5,
    parameter DATA_WIDTH  = 8,
    parameter PIPELINE    = 1       // 0 = no pipeline, 1 = pipeline at each tree level
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          enable,
    input  wire [NUM_INPUTS*DATA_WIDTH-1:0] din,  // Flattened input bus
    input  wire                          valid_in,

    output wire [DATA_WIDTH+$clog2(NUM_INPUTS)-1:0] dout,
    output wire                          valid_out
);

    // Local parameters
    localparam TREE_DEPTH = (NUM_INPUTS > 1) ? $clog2(NUM_INPUTS) : 1;
    localparam OUT_WIDTH  = DATA_WIDTH + TREE_DEPTH;

    // Calculate next power of 2
    function integer next_pow2;
        input integer n;
        integer p;
        begin
            p = 1;
            while (p < n) p = p * 2;
            next_pow2 = p;
        end
    endfunction

    localparam NUM_PADDED = (NUM_INPUTS > 1) ? next_pow2(NUM_INPUTS) : 1;

    // Internal signals - use wires for each level
    wire [OUT_WIDTH-1:0] level0_data [0:NUM_PADDED-1];
    reg [OUT_WIDTH-1:0] level_data [1:TREE_DEPTH][0:NUM_PADDED-1];
    reg                  valid_pipe [0:TREE_DEPTH];

    // Extract inputs from flattened bus
    genvar i;
    generate
        for (i = 0; i < NUM_PADDED; i = i + 1) begin : gen_input_pad
            if (i < NUM_INPUTS)
                assign level0_data[i] = {{TREE_DEPTH{1'b0}}, din[(i+1)*DATA_WIDTH-1 : i*DATA_WIDTH]};
            else
                assign level0_data[i] = {(OUT_WIDTH){1'b0}};
        end
    endgenerate

    // Stage 0 valid register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            valid_pipe[0] <= 1'b0;
        else if (enable)
            valid_pipe[0] <= valid_in;
        else
            valid_pipe[0] <= 1'b0;
    end

    // Generate adder tree
    generate
        genvar level, pair;
        for (level = 0; level < TREE_DEPTH; level = level + 1) begin : gen_tree_level
            localparam NUM_AT_LEVEL = NUM_PADDED / (2 ** (level + 1));

            for (pair = 0; pair < NUM_AT_LEVEL; pair = pair + 1) begin : gen_adders
                if (PIPELINE) begin : gen_pipelined
                    always @(posedge clk or negedge rst_n) begin
                        if (!rst_n) begin
                            level_data[level+1][pair] <= {(OUT_WIDTH){1'b0}};
                        end else if (enable && valid_pipe[level]) begin
                            if (level == 0)
                                level_data[level+1][pair] <= level0_data[pair*2] + level0_data[pair*2+1];
                            else
                                level_data[level+1][pair] <= level_data[level][pair*2] + level_data[level][pair*2+1];
                        end
                    end
                end else begin : gen_combinational
                    // Combinational not supported in this version - use pipelined
                    always @(posedge clk or negedge rst_n) begin
                        if (!rst_n) begin
                            level_data[level+1][pair] <= {(OUT_WIDTH){1'b0}};
                        end else if (enable && valid_pipe[level]) begin
                            if (level == 0)
                                level_data[level+1][pair] <= level0_data[pair*2] + level0_data[pair*2+1];
                            else
                                level_data[level+1][pair] <= level_data[level][pair*2] + level_data[level][pair*2+1];
                        end
                    end
                end
            end

            // Valid signal propagation
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    valid_pipe[level+1] <= 1'b0;
                else if (enable)
                    valid_pipe[level+1] <= valid_pipe[level];
                else
                    valid_pipe[level+1] <= 1'b0;
            end
        end
    endgenerate

    // Output assignment
    assign dout     = (TREE_DEPTH > 0) ? level_data[TREE_DEPTH][0] : level0_data[0];
    assign valid_out = valid_pipe[TREE_DEPTH];

endmodule