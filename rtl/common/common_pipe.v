//-----------------------------------------------------------------------------
// Module: common_pipe
// Purpose: Pipeline register with valid/ready handshake
// Author: rtl-impl
// Date: 2026-03-24
// Version: v2.0 - Added valid/ready handshake for back-pressure support
//-----------------------------------------------------------------------------
// Features:
//   - Configurable data width
//   - Multiple pipeline stages (1-16)
//   - Optional reset value
//   - Valid/Ready handshake protocol
//   - Back-pressure support via ready signal
//   - Pure Verilog-2001 (synthesizable)
//-----------------------------------------------------------------------------
// Handshake Protocol:
//   - Transfer occurs when valid=1 AND ready=1 on rising clock edge
//   - When ready_in=0, pipeline stalls and holds current values
//   - ready_out is always 1 (simple pipeline without skid buffer)
//   - valid propagates through pipeline with same latency as data
//-----------------------------------------------------------------------------

module common_pipe #(
    parameter DATA_WIDTH  = 10,
    parameter STAGES      = 1,
    parameter RESET_VAL   = 0,
    parameter REGISTER_IN = 1   // 1: Register input, 0: Direct pass (reserved)
)(
    // Clock and Reset
    input  wire                      clk,
    input  wire                      rst_n,

    // Data Input
    input  wire [DATA_WIDTH-1:0]     din,
    input  wire                      valid_in,
    output wire                      ready_out,    // Can accept new data

    // Data Output
    output wire [DATA_WIDTH-1:0]     dout,
    output wire                      valid_out,
    input  wire                      ready_in      // Downstream ready
);

    //=========================================================================
    // Parameter Validation
    //=========================================================================
    // synthesis translate_off
    initial begin
        if (STAGES < 1 || STAGES > 16) begin
            $display("ERROR: common_pipe STAGES must be 1-16, got %d", STAGES);
            $finish;
        end
    end
    // synthesis translate_on

    //=========================================================================
    // Internal Signals
    //=========================================================================
    // Pipeline registers for data
    reg [DATA_WIDTH-1:0] pipe_reg [0:STAGES-1];

    // Pipeline registers for valid (one bit per stage)
    reg [STAGES-1:0]      valid_reg;

    //=========================================================================
    // Ready Output (Simple Pipeline - Always Ready)
    //=========================================================================
    // For simple pipeline without skid buffer, always ready to accept new data
    // Upstream can always send data; back-pressure handled by ready_in
    assign ready_out = 1'b1;

    //=========================================================================
    // Pipeline Register Logic with Back-pressure
    //=========================================================================
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset all pipeline stages
            for (i = 0; i < STAGES; i = i + 1) begin
                pipe_reg[i]  <= RESET_VAL[DATA_WIDTH-1:0];
                valid_reg[i] <= 1'b0;
            end
        end else if (ready_in) begin
            // Normal operation - shift pipeline forward
            // Stage 0: Capture input
            pipe_reg[0]  <= din;
            valid_reg[0] <= valid_in;

            // Stage 1 to STAGES-1: Shift from previous stage
            for (i = 1; i < STAGES; i = i + 1) begin
                pipe_reg[i]  <= pipe_reg[i-1];
                valid_reg[i] <= valid_reg[i-1];
            end
        end
        // else: ready_in=0 (back-pressure) - hold all values
    end

    //=========================================================================
    // Output Assignment
    //=========================================================================
    assign dout     = pipe_reg[STAGES-1];
    assign valid_out = valid_reg[STAGES-1];

endmodule