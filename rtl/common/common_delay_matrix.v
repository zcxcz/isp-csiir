//-----------------------------------------------------------------------------
// Module: common_delay_matrix
// Purpose: Multi-column shift register delay matrix
// Author: rtl-impl
// Date: 2026-04-13
// Version: v1.0
//-----------------------------------------------------------------------------
// Description:
//   Parameterized 2D shift register supporting:
//   - Configurable data width per column
//   - Configurable number of columns
//   - Configurable number of delay stages
//   - Column-by-column independent delay
//
//   This module replaces always-block delay descriptions in functional modules.
//   Use when a module needs to delay multi-channel data (e.g., 5x1 column delay).
//
// Usage:
//   For 5x1 column delay (5 columns, 5 stages deep):
//     common_delay_matrix #(.DATA_WIDTH(10), .NUM_COLS(5), .STAGES(5)) u_col_delay (...);
//
// Parameters:
//   DATA_WIDTH - Bit width of each column data
//   NUM_COLS  - Number of columns (e.g., 5 for 5x1 patch)
//   STAGES    - Number of delay stages
//-----------------------------------------------------------------------------

module common_delay_matrix #(
    parameter DATA_WIDTH  = 10,
    parameter NUM_COLS    = 5,
    parameter STAGES      = 5
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,
    input  wire [DATA_WIDTH*NUM_COLS-1:0] din_flat,
    output wire [DATA_WIDTH*NUM_COLS-1:0] dout_flat,
    output wire [DATA_WIDTH*NUM_COLS*STAGES-1:0] tap_flat
);

    //=========================================================================
    // Internal Signals
    //=========================================================================
    // [stage][column] - delay_reg[0] is input, delay_reg[STAGES-1] is output
    reg [DATA_WIDTH-1:0] delay_reg [0:STAGES-1][0:NUM_COLS-1];

    integer s, c;

    //=========================================================================
    // Delay Matrix Logic
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (s = 0; s < STAGES; s = s + 1) begin
                for (c = 0; c < NUM_COLS; c = c + 1) begin
                    delay_reg[s][c] <= {DATA_WIDTH{1'b0}};
                end
            end
        end else if (enable) begin
            // Input stage: unpack from flattened input
            for (c = 0; c < NUM_COLS; c = c + 1) begin
                delay_reg[0][c] <= din_flat[c*DATA_WIDTH +: DATA_WIDTH];
            end
            // Shift through stages
            for (s = 1; s < STAGES; s = s + 1) begin
                for (c = 0; c < NUM_COLS; c = c + 1) begin
                    delay_reg[s][c] <= delay_reg[s-1][c];
                end
            end
        end
    end

    //=========================================================================
    // Output Assignment
    //=========================================================================
    // dout_flat is the final delayed output (last stage) - pack to flattened
    genvar g_dout;
    generate
        for (g_dout = 0; g_dout < NUM_COLS; g_dout = g_dout + 1) begin : gen_dout
            assign dout_flat[g_dout*DATA_WIDTH +: DATA_WIDTH] = delay_reg[STAGES-1][g_dout];
        end
    endgenerate

    // tap outputs for each stage - pack to flattened
    genvar g_s, g_c;
    generate
        for (g_s = 0; g_s < STAGES; g_s = g_s + 1) begin : gen_stage
            for (g_c = 0; g_c < NUM_COLS; g_c = g_c + 1) begin : gen_col
                assign tap_flat[(g_s*NUM_COLS+g_c)*DATA_WIDTH +: DATA_WIDTH] = delay_reg[g_s][g_c];
            end
        end
    endgenerate

endmodule
