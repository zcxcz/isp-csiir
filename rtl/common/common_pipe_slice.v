//-----------------------------------------------------------------------------
// Module: common_pipe_slice
// Purpose: Single-entry valid/ready pipe element with selectable structure
// Author: rtl-impl
// Date: 2026-03-29
// Version: v1.0
//-----------------------------------------------------------------------------
// Features:
//   - Configurable data width
//   - Optional reset value
//   - Correct ready/valid back-pressure propagation
//   - Selectable implementation via PIPE_TYPE
//   - Pure Verilog-2001 (synthesizable)
//-----------------------------------------------------------------------------
// PIPE_TYPE Description:
//   - 0: Registered slice
//        * dout/dout_valid come only from registers
//        * Suitable before CDC wrappers or async boundary modules that require
//          registered driving signals
//        * Adds one cycle of latency
//   - 1: Skid buffer
//        * Empty-buffer path bypasses input directly to output
//        * Zero extra latency in bypass mode
//        * dout/dout_valid contain combinational mux logic, so this mode should
//          not be used directly in front of CDC or async sink modules that
//          require register-driven inputs
//-----------------------------------------------------------------------------

module common_pipe_slice #(
    parameter DATA_WIDTH = 10,
    parameter RESET_VAL  = 0,
    parameter PIPE_TYPE  = 0
) (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire [DATA_WIDTH-1:0] din,
    input  wire                  din_valid,
    output wire                  din_ready,

    output wire [DATA_WIDTH-1:0] dout,
    output wire                  dout_valid,
    input  wire                  dout_ready
);

    localparam PIPE_TYPE_REG  = 0;
    localparam PIPE_TYPE_SKID = 1;

    // synthesis translate_off
    initial begin
        if ((PIPE_TYPE != PIPE_TYPE_REG) && (PIPE_TYPE != PIPE_TYPE_SKID)) begin
            $display("ERROR: common_pipe_slice PIPE_TYPE must be 0(REG) or 1(SKID), got %0d",
                     PIPE_TYPE);
            $finish;
        end
    end
    // synthesis translate_on

    generate
        if (PIPE_TYPE == PIPE_TYPE_REG) begin : g_reg_slice
            reg [DATA_WIDTH-1:0] data_reg;
            reg                  valid_reg;

            assign din_ready = !valid_reg || dout_ready;
            assign dout      = data_reg;
            assign dout_valid = valid_reg;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    valid_reg <= 1'b0;
                    data_reg  <= RESET_VAL[DATA_WIDTH-1:0];
                end else if (din_ready) begin
                    valid_reg <= din_valid;
                    if (din_valid)
                        data_reg <= din;
                end
            end
        end else begin : g_skid_slice
            reg [DATA_WIDTH-1:0] hold_data;
            reg                  hold_valid;

            wire bypass_en;
            wire accept_in;

            assign bypass_en = !hold_valid;
            assign din_ready = bypass_en || dout_ready;
            assign dout_valid = hold_valid ? 1'b1 : din_valid;
            assign dout      = hold_valid ? hold_data : din;
            assign accept_in = din_valid && din_ready;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    hold_valid <= 1'b0;
                    hold_data  <= RESET_VAL[DATA_WIDTH-1:0];
                end else if (hold_valid) begin
                    if (dout_ready) begin
                        if (accept_in) begin
                            hold_data  <= din;
                            hold_valid <= 1'b1;
                        end else begin
                            hold_valid <= 1'b0;
                        end
                    end
                end else if (accept_in && !dout_ready) begin
                    hold_data  <= din;
                    hold_valid <= 1'b1;
                end
            end
        end
    endgenerate

endmodule
