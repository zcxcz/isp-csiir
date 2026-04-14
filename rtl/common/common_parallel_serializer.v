//-----------------------------------------------------------------------------
// Module: common_parallel_serializer
// Purpose: 1P to 2P (parallel) serializer with flow control
// Author: rtl-impl
// Date: 2026-04-14
//-----------------------------------------------------------------------------
// Description:
//   Converts single-pixel input (1P) to two-pixel packed output (2P).
//   - Input: 1 pixel per cycle (din, din_valid, din_ready)
//   - Output: 2 pixels packed per cycle (dout, dout_valid, dout_ready)
//   - Output valid fires every OTHER cycle when input is continuous
//
// Timing:
//   Cycle N:   din_valid=1, din=pixel0 -> buffer pixel0, ready=0
//   Cycle N+1: din_valid=1, din=pixel1 -> output {pixel1, pixel0}, ready=1
//   Cycle N+2: din_valid=1, din=pixel2 -> buffer pixel2, ready=0
//   Cycle N+3: din_valid=1, din=pixel3 -> output {pixel3, pixel2}, ready=1
//
//   When din_valid=0, no action (no partial output).
//   SOF resets the even/odd parity counter.
//
// Parameters:
//   DATA_WIDTH - Bit width of each pixel
//-----------------------------------------------------------------------------

module common_parallel_serializer #(
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

    // Even/odd column indicator (for external use)
    output wire                  even_col     // 1=even col (lower half valid), 0=odd col (upper half valid)
);

    //=========================================================================
    // State Machine
    //=========================================================================
    localparam ST_IDLE      = 2'b00;
    localparam ST_HAVE_EVEN = 2'b01;  // Have pixel0, waiting for pixel1
    localparam ST_HAVE_ODD  = 2'b10;  // Have pixel1, output ready (sending 2P)

    reg [1:0] state;
    reg [1:0] next_state;

    // Buffered pixel (first pixel of the 2P pair)
    reg [DATA_WIDTH-1:0] pixel_buf;

    // Even/odd parity - toggles each time we receive a pixel
    reg even_parity;

    // Output data
    reg [DATA_WIDTH*2-1:0] dout_reg;
    reg dout_valid_reg;

    //=========================================================================
    // State Transition Logic
    //=========================================================================
    always @(*) begin
        next_state = state;
        case (state)
            ST_IDLE: begin
                if (din_valid && enable)
                    next_state = ST_HAVE_EVEN;
            end

            ST_HAVE_EVEN: begin
                if (din_valid && enable && dout_ready)
                    next_state = ST_HAVE_ODD;
                else if (din_valid && enable && !dout_ready)
                    next_state = ST_HAVE_EVEN;  // Stay, wait for dout_ready
            end

            ST_HAVE_ODD: begin
                if (dout_valid && dout_ready) begin
                    if (din_valid && enable)
                        next_state = ST_HAVE_EVEN;
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
    // Parity Counter
    //=========================================================================
    // even_parity indicates which column we're expecting next:
    // 1 = even column (pixel goes to lower half of 2P word)
    // 0 = odd column (pixel goes to upper half of 2P word)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            even_parity <= 1'b1;
        end else if (sof) begin
            even_parity <= 1'b1;
        end else if (enable && din_valid) begin
            even_parity <= ~even_parity;
        end
    end

    //=========================================================================
    // Pixel Buffer Management
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

                ST_HAVE_EVEN: begin
                    // Stay: keep pixel_buf, don't overwrite until output
                end

                ST_HAVE_ODD: begin
                    if (dout_valid && dout_ready && din_valid)
                        pixel_buf <= din;
                    else if (dout_valid && dout_ready && !din_valid)
                        pixel_buf <= {DATA_WIDTH{1'b0}};
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
                    dout_valid_reg <= 1'b0;
                end

                ST_HAVE_EVEN: begin
                    // Waiting for second pixel, no output yet
                    dout_valid_reg <= 1'b0;
                end

                ST_HAVE_ODD: begin
                    // Output the 2P word: {pixel1, pixel0}
                    if (!dout_ready) begin
                        // Hold output when downstream not ready
                        dout_valid_reg <= dout_valid_reg;
                    end else begin
                        dout_reg <= {din, pixel_buf};  // {odd, even}
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
    // - HAVE_EVEN: NOT ready (waiting for second pixel)
    // - HAVE_ODD: ready after output completes (dout_valid && dout_ready)
    assign din_ready = (state == ST_IDLE) ||
                       (state == ST_HAVE_ODD && dout_valid && dout_ready && !din_valid);

    //=========================================================================
    // Output Assignment
    //=========================================================================
    assign dout       = dout_reg;
    assign dout_valid = dout_valid_reg;
    assign even_col   = even_parity;

endmodule
