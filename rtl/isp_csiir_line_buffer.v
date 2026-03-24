//-----------------------------------------------------------------------------
// Module: isp_csiir_line_buffer
// Purpose: 5-row line buffer with 5x5 window generation
// Author: rtl-impl
// Date: 2026-03-24
// Version: v3.0 - Added valid/ready handshake signals for back-pressure support
//-----------------------------------------------------------------------------
// Description:
//   Implements 5-row circular line buffer for 5x5 sliding window generation.
//   Supports:
//   - 5-row pixel storage for 5x5 window
//   - Line buffer feedback writeback (u10 format from Stage 4)
//   - Configurable image width
//   - Valid/Ready handshake protocol with back-pressure support
//
// Data Format:
//   - Storage: u10 (10-bit unsigned)
//   - Writeback input: u10 from Stage 4 output
//
// Handshake Protocol:
//   - din_ready: Asserted when module can accept input data
//   - window_valid: Asserted when window output is valid
//   - window_ready: Input from downstream to indicate readiness
//   - When window_ready=0, window output is paused (back-pressure)
//-----------------------------------------------------------------------------

module isp_csiir_line_buffer #(
    parameter IMG_WIDTH       = 5472,
    parameter DATA_WIDTH      = 10,
    parameter LINE_ADDR_WIDTH = 14
)(
    // Clock and Reset
    input  wire                        clk,
    input  wire                        rst_n,

    // Control
    input  wire                        enable,

    // Image dimension configuration (runtime)
    input  wire [LINE_ADDR_WIDTH-1:0]  img_width,
    input  wire [12:0]                 img_height,

    // Input pixel stream with handshake
    input  wire [DATA_WIDTH-1:0]       din,
    input  wire                        din_valid,
    output wire                        din_ready,
    input  wire                        sof,          // Start of frame
    input  wire                        eol,          // End of line

    // Line buffer feedback writeback (u10 format from Stage 4)
    input  wire                        lb_wb_en,
    input  wire [DATA_WIDTH-1:0]       lb_wb_data,
    input  wire [LINE_ADDR_WIDTH-1:0]  lb_wb_addr,
    input  wire [2:0]                  lb_wb_row_offset,

    // 5x5 Window output with handshake
    output wire [DATA_WIDTH-1:0]       window_0_0, window_0_1, window_0_2, window_0_3, window_0_4,
    output wire [DATA_WIDTH-1:0]       window_1_0, window_1_1, window_1_2, window_1_3, window_1_4,
    output wire [DATA_WIDTH-1:0]       window_2_0, window_2_1, window_2_2, window_2_3, window_2_4,
    output wire [DATA_WIDTH-1:0]       window_3_0, window_3_1, window_3_2, window_3_3, window_3_4,
    output wire [DATA_WIDTH-1:0]       window_4_0, window_4_1, window_4_2, window_4_3, window_4_4,
    output reg                         window_valid,
    input  wire                        window_ready,
    output reg  [LINE_ADDR_WIDTH-1:0]   center_x,
    output wire [12:0]                 center_y
);

    //=========================================================================
    // Local Parameters
    //=========================================================================
    localparam LINE_COUNT = 5;

    //=========================================================================
    // Internal Signals
    //=========================================================================
    // 5-row circular line memory
    reg [DATA_WIDTH-1:0] line_mem_0 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] line_mem_1 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] line_mem_2 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] line_mem_3 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] line_mem_4 [0:IMG_WIDTH-1];

    // Initialize line memories to 0 (for simulation)
    integer init_i;
    initial begin
        for (init_i = 0; init_i < IMG_WIDTH; init_i = init_i + 1) begin
            line_mem_0[init_i] = {DATA_WIDTH{1'b0}};
            line_mem_1[init_i] = {DATA_WIDTH{1'b0}};
            line_mem_2[init_i] = {DATA_WIDTH{1'b0}};
            line_mem_3[init_i] = {DATA_WIDTH{1'b0}};
            line_mem_4[init_i] = {DATA_WIDTH{1'b0}};
        end
    end

    // Row pointers (circular)
    reg [2:0] wr_row_ptr;   // Write row pointer (0-4)
    reg [2:0] rd_row_ptr;   // Read row pointer (0-4)

    // Column counters
    reg [LINE_ADDR_WIDTH-1:0] wr_col_ptr;
    reg [LINE_ADDR_WIDTH-1:0] rd_col_ptr;

    // Row counter
    reg [12:0] row_cnt;

    // Delay for valid generation (need 2 rows + 2 cols before window is valid)
    reg [3:0] valid_delay;
    reg       frame_started;

    // Column delay for window center
    reg [LINE_ADDR_WIDTH-1:0] center_x_delay;

    //=========================================================================
    // Input Handshake - din_ready
    //=========================================================================
    // din_ready indicates when the module can accept new input data
    // Ready when enabled and frame has started (can accept data during processing)
    assign din_ready = enable && frame_started;

    //=========================================================================
    // Write Logic
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_row_ptr   <= 3'd0;
            wr_col_ptr   <= {LINE_ADDR_WIDTH{1'b0}};
            row_cnt      <= 13'd0;
        end else if (sof) begin
            wr_row_ptr   <= 3'd0;
            wr_col_ptr   <= {LINE_ADDR_WIDTH{1'b0}};
            row_cnt      <= 13'd0;
        end else if (enable) begin
            // Handle EOL to update row pointer and reset column
            if (eol) begin
                // Note: wr_col_ptr already incremented when last pixel was written
                // Reset column pointer for next row
                wr_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
                wr_row_ptr <= (wr_row_ptr == 3'd4) ? 3'd0 : wr_row_ptr + 1'b1;
                row_cnt    <= row_cnt + 1'b1;
            end
            // Write data when din_valid (can happen same cycle as eol for last pixel)
            if (din_valid && din_ready) begin
                case (wr_row_ptr)
                    3'd0: line_mem_0[wr_col_ptr] <= din;
                    3'd1: line_mem_1[wr_col_ptr] <= din;
                    3'd2: line_mem_2[wr_col_ptr] <= din;
                    3'd3: line_mem_3[wr_col_ptr] <= din;
                    3'd4: line_mem_4[wr_col_ptr] <= din;
                endcase
                // Update column pointer
                wr_col_ptr <= wr_col_ptr + 1'b1;
            end
        end
    end

    //=========================================================================
    // Line Buffer Feedback Writeback Logic
    //=========================================================================
    wire [2:0] lb_wr_row = (wr_row_ptr + lb_wb_row_offset) % 5;

    // TEMPORARILY DISABLED FOR DEBUGGING - IIR feedback causes corruption
    always @(posedge clk) begin
        if (0 && enable && lb_wb_en) begin  // DISABLED
            case (lb_wr_row)
                3'd0: line_mem_0[lb_wb_addr] <= lb_wb_data;
                3'd1: line_mem_1[lb_wb_addr] <= lb_wb_data;
                3'd2: line_mem_2[lb_wb_addr] <= lb_wb_data;
                3'd3: line_mem_3[lb_wb_addr] <= lb_wb_data;
                3'd4: line_mem_4[lb_wb_addr] <= lb_wb_data;
            endcase
        end
    end

    //=========================================================================
    // Read Logic - Generate 5x5 Window with Duplicate Padding
    //=========================================================================
    // Calculate read row pointers based on current write position
    // For full-size output from pixel 0, read rows follow write rows
    // The center row (win_row_2) should always point to the current write row

    // Read row pointers: map to actual line memories that have data
    // wr_row_ptr points to the row currently being written
    // For a 5x5 window centered at current write position:
    //   win_row_2 = wr_row_ptr (center, current row)
    //   win_row_1 = previous row
    //   win_row_0 = two rows before (duplicate if not available)
    //   win_row_3 = next row (duplicate current if not available)
    //   win_row_4 = two rows after (duplicate current if not available)

    wire [2:0] wr_row_prev  = (wr_row_ptr == 0) ? 3'd4 : wr_row_ptr - 1'b1;
    wire [2:0] wr_row_prev2 = (wr_row_ptr <= 1) ? wr_row_ptr + 3'd3 : wr_row_ptr - 3'd2;
    wire [2:0] wr_row_next  = (wr_row_ptr == 4) ? 3'd0 : wr_row_ptr + 1'b1;
    wire [2:0] wr_row_next2 = (wr_row_ptr >= 3) ? wr_row_ptr - 3'd3 : wr_row_ptr + 3'd2;

    // Physical row selection for each window row
    wire [2:0] win_row_0_phys = (row_cnt < 2) ? wr_row_ptr : wr_row_prev2;  // Duplicate center for first 2 rows
    wire [2:0] win_row_1_phys = (row_cnt < 1) ? wr_row_ptr : wr_row_prev;
    wire [2:0] win_row_2_phys = wr_row_ptr;  // Center row = current write row
    // For win_row_3: duplicate center if row_cnt < 1, else if at bottom, duplicate center, else next row
    wire [2:0] win_row_3_phys = (row_cnt < 1) ? wr_row_ptr :
                                (row_cnt >= img_height - 1) ? wr_row_ptr : wr_row_next;
    // For win_row_4: duplicate center if row_cnt < 2, else if at bottom, duplicate center, else two rows ahead
    wire [2:0] win_row_4_phys = (row_cnt < 2) ? wr_row_ptr :
                                (row_cnt >= img_height - 2) ? wr_row_ptr : wr_row_next2;

    // Column offsets for 5x5 window with duplicate padding (clamp to valid range)
    // When window_valid goes high, rd_col_ptr has advanced by 1
    // So we need to read from (rd_col_ptr - 1), which is the column that was just written
    wire [LINE_ADDR_WIDTH-1:0] center_col = (rd_col_ptr > 0) ? rd_col_ptr - 1'b1 : {LINE_ADDR_WIDTH{1'b0}};
    wire [LINE_ADDR_WIDTH-1:0] col_m2 = (center_col < 2) ? {LINE_ADDR_WIDTH{1'b0}} : center_col - 2;
    wire [LINE_ADDR_WIDTH-1:0] col_m1 = (center_col < 1) ? {LINE_ADDR_WIDTH{1'b0}} : center_col - 1;
    wire [LINE_ADDR_WIDTH-1:0] col_0  = center_col;
    // For col_p1 and col_p2, clamp to img_width - 1
    wire [LINE_ADDR_WIDTH-1:0] col_p1 = (center_col >= img_width - 1) ? img_width - 1 : center_col + 1;
    wire [LINE_ADDR_WIDTH-1:0] col_p2 = (center_col >= img_width - 2) ? img_width - 1 : center_col + 2;

    //=========================================================================
    // Row Boundary Handling - incorporated into win_row_X_phys above
    //=========================================================================

    // Helper function to read from line memory
    function [DATA_WIDTH-1:0] read_line_mem;
        input [2:0] row_idx;
        input [LINE_ADDR_WIDTH-1:0] col_addr;
        begin
            case (row_idx)
                3'd0: read_line_mem = line_mem_0[col_addr];
                3'd1: read_line_mem = line_mem_1[col_addr];
                3'd2: read_line_mem = line_mem_2[col_addr];
                3'd3: read_line_mem = line_mem_3[col_addr];
                default: read_line_mem = line_mem_4[col_addr];
            endcase
        end
    endfunction

    // Generate window outputs
    // Window Row 0 (top row)
    assign window_0_0 = read_line_mem(win_row_0_phys, col_m2);
    assign window_0_1 = read_line_mem(win_row_0_phys, col_m1);
    assign window_0_2 = read_line_mem(win_row_0_phys, col_0);
    assign window_0_3 = read_line_mem(win_row_0_phys, col_p1);
    assign window_0_4 = read_line_mem(win_row_0_phys, col_p2);

    // Window Row 1
    assign window_1_0 = read_line_mem(win_row_1_phys, col_m2);
    assign window_1_1 = read_line_mem(win_row_1_phys, col_m1);
    assign window_1_2 = read_line_mem(win_row_1_phys, col_0);
    assign window_1_3 = read_line_mem(win_row_1_phys, col_p1);
    assign window_1_4 = read_line_mem(win_row_1_phys, col_p2);

    // Window Row 2 (center row)
    assign window_2_0 = read_line_mem(win_row_2_phys, col_m2);
    assign window_2_1 = read_line_mem(win_row_2_phys, col_m1);
    assign window_2_2 = read_line_mem(win_row_2_phys, col_0);
    assign window_2_3 = read_line_mem(win_row_2_phys, col_p1);
    assign window_2_4 = read_line_mem(win_row_2_phys, col_p2);

    // Window Row 3
    assign window_3_0 = read_line_mem(win_row_3_phys, col_m2);
    assign window_3_1 = read_line_mem(win_row_3_phys, col_m1);
    assign window_3_2 = read_line_mem(win_row_3_phys, col_0);
    assign window_3_3 = read_line_mem(win_row_3_phys, col_p1);
    assign window_3_4 = read_line_mem(win_row_3_phys, col_p2);

    // Window Row 4 (bottom row)
    assign window_4_0 = read_line_mem(win_row_4_phys, col_m2);
    assign window_4_1 = read_line_mem(win_row_4_phys, col_m1);
    assign window_4_2 = read_line_mem(win_row_4_phys, col_0);
    assign window_4_3 = read_line_mem(win_row_4_phys, col_p1);
    assign window_4_4 = read_line_mem(win_row_4_phys, col_p2);

    //=========================================================================
    // Read Pointer and Valid Control with Back-pressure Support
    //=========================================================================
    // Timing: Data is written on the clock edge when din_valid=1
    // Window reads are combinational, so they see the OLD value
    // Solution: Delay window_valid by one cycle so it comes after the write
    //
    // Back-pressure handling:
    // - When window_ready=0, hold rd_col_ptr, rd_row_ptr, and center_x
    // - window_valid remains asserted (data is valid, just not consumed)

    reg window_valid_d;  // Delayed valid

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_col_ptr     <= {LINE_ADDR_WIDTH{1'b0}};
            rd_row_ptr     <= 3'd0;
            window_valid   <= 1'b0;
            window_valid_d <= 1'b0;
            frame_started  <= 1'b0;
            center_x       <= {LINE_ADDR_WIDTH{1'b0}};
        end else if (sof) begin
            rd_col_ptr     <= {LINE_ADDR_WIDTH{1'b0}};
            rd_row_ptr     <= 3'd0;
            window_valid   <= 1'b0;
            window_valid_d <= 1'b0;
            frame_started  <= 1'b1;
            center_x       <= {LINE_ADDR_WIDTH{1'b0}};
        end else if (enable && frame_started) begin
            // Back-pressure handling:
            // When window_ready=0, pause read pointer updates
            // but keep window_valid high (data is valid)
            if (!window_ready && window_valid) begin
                // Back-pressure: hold all output state
                // rd_col_ptr, rd_row_ptr, center_x, window_valid remain unchanged
            end
            else begin
                // Normal operation or no valid data to hold
                // Handle EOL separately to reset column pointer
                if (eol) begin
                    rd_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
                    // Advance row pointer after 2 rows filled
                    if (row_cnt >= 2) begin
                        rd_row_ptr <= (rd_row_ptr == 3'd4) ? 3'd0 : rd_row_ptr + 1'b1;
                    end
                    window_valid   <= window_valid_d;
                    window_valid_d <= 1'b0;
                end else if (din_valid && din_ready) begin
                    // Update read column pointer
                    rd_col_ptr <= rd_col_ptr + 1'b1;

                    // Valid generation for full-size output with duplicate padding
                    // Set valid_d for next cycle (after write completes)
                    if (rd_col_ptr < img_width && row_cnt < img_height) begin
                        window_valid   <= window_valid_d;
                        window_valid_d <= 1'b1;
                        center_x       <= rd_col_ptr;  // Center of window (no offset)
                    end else begin
                        window_valid   <= window_valid_d;
                        window_valid_d <= 1'b0;
                    end
                end else begin
                    // No din_valid, propagate the delayed valid
                    window_valid   <= window_valid_d;
                    window_valid_d <= 1'b0;
                end
            end
        end
    end

    // center_y is computed combinationally from row_cnt
    // center_y = row_cnt (no offset for full-size output)
    assign center_y = row_cnt;

endmodule