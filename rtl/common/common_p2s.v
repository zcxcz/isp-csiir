//-----------------------------------------------------------------------------
// Module: common_p2s
// Purpose: 2P to 1P deserializer (parallel-to-serial)
//          Converts two-pixel packed input to single-pixel stream
// Author: rtl-impl
// Date: 2026-04-15
//-----------------------------------------------------------------------------
// Description:
//   Takes 2 pixels packed per cycle and outputs 1 pixel per cycle.
//   - Takes 2 cycles to output one 2P word
//   - Outputs first pixel (even) then second pixel (odd)
//   - even_cycle signal indicates which pixel is being output
//
// Parameters:
//   DATA_WIDTH - Bit width of each pixel
//-----------------------------------------------------------------------------

module common_p2s #(
    parameter DATA_WIDTH = 10
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  enable,
    input  wire                  sof,        // Start of frame - reset state

    // 2P Input (two pixels packed per cycle)
    input  wire [DATA_WIDTH*2-1:0] din,
    input  wire                  din_valid,
    output wire                  din_ready,

    // 1P Output (single pixel per cycle)
    output wire [DATA_WIDTH-1:0] dout,
    output wire                  dout_valid,
    input  wire                  dout_ready,

    // Even/odd cycle indicator for output
    output wire                  even_cycle_out  // 1=even pixel, 0=odd pixel
);

    //=========================================================================
    // State
    //=========================================================================
    localparam ST_IDLE  = 1'b0;
    localparam ST_SEND0 = 1'b1;  // Sending first pixel (even)
    localparam ST_SEND1 = 2'b10; // Sending second pixel (odd)

    reg [1:0] state;
    reg [1:0] next_state;

    // Buffered 2P word
    reg [DATA_WIDTH*2-1:0] din_buf;

    // Even cycle for output (toggles each output)
    reg even_cycle_reg;

    // Output control
    reg dout_valid_reg;

    //=========================================================================
    // State Transition
    //=========================================================================
    always @(*) begin
        next_state = state;
        case (state)
            ST_IDLE: begin
                if (din_valid && enable)
                    next_state = ST_SEND0;
            end

            ST_SEND0: begin
                if (dout_ready)
                    next_state = ST_SEND1;
            end

            ST_SEND1: begin
                if (dout_ready) begin
                    if (din_valid && enable)
                        next_state = ST_SEND0;
                    else
                        next_state = ST_IDLE;
                end
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
    // Even Cycle Counter (for output)
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            even_cycle_reg <= 1'b1;
        end else if (sof) begin
            even_cycle_reg <= 1'b1;
        end else if (enable && dout_ready && dout_valid_reg) begin
            even_cycle_reg <= ~even_cycle_reg;
        end
    end

    assign even_cycle_out = even_cycle_reg;

    //=========================================================================
    // Input Buffer
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            din_buf <= {DATA_WIDTH*2{1'b0}};
        end else if (sof) begin
            din_buf <= {DATA_WIDTH*2{1'b0}};
        end else if (enable) begin
            case (state)
                ST_IDLE: begin
                    if (din_valid)
                        din_buf <= din;
                end

                ST_SEND0: begin
                    if (dout_ready) begin
                        // Keep buffer for next output
                        din_buf <= din_buf;
                    end
                end

                ST_SEND1: begin
                    if (dout_ready && din_valid)
                        din_buf <= din;
                end

                default: din_buf <= din_buf;
            endcase
        end
    end

    //=========================================================================
    // Output Data and Valid
    //=========================================================================
    // dout: lower bits = even pixel, upper bits = odd pixel
    wire [DATA_WIDTH-1:0] pixel_even = din_buf[0 +: DATA_WIDTH];
    wire [DATA_WIDTH-1:0] pixel_odd  = din_buf[DATA_WIDTH +: DATA_WIDTH];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout_valid_reg <= 1'b0;
        end else if (sof) begin
            dout_valid_reg <= 1'b0;
        end else if (enable) begin
            case (state)
                ST_IDLE: begin
                    dout_valid_reg <= 1'b0;
                end

                ST_SEND0: begin
                    if (dout_ready)
                        dout_valid_reg <= 1'b1;
                    else
                        dout_valid_reg <= dout_valid_reg;
                end

                ST_SEND1: begin
                    if (dout_ready)
                        dout_valid_reg <= 1'b0;
                    else
                        dout_valid_reg <= dout_valid_reg;
                end

                default: dout_valid_reg <= 1'b0;
            endcase
        end
    end

    //=========================================================================
    // Output Assignment
    //=========================================================================
    assign dout = even_cycle_reg ? pixel_even : pixel_odd;

    //=========================================================================
    // Ready Signal
    //=========================================================================
    // ready when we can accept the next 2P word:
    // - IDLE: ready
    // - SEND0: NOT ready (mid-output)
    // - SEND1: ready after sending second pixel if no new input
    assign din_ready = (state == ST_IDLE) ||
                       (state == ST_SEND1 && dout_ready && !din_valid);

endmodule
