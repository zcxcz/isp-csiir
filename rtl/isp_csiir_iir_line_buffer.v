//-----------------------------------------------------------------------------
// Module: isp_csiir_iir_line_buffer
// Description: 6-line buffer with IIR feedback support for ISP-CSIIR
//              - lb_0 ~ lb_4: Store history data (can be written back by IIR)
//              - lb_5: New input data write buffer
//              - Exploits pipeline_delay << line_period to avoid conflicts
//              - Pure Verilog-2001 compatible
//              - Fully parameterized for resolution and data width
//
// Architecture:
//   Input → lb_5 (new) → shift → lb_4 → lb_3 → lb_2 → lb_1 → lb_0
//                                              ↓
//                                        5x5 Window Generation
//                                              ↓
//                                         Pipeline (~17 cycles)
//                                              ↓
//                                         IIR Feedback → Write back to lb_0~lb_4
//                                              (no conflict due to timing)
//-----------------------------------------------------------------------------

module isp_csiir_iir_line_buffer #(
    parameter IMG_WIDTH       = 5472,
    parameter DATA_WIDTH      = 10,
    parameter LINE_ADDR_WIDTH = 14,
    parameter ROW_CNT_WIDTH   = 13
)(
    input  wire                        clk,
    input  wire                        rst_n,

    // Control
    input  wire                        enable,
    input  wire                        sof,           // Start of frame
    input  wire                        eol,           // End of line

    // Original input
    input  wire [DATA_WIDTH-1:0]       din,
    input  wire                        din_valid,

    // IIR feedback (from pipeline output)
    input  wire [DATA_WIDTH-1:0]       iir_feedback_data,
    input  wire                        iir_feedback_valid,
    input  wire [LINE_ADDR_WIDTH-1:0]  iir_feedback_col,

    // 5x5 window output (from lb_0 ~ lb_4)
    output wire [DATA_WIDTH-1:0]       window_0_0, window_0_1, window_0_2, window_0_3, window_0_4,
    output wire [DATA_WIDTH-1:0]       window_1_0, window_1_1, window_1_2, window_1_3, window_1_4,
    output wire [DATA_WIDTH-1:0]       window_2_0, window_2_1, window_2_2, window_2_3, window_2_4,
    output wire [DATA_WIDTH-1:0]       window_3_0, window_3_1, window_3_2, window_3_3, window_3_4,
    output wire [DATA_WIDTH-1:0]       window_4_0, window_4_1, window_4_2, window_4_3, window_4_4,
    output reg                         window_valid,

    // Boundary mode: 00=zero, 01=replicate, 10=mirror
    input  wire [1:0]                  boundary_mode
);

    `include "isp_csiir_defines.vh"

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam NUM_HISTORY_LINES = 5;   // lb_0 ~ lb_4 for history and IIR writeback
    localparam NUM_TOTAL_LINES   = 6;   // Total including lb_5 for new input
    localparam WINDOW_CENTER     = 2;   // Center of 5x5 window

    //=========================================================================
    // 6 Line Buffers
    //=========================================================================
    // lb_0 ~ lb_4: History lines (read for window, write for IIR feedback)
    reg [DATA_WIDTH-1:0] lb_0 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] lb_1 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] lb_2 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] lb_3 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] lb_4 [0:IMG_WIDTH-1];

    // lb_5: New input line (write only)
    reg [DATA_WIDTH-1:0] lb_5 [0:IMG_WIDTH-1];

    //=========================================================================
    // Pointers and Counters
    //=========================================================================
    reg [LINE_ADDR_WIDTH-1:0] wr_ptr;        // Write pointer for current column
    reg [LINE_ADDR_WIDTH-1:0] col_cnt;       // Column counter
    reg [ROW_CNT_WIDTH-1:0]   row_cnt;       // Row counter

    // Line valid flags
    reg [NUM_HISTORY_LINES-1:0] line_valid;  // Which history lines have valid data

    //=========================================================================
    // Shift Registers for 5x5 Window (Horizontal taps)
    //=========================================================================
    reg [DATA_WIDTH-1:0] row0_tap0, row0_tap1, row0_tap2, row0_tap3, row0_tap4;
    reg [DATA_WIDTH-1:0] row1_tap0, row1_tap1, row1_tap2, row1_tap3, row1_tap4;
    reg [DATA_WIDTH-1:0] row2_tap0, row2_tap1, row2_tap2, row2_tap3, row2_tap4;
    reg [DATA_WIDTH-1:0] row3_tap0, row3_tap1, row3_tap2, row3_tap3, row3_tap4;
    reg [DATA_WIDTH-1:0] row4_tap0, row4_tap1, row4_tap2, row4_tap3, row4_tap4;

    //=========================================================================
    // Column Pipeline (Vertical shift)
    //=========================================================================
    reg [DATA_WIDTH-1:0] col_pipe_0, col_pipe_1, col_pipe_2, col_pipe_3, col_pipe_4;

    //=========================================================================
    // Input Write Logic
    //=========================================================================
    // Write new input to lb_5, and propagate history lines
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr     <= {LINE_ADDR_WIDTH{1'b0}};
            col_cnt    <= {LINE_ADDR_WIDTH{1'b0}};
            row_cnt    <= {ROW_CNT_WIDTH{1'b0}};
            line_valid <= 5'b00000;
        end else if (enable) begin
            if (din_valid) begin
                // Write new input to lb_5
                lb_5[wr_ptr] <= din;

                // Read from history lines and propagate (for next cycle)
                // This creates the vertical shift for 5x5 window
                // lb_4 <- lb_3 <- lb_2 <- lb_1 <- lb_0 <- (will be updated at EOL)

                // Update pointers
                if (eol || col_cnt == IMG_WIDTH - 1) begin
                    // End of line: shift line buffers
                    wr_ptr  <= {LINE_ADDR_WIDTH{1'b0}};
                    col_cnt <= {LINE_ADDR_WIDTH{1'b0}};

                    // Shift line valid flags (oldest out, newest in)
                    line_valid <= {line_valid[3:0], 1'b1};

                    // Increment row counter
                    if (row_cnt < {ROW_CNT_WIDTH{1'b1}})
                        row_cnt <= row_cnt + {{ROW_CNT_WIDTH-1{1'b0}}, 1'b1};
                end else begin
                    wr_ptr  <= wr_ptr + {{LINE_ADDR_WIDTH-1{1'b0}}, 1'b1};
                    col_cnt <= col_cnt + {{LINE_ADDR_WIDTH-1{1'b0}}, 1'b1};
                end
            end

            // Reset on SOF
            if (sof) begin
                wr_ptr     <= {LINE_ADDR_WIDTH{1'b0}};
                col_cnt    <= {LINE_ADDR_WIDTH{1'b0}};
                row_cnt    <= {ROW_CNT_WIDTH{1'b0}};
                line_valid <= 5'b00000;
            end
        end
    end

    //=========================================================================
    // Line Buffer Propagation (at end of each line)
    //=========================================================================
    // When a line is complete, shift the line buffers
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Initialize all line buffers to zero
            for (k = 0; k < IMG_WIDTH; k = k + 1) begin
                lb_0[k] <= {DATA_WIDTH{1'b0}};
                lb_1[k] <= {DATA_WIDTH{1'b0}};
                lb_2[k] <= {DATA_WIDTH{1'b0}};
                lb_3[k] <= {DATA_WIDTH{1'b0}};
                lb_4[k] <= {DATA_WIDTH{1'b0}};
                lb_5[k] <= {DATA_WIDTH{1'b0}};
            end
        end else if (enable && eol && din_valid) begin
            // Shift lines: lb_0 <- lb_1 <- lb_2 <- lb_3 <- lb_4 <- lb_5
            // This is done per-pixel during the line, but we mark completion here
            // Actually, we do line-by-line copy at EOL for efficiency
            // Note: In real hardware, this would be done with pointer swapping
        end
    end

    //=========================================================================
    // Per-Pixel Line Buffer Read and Column Pipeline
    //=========================================================================
    // Read from line buffers and create vertical pipeline
    wire [DATA_WIDTH-1:0] lb_0_rd = lb_0[wr_ptr];
    wire [DATA_WIDTH-1:0] lb_1_rd = lb_1[wr_ptr];
    wire [DATA_WIDTH-1:0] lb_2_rd = lb_2[wr_ptr];
    wire [DATA_WIDTH-1:0] lb_3_rd = lb_3[wr_ptr];
    wire [DATA_WIDTH-1:0] lb_4_rd = lb_4[wr_ptr];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_pipe_0   <= {DATA_WIDTH{1'b0}};
            col_pipe_1   <= {DATA_WIDTH{1'b0}};
            col_pipe_2   <= {DATA_WIDTH{1'b0}};
            col_pipe_3   <= {DATA_WIDTH{1'b0}};
            col_pipe_4   <= {DATA_WIDTH{1'b0}};
            window_valid <= 1'b0;
        end else if (enable && din_valid) begin
            // Vertical shift: newest at bottom (col_pipe_4), oldest at top (col_pipe_0)
            // After enough rows, col_pipe_0 = oldest row, col_pipe_4 = newest row
            col_pipe_0 <= col_pipe_1;
            col_pipe_1 <= col_pipe_2;
            col_pipe_2 <= col_pipe_3;
            col_pipe_3 <= col_pipe_4;

            // Load from line buffers (with history shift)
            // At each column, we read the history and form the vertical column
            if (line_valid[3]) col_pipe_4 <= lb_4_rd;
            else if (line_valid[2]) col_pipe_4 <= lb_3_rd;
            else if (line_valid[1]) col_pipe_4 <= lb_2_rd;
            else if (line_valid[0]) col_pipe_4 <= lb_1_rd;
            else                    col_pipe_4 <= din;  // First few rows

            // Window valid after 2 rows and 2 columns filled
            window_valid <= (row_cnt >= {{ROW_CNT_WIDTH-2{1'b0}}, 2'd2}) &&
                            (col_cnt >= {{LINE_ADDR_WIDTH-2{1'b0}}, 2'd2});
        end else begin
            window_valid <= 1'b0;
        end
    end

    //=========================================================================
    // Line Buffer Update at End of Line
    //=========================================================================
    // Shift entire lines: lb_0 <- lb_1 <- lb_2 <- lb_3 <- lb_4 <- lb_5
    // This is done one column at a time during horizontal blanking
    // or using pointer swapping in a more optimized implementation

    reg [LINE_ADDR_WIDTH-1:0] shift_col_ptr;
    reg                       line_shift_en;
    reg [3:0]                 shift_state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_col_ptr <= 0;
            line_shift_en <= 1'b0;
            shift_state   <= 0;
        end else if (enable) begin
            // Start line shift after EOL
            if (eol && din_valid) begin
                line_shift_en <= 1'b1;
                shift_col_ptr <= 0;
                shift_state   <= 0;
            end else if (line_shift_en) begin
                // Shift one column per cycle
                if (shift_col_ptr < IMG_WIDTH - 1) begin
                    lb_0[shift_col_ptr] <= lb_1[shift_col_ptr];
                    lb_1[shift_col_ptr] <= lb_2[shift_col_ptr];
                    lb_2[shift_col_ptr] <= lb_3[shift_col_ptr];
                    lb_3[shift_col_ptr] <= lb_4[shift_col_ptr];
                    lb_4[shift_col_ptr] <= lb_5[shift_col_ptr];
                    shift_col_ptr <= shift_col_ptr + 1;
                end else begin
                    // Last column
                    lb_0[shift_col_ptr] <= lb_1[shift_col_ptr];
                    lb_1[shift_col_ptr] <= lb_2[shift_col_ptr];
                    lb_2[shift_col_ptr] <= lb_3[shift_col_ptr];
                    lb_3[shift_col_ptr] <= lb_4[shift_col_ptr];
                    lb_4[shift_col_ptr] <= lb_5[shift_col_ptr];
                    line_shift_en <= 1'b0;
                end
            end
        end
    end

    //=========================================================================
    // IIR Feedback Write Logic
    //=========================================================================
    // Write back IIR results to lb_0 ~ lb_4
    // This happens during pipeline processing, after the input has moved on
    // Timing: output is ~17 cycles delayed, new input at same column is much later
    //         due to line width >> pipeline delay
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset handled above
        end else if (enable && iir_feedback_valid) begin
            // Write IIR feedback to all 5 history lines at the feedback column
            // The column iir_feedback_col is from ~17 cycles ago
            // New input at that column has already been written to lb_5 and shifted
            // But since W >> D, the IIR write happens before new data reaches lb_0~lb_4

            // Write to history lines (lb_0 ~ lb_4)
            lb_0[iir_feedback_col] <= iir_feedback_data;
            lb_1[iir_feedback_col] <= iir_feedback_data;
            lb_2[iir_feedback_col] <= iir_feedback_data;
            lb_3[iir_feedback_col] <= iir_feedback_data;
            lb_4[iir_feedback_col] <= iir_feedback_data;
        end
    end

    //=========================================================================
    // Horizontal Shift Registers for Each Row
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Row 0
            row0_tap0 <= {DATA_WIDTH{1'b0}};
            row0_tap1 <= {DATA_WIDTH{1'b0}};
            row0_tap2 <= {DATA_WIDTH{1'b0}};
            row0_tap3 <= {DATA_WIDTH{1'b0}};
            row0_tap4 <= {DATA_WIDTH{1'b0}};
            // Row 1
            row1_tap0 <= {DATA_WIDTH{1'b0}};
            row1_tap1 <= {DATA_WIDTH{1'b0}};
            row1_tap2 <= {DATA_WIDTH{1'b0}};
            row1_tap3 <= {DATA_WIDTH{1'b0}};
            row1_tap4 <= {DATA_WIDTH{1'b0}};
            // Row 2
            row2_tap0 <= {DATA_WIDTH{1'b0}};
            row2_tap1 <= {DATA_WIDTH{1'b0}};
            row2_tap2 <= {DATA_WIDTH{1'b0}};
            row2_tap3 <= {DATA_WIDTH{1'b0}};
            row2_tap4 <= {DATA_WIDTH{1'b0}};
            // Row 3
            row3_tap0 <= {DATA_WIDTH{1'b0}};
            row3_tap1 <= {DATA_WIDTH{1'b0}};
            row3_tap2 <= {DATA_WIDTH{1'b0}};
            row3_tap3 <= {DATA_WIDTH{1'b0}};
            row3_tap4 <= {DATA_WIDTH{1'b0}};
            // Row 4
            row4_tap0 <= {DATA_WIDTH{1'b0}};
            row4_tap1 <= {DATA_WIDTH{1'b0}};
            row4_tap2 <= {DATA_WIDTH{1'b0}};
            row4_tap3 <= {DATA_WIDTH{1'b0}};
            row4_tap4 <= {DATA_WIDTH{1'b0}};
        end else if (enable && din_valid) begin
            // Row 0: shift left, load from col_pipe_0
            row0_tap0 <= row0_tap1;
            row0_tap1 <= row0_tap2;
            row0_tap2 <= row0_tap3;
            row0_tap3 <= row0_tap4;
            row0_tap4 <= col_pipe_0;

            // Row 1: shift left, load from col_pipe_1
            row1_tap0 <= row1_tap1;
            row1_tap1 <= row1_tap2;
            row1_tap2 <= row1_tap3;
            row1_tap3 <= row1_tap4;
            row1_tap4 <= col_pipe_1;

            // Row 2: shift left, load from col_pipe_2
            row2_tap0 <= row2_tap1;
            row2_tap1 <= row2_tap2;
            row2_tap2 <= row2_tap3;
            row2_tap3 <= row2_tap4;
            row2_tap4 <= col_pipe_2;

            // Row 3: shift left, load from col_pipe_3
            row3_tap0 <= row3_tap1;
            row3_tap1 <= row3_tap2;
            row3_tap2 <= row3_tap3;
            row3_tap3 <= row3_tap4;
            row3_tap4 <= col_pipe_3;

            // Row 4: shift left, load from col_pipe_4
            row4_tap0 <= row4_tap1;
            row4_tap1 <= row4_tap2;
            row4_tap2 <= row4_tap3;
            row4_tap3 <= row4_tap4;
            row4_tap4 <= col_pipe_4;
        end
    end

    //=========================================================================
    // Output Assignments (window[r][c] = row_r_tap_c)
    //=========================================================================
    // Row 0 (oldest)
    assign window_0_0 = row0_tap0;
    assign window_0_1 = row0_tap1;
    assign window_0_2 = row0_tap2;
    assign window_0_3 = row0_tap3;
    assign window_0_4 = row0_tap4;
    // Row 1
    assign window_1_0 = row1_tap0;
    assign window_1_1 = row1_tap1;
    assign window_1_2 = row1_tap2;
    assign window_1_3 = row1_tap3;
    assign window_1_4 = row1_tap4;
    // Row 2 (center)
    assign window_2_0 = row2_tap0;
    assign window_2_1 = row2_tap1;
    assign window_2_2 = row2_tap2;
    assign window_2_3 = row2_tap3;
    assign window_2_4 = row2_tap4;
    // Row 3
    assign window_3_0 = row3_tap0;
    assign window_3_1 = row3_tap1;
    assign window_3_2 = row3_tap2;
    assign window_3_3 = row3_tap3;
    assign window_3_4 = row3_tap4;
    // Row 4 (newest)
    assign window_4_0 = row4_tap0;
    assign window_4_1 = row4_tap1;
    assign window_4_2 = row4_tap2;
    assign window_4_3 = row4_tap3;
    assign window_4_4 = row4_tap4;

endmodule