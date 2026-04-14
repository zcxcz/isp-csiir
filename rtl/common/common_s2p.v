//-----------------------------------------------------------------------------
// Module: common_s2p
// Purpose: 1P to 2P serializer (serial-to-parallel)
//          Converts single-pixel stream to two-pixel packed output
// Author: rtl-impl
// Date: 2026-04-15
//-----------------------------------------------------------------------------
// Description:
//   Takes 1 pixel per cycle and outputs 2 pixels packed every 2 cycles.
//   - Cycle N:   din_valid=1, din=pixelA -> buffer pixelA
//   - Cycle N+1: din_valid=1, din=pixelB -> output {pixelB, pixelA}
//   - Pattern repeats
//
//   When backpressured (dout_ready=0), holds output until ready.
//
// Parameters:
//   DATA_WIDTH - Bit width of each pixel
//-----------------------------------------------------------------------------

module common_s2p #(
    parameter DATA_WIDTH = 10
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  enable,
    input  wire                  sof,        // Start of frame - reset parity

    // 1P Input (single pixel per cycle)
    input  wire [DATA_WIDTH-1:0] din,
    input  wire                  din_valid,
    output wire                  din_ready,

    // 2P Output (two pixels packed per cycle)
    output wire [DATA_WIDTH*2-1:0] dout,
    output wire                  dout_valid,
    input  wire                  dout_ready,

    // Even/odd cycle indicator
    output wire                  even_cycle   // 1=even (first pixel), 0=odd (second pixel)
);

    //=========================================================================
    // State
    //=========================================================================
    localparam ST_IDLE  = 1'b0;
    localparam ST_HAVE0 = 1'b1;  // Have first pixel, waiting for second

    reg state;
    reg next_state;

    // Buffered first pixel
    reg [DATA_WIDTH-1:0] pixel_buf;

    // Even cycle counter (toggles each input)
    reg even_cycle_reg;

    // Output holding register
    reg [DATA_WIDTH*2-1:0] dout_reg;
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
                    next_state = ST_IDLE;  // Output generated, back to idle
                else if (din_valid && enable && !dout_ready)
                    next_state = ST_HAVE0;  // Stay, waiting for dout_ready
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
            pixel_buf <= {DATA_WIDTH{1'b0}};
        end else if (sof) begin
            pixel_buf <= {DATA_WIDTH{1'b0}};
        end else if (enable) begin
            case (state)
                ST_IDLE: begin
                    if (din_valid)
                        pixel_buf <= din;
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
            dout_reg <= {DATA_WIDTH*2{1'b0}};
            dout_valid_reg <= 1'b0;
        end else if (sof) begin
            dout_reg <= {DATA_WIDTH*2{1'b0}};
            dout_valid_reg <= 1'b0;
        end else if (enable) begin
            case (state)
                ST_IDLE: begin
                    // Waiting for first pixel
                    dout_valid_reg <= 1'b0;
                end

                ST_HAVE0: begin
                    if (din_valid && enable && !dout_ready) begin
                        // Hold output
                        dout_valid_reg <= dout_valid_reg;
                    end else if (din_valid && enable && dout_ready) begin
                        // Output {current, buffered}
                        dout_reg <= {din, pixel_buf};
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
    // ready when we can accept the next pixel:
    // - IDLE: ready to receive first pixel
    // - HAVE0: NOT ready (waiting for second pixel or outputting)
    assign din_ready = (state == ST_IDLE);

    //=========================================================================
    // Output Assignment
    //=========================================================================
    assign dout       = dout_reg;
    assign dout_valid = dout_valid_reg;

endmodule
