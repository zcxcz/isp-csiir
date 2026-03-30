//-----------------------------------------------------------------------------
// Module: common_skid_buffer
// Purpose: Compatibility wrapper for common_pipe_slice skid mode
// Author: rtl-impl
// Date: 2026-03-29
// Version: v1.1
//-----------------------------------------------------------------------------
// Notes:
//   - This module keeps the previous skid-buffer interface for compatibility
//   - For new common-module usage, prefer common_pipe_slice and set PIPE_TYPE
//   - common_skid_buffer is equivalent to common_pipe_slice with PIPE_TYPE=1
//-----------------------------------------------------------------------------

module common_skid_buffer #(
    parameter DATA_WIDTH = 10,
    parameter RESET_VAL  = 0
) (
    input  wire                  clk,
    input  wire                  rst_n,

    input  wire [DATA_WIDTH-1:0] din,
    input  wire                  valid_in,
    output wire                  ready_out,

    output wire [DATA_WIDTH-1:0] dout,
    output wire                  valid_out,
    input  wire                  ready_in
);

    common_pipe_slice #(
        .DATA_WIDTH (DATA_WIDTH),
        .RESET_VAL  (RESET_VAL),
        .PIPE_TYPE  (1)
    ) u_pipe_slice (
        .clk       (clk),
        .rst_n     (rst_n),
        .din       (din),
        .valid_in  (valid_in),
        .ready_out (ready_out),
        .dout      (dout),
        .valid_out (valid_out),
        .ready_in  (ready_in)
    );

endmodule
