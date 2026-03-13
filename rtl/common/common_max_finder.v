//-----------------------------------------------------------------------------
// Module: common_max_finder
// Description: Find maximum value among multiple inputs using tree structure
//              Optimized for timing with optional pipelining
//-----------------------------------------------------------------------------

module common_max_finder #(
    parameter NUM_INPUTS  = 3,
    parameter DATA_WIDTH  = 12,
    parameter PIPELINE    = 1
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          enable,
    input  wire [DATA_WIDTH-1:0]         din [0:NUM_INPUTS-1],
    input  wire                          valid_in,

    output wire [DATA_WIDTH-1:0]         max_out,
    output wire                          valid_out
);

    // Local parameters
    localparam TREE_DEPTH = $clog2(NUM_INPUTS);

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

    localparam NUM_PADDED = next_pow2(NUM_INPUTS);

    // Internal signals
    reg [DATA_WIDTH-1:0] level_max [0:TREE_DEPTH][0:NUM_PADDED-1];
    reg                  valid_pipe [0:TREE_DEPTH];

    // Input padding
    genvar i;
    generate
        for (i = 0; i < NUM_PADDED; i = i + 1) begin : gen_input_pad
            if (i < NUM_INPUTS)
                assign level_max[0][i] = din[i];
            else
                assign level_max[0][i] = {DATA_WIDTH{1'b0}};
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

    // Generate max finder tree
    generate
        genvar level, pair;
        for (level = 0; level < TREE_DEPTH; level = level + 1) begin : gen_tree_level
            localparam NUM_AT_LEVEL = NUM_PADDED / (2 ** (level + 1));

            for (pair = 0; pair < NUM_AT_LEVEL; pair = pair + 1) begin : gen_max
                if (PIPELINE) begin : gen_pipelined
                    always @(posedge clk or negedge rst_n) begin
                        if (!rst_n) begin
                            level_max[level+1][pair] <= {DATA_WIDTH{1'b0}};
                        end else if (enable && valid_pipe[level]) begin
                            level_max[level+1][pair] <=
                                (level_max[level][pair*2] > level_max[level][pair*2+1]) ?
                                level_max[level][pair*2] : level_max[level][pair*2+1];
                        end
                    end
                end else begin : gen_combinational
                    always @(*) begin
                        level_max[level+1][pair] =
                            (level_max[level][pair*2] > level_max[level][pair*2+1]) ?
                            level_max[level][pair*2] : level_max[level][pair*2+1];
                    end
                end
            end

            // Valid signal propagation
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    valid_pipe[level+1] <= 1'b0;
                else if (enable)
                    valid_pipe[level+1] <= valid_pipe[level];
            end
        end
    endgenerate

    // Output assignment
    assign max_out   = level_max[TREE_DEPTH][0];
    assign valid_out = valid_pipe[TREE_DEPTH];

endmodule