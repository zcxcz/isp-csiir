//-----------------------------------------------------------------------------
// Module: common_s2p
// Purpose: Serial to Parallel converter
//          Converts Nx1 serial input to Mx1 parallel output
// Author: rtl-impl
// Date: 2026-04-15
// Modified: 2026-04-20
//-----------------------------------------------------------------------------
// Description:
//   Converts serial input (1 pixel per cycle) to parallel output (2 pixels packed)
//
// Parameters:
//   DATA_WIDTH    - Bit width of each pixel
//   DIN_WIDTH      - Width of each input pixel (default = DATA_WIDTH)
//   DIN_COUNT      - Number of input pixels per cycle (default = 1)
//   DOUT_WIDTH     - Width of each output pixel (default = DATA_WIDTH)
//   DOUT_COUNT     - Number of output pixels packed together (default = 2)
//-----------------------------------------------------------------------------

module common_s2p #(
    parameter DATA_WIDTH  = 10,
    parameter DIN_WIDTH   = DATA_WIDTH,   // width of each input pixel
    parameter DIN_COUNT   = 1,             // number of input pixels per cycle
    parameter DOUT_WIDTH  = DATA_WIDTH,   // width of each output pixel
    parameter DOUT_COUNT   = 2             // number of output pixels packed
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          enable,
    input  wire                          sof,        // Start of frame

    // Serial Input (DIN_COUNT pixels per cycle, each DIN_WIDTH bits)
    input  wire [DIN_WIDTH*DIN_COUNT-1:0] din,
    input  wire                          din_valid,
    output wire                          din_ready,

    // Parallel Output (DOUT_COUNT pixels packed, each DOUT_WIDTH bits)
    output wire [DOUT_WIDTH*DOUT_COUNT-1:0] dout,
    output wire                          dout_valid,
    input  wire                          dout_ready,

    // Even/odd cycle indicator (for 1-to-2 conversion)
    output wire                          even_cycle
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam ST_IDLE   = 1'b0;
    localparam ST_HAVE0  = 1'b1;  // Have first pixel, waiting for second

    //=========================================================================
    // Internal Signals
    //=========================================================================
    reg state;
    reg next_state;
    reg [DIN_WIDTH-1:0] pixel_buf;        // Buffered first pixel
    reg even_cycle_reg;                  // Even cycle counter
    reg [DOUT_WIDTH*DOUT_COUNT-1:0] dout_reg;
    reg dout_valid_reg;

    //=========================================================================
    // State Transition
    //=========================================================================
    always @(*) begin
        next_state = state;
        case (state)
            ST_IDLE: begin
                if (din_valid && enable)
                    next_state = ST_HAVE0;
            end

            ST_HAVE0: begin
                if (din_valid && enable && dout_ready)
                    next_state = ST_IDLE;
                else if (din_valid && enable && !dout_ready)
                    next_state = ST_HAVE0;
            end

            default: next_state = ST_IDLE;
        endcase
    end

    //=========================================================================
    // State Register
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
        end else if (sof) begin
            state <= ST_IDLE;
        end else if (enable) begin
            state <= next_state;
        end
    end

    //=========================================================================
    // Even Cycle Counter
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            even_cycle_reg <= 1'b1;
        end else if (sof) begin
            even_cycle_reg <= 1'b1;
        end else if (enable && din_valid) begin
            even_cycle_reg <= ~even_cycle_reg;
        end
    end

    assign even_cycle = even_cycle_reg;

    //=========================================================================
    // Pixel Buffer
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pixel_buf <= {DIN_WIDTH{1'b0}};
        end else if (sof) begin
            pixel_buf <= {DIN_WIDTH{1'b0}};
        end else if (enable) begin
            case (state)
                ST_IDLE: begin
                    if (din_valid)
                        pixel_buf <= din[DIN_WIDTH-1:0];
                end
                ST_HAVE0: begin
                    // Keep pixel_buf until we output
                end
                default: pixel_buf <= pixel_buf;
            endcase
        end
    end

    //=========================================================================
    // Output Data and Valid
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout_reg <= {DOUT_WIDTH*DOUT_COUNT{1'b0}};
            dout_valid_reg <= 1'b0;
        end else if (sof) begin
            dout_reg <= {DOUT_WIDTH*DOUT_COUNT{1'b0}};
            dout_valid_reg <= 1'b0;
        end else if (enable) begin
            case (state)
                ST_IDLE: begin
                    dout_valid_reg <= 1'b0;
                end

                ST_HAVE0: begin
                    if (din_valid && enable && !dout_ready) begin
                        dout_valid_reg <= dout_valid_reg;
                    end else if (din_valid && enable && dout_ready) begin
                        // Output {current, buffered}
                        dout_reg <= {din[DIN_WIDTH-1:0], pixel_buf};
                        dout_valid_reg <= 1'b1;
                    end
                end

                default: begin
                    dout_valid_reg <= 1'b0;
                end
            endcase
        end
    end

    //=========================================================================
    // Ready Signal
    //=========================================================================
    assign din_ready = (state == ST_IDLE);

    //=========================================================================
    // Output Assignment
    //=========================================================================
    assign dout       = dout_reg;
    assign dout_valid = dout_valid_reg;

endmodule
