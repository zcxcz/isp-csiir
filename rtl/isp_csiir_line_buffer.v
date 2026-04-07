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

    // Patch feedback interface
    input  wire                        patch_valid,
    output wire                        patch_ready,
    input  wire [LINE_ADDR_WIDTH-1:0]  patch_center_x,
    input  wire [12:0]                 patch_center_y,
    input  wire [DATA_WIDTH*25-1:0]    patch_5x5,

    // 5x5 Window output with handshake
    output wire [DATA_WIDTH-1:0]       window_0_0, window_0_1, window_0_2, window_0_3, window_0_4,
    output wire [DATA_WIDTH-1:0]       window_1_0, window_1_1, window_1_2, window_1_3, window_1_4,
    output wire [DATA_WIDTH-1:0]       window_2_0, window_2_1, window_2_2, window_2_3, window_2_4,
    output wire [DATA_WIDTH-1:0]       window_3_0, window_3_1, window_3_2, window_3_3, window_3_4,
    output wire [DATA_WIDTH-1:0]       window_4_0, window_4_1, window_4_2, window_4_3, window_4_4,
    output reg                         window_valid,
    input  wire                        window_ready,
    output wire [LINE_ADDR_WIDTH-1:0]  center_x,
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
    localparam PATCH_WIDTH = DATA_WIDTH * 25;

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

    // Row counter
    reg [12:0] row_cnt;

    // Frame state
    reg       frame_started;
    reg       eol_pending;
    reg       tail_pending;

    // Flush / tail context
    reg [2:0]                 flush_cnt;
    reg                       flush_active;
    reg [LINE_ADDR_WIDTH-1:0] flush_center;
    reg [2:0]                 flush_row_ptr;
    reg [12:0]                flush_row_cnt;
    reg                       window_valid_next;
    reg                       tail_active;
    reg [2:0]                 tail_base_ptr;
    reg [LINE_ADDR_WIDTH-1:0] tail_col_ptr;
    reg [12:0]                tail_center_y;

    function [2:0] row_minus_wrap;
        input [2:0] base;
        input [2:0] delta;
        begin
            if (base >= delta)
                row_minus_wrap = base - delta;
            else
                row_minus_wrap = base + 3'd5 - delta;
        end
    endfunction

    //=========================================================================
    // Input Handshake - din_ready
    //=========================================================================
    // din_ready indicates when the module can accept new input data
    // Ready only when downstream can accept the next window.
    assign din_ready = enable && frame_started && window_ready;

    wire window_stalled = !window_ready;
    wire eol_fire = (eol || eol_pending) && !window_stalled;
    wire [2:0] lb_wr_row = (wr_row_ptr + lb_wb_row_offset) % 5;
    assign patch_ready = 1'b1;

    function [DATA_WIDTH-1:0] patch_value_at;
        input integer patch_y;
        input integer patch_x;
        integer bit_index;
        begin
            bit_index = ((patch_y * 5) + patch_x) * DATA_WIDTH;
            patch_value_at = patch_5x5[bit_index +: DATA_WIDTH];
        end
    endfunction

    //=========================================================================
    // Write Logic
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        integer patch_dx;
        integer patch_dy;
        integer patch_x;
        integer patch_y;
        reg [DATA_WIDTH-1:0] patch_pixel;
        if (!rst_n) begin
            wr_row_ptr   <= 3'd0;
            wr_col_ptr   <= {LINE_ADDR_WIDTH{1'b0}};
            row_cnt      <= 13'd0;
            eol_pending  <= 1'b0;
        end else if (sof) begin
            wr_row_ptr   <= 3'd0;
            wr_col_ptr   <= {LINE_ADDR_WIDTH{1'b0}};
            row_cnt      <= 13'd0;
            eol_pending  <= 1'b0;
        end else if (enable) begin
            if (eol && window_stalled)
                eol_pending <= 1'b1;
            else if (eol_fire)
                eol_pending <= 1'b0;

            // Handle EOL to update row pointer and reset column
            if (eol_fire) begin
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

            // Feedback writeback shares the same line memories as the input path.
            // Keep the commit in this sequencer so a cycle with both writes has
            // deterministic ordering; writeback wins if both target the same cell.
            if (lb_wb_en) begin
                case (lb_wr_row)
                    3'd0: line_mem_0[lb_wb_addr] <= lb_wb_data;
                    3'd1: line_mem_1[lb_wb_addr] <= lb_wb_data;
                    3'd2: line_mem_2[lb_wb_addr] <= lb_wb_data;
                    3'd3: line_mem_3[lb_wb_addr] <= lb_wb_data;
                    3'd4: line_mem_4[lb_wb_addr] <= lb_wb_data;
                endcase
            end

            if (patch_valid && patch_ready) begin
                for (patch_dy = -2; patch_dy <= 2; patch_dy = patch_dy + 1) begin
                    for (patch_dx = -2; patch_dx <= 2; patch_dx = patch_dx + 1) begin
                        patch_x = patch_center_x;
                        patch_x = patch_x + patch_dx;
                        if (patch_x < 0)
                            patch_x = 0;
                        else if (patch_x >= img_width)
                            patch_x = img_width - 1;

                        patch_y = patch_center_y;
                        patch_y = patch_y + patch_dy;
                        if (patch_y < 0)
                            patch_y = 0;
                        else if (patch_y >= img_height)
                            patch_y = img_height - 1;

                        patch_pixel = patch_value_at(patch_dy + 2, patch_dx + 2);
                        case (patch_y % 5)
                            0: line_mem_0[patch_x] <= patch_pixel;
                            1: line_mem_1[patch_x] <= patch_pixel;
                            2: line_mem_2[patch_x] <= patch_pixel;
                            3: line_mem_3[patch_x] <= patch_pixel;
                            default: line_mem_4[patch_x] <= patch_pixel;
                        endcase
                    end
                end
            end
        end
    end

    //=========================================================================
    // Line Buffer Feedback Writeback Logic
    //=========================================================================
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

    wire [2:0] wr_row_prev  = row_minus_wrap(wr_row_ptr, 3'd1);
    wire [2:0] wr_row_prev2 = row_minus_wrap(wr_row_ptr, 3'd2);
    wire [2:0] wr_row_prev3 = row_minus_wrap(wr_row_ptr, 3'd3);
    wire [2:0] wr_row_prev4 = row_minus_wrap(wr_row_ptr, 3'd4);

    wire [2:0] flush_row_prev  = row_minus_wrap(flush_row_ptr, 3'd1);
    wire [2:0] flush_row_prev2 = row_minus_wrap(flush_row_ptr, 3'd2);
    wire [2:0] flush_row_prev3 = row_minus_wrap(flush_row_ptr, 3'd3);
    wire [2:0] flush_row_prev4 = row_minus_wrap(flush_row_ptr, 3'd4);

    wire [2:0] tail_row_prev1 = row_minus_wrap(tail_base_ptr, 3'd1);
    wire [2:0] tail_row_prev2 = row_minus_wrap(tail_base_ptr, 3'd2);
    wire [2:0] tail_row_prev3 = row_minus_wrap(tail_base_ptr, 3'd3);
    wire [2:0] tail_row_prev4 = row_minus_wrap(tail_base_ptr, 3'd4);

    // Physical row selection for the currently written row context.
    // The streamed window is centered on row_cnt-2, so the current write row
    // provides the +2 vertical tap.
    wire [2:0] stream_row_0_phys = (row_cnt == 13'd2) ? wr_row_prev2 :
                                   (row_cnt == 13'd3) ? wr_row_prev3 :
                                                        wr_row_prev4;
    wire [2:0] stream_row_1_phys = (row_cnt == 13'd2) ? wr_row_prev2 :
                                   (row_cnt == 13'd3) ? wr_row_prev3 :
                                                        wr_row_prev3;
    wire [2:0] stream_row_2_phys = wr_row_prev2;
    wire [2:0] stream_row_3_phys = wr_row_prev;
    wire [2:0] stream_row_4_phys = wr_row_ptr;

    // Flush uses the row context captured at EOL before wr_row_ptr/row_cnt advance.
    wire [2:0] flush_ctx_row_0_phys = (flush_row_cnt == 13'd2) ? flush_row_prev2 :
                                      (flush_row_cnt == 13'd3) ? flush_row_prev3 :
                                                                  flush_row_prev4;
    wire [2:0] flush_ctx_row_1_phys = (flush_row_cnt == 13'd2) ? flush_row_prev2 :
                                      (flush_row_cnt == 13'd3) ? flush_row_prev3 :
                                                                  flush_row_prev3;
    wire [2:0] flush_ctx_row_2_phys = flush_row_prev2;
    wire [2:0] flush_ctx_row_3_phys = flush_row_prev;
    wire [2:0] flush_ctx_row_4_phys = flush_row_ptr;

    // Tail rows after EOF duplicate the bottom line.
    wire [2:0] tail_row_0_phys = (tail_center_y == img_height - 1'b1) ? tail_row_prev3 : tail_row_prev4;
    wire [2:0] tail_row_1_phys = (tail_center_y == img_height - 1'b1) ? tail_row_prev2 : tail_row_prev3;
    wire [2:0] tail_row_2_phys = (tail_center_y == img_height - 1'b1) ? tail_row_prev1 : tail_row_prev2;
    wire [2:0] tail_row_3_phys = tail_row_prev1;
    wire [2:0] tail_row_4_phys = tail_row_prev1;

    wire [2:0] win_row_0_phys = tail_active ? tail_row_0_phys :
                                flush_active ? flush_ctx_row_0_phys :
                                               stream_row_0_phys;
    wire [2:0] win_row_1_phys = tail_active ? tail_row_1_phys :
                                flush_active ? flush_ctx_row_1_phys :
                                               stream_row_1_phys;
    wire [2:0] win_row_2_phys = tail_active ? tail_row_2_phys :
                                flush_active ? flush_ctx_row_2_phys :
                                               stream_row_2_phys;
    wire [2:0] win_row_3_phys = tail_active ? tail_row_3_phys :
                                flush_active ? flush_ctx_row_3_phys :
                                               stream_row_3_phys;
    wire [2:0] win_row_4_phys = tail_active ? tail_row_4_phys :
                                flush_active ? flush_ctx_row_4_phys :
                                               stream_row_4_phys;

    // Combinational output center calculation
    // output_center = wr_col_ptr - 5 (valid when wr_col_ptr >= 5)
    // The 5x5 UV window uses horizontal taps {-4, -2, 0, +2, +4}, so the
    // +4 sample must already be committed before the center can be emitted.
    wire [LINE_ADDR_WIDTH-1:0] output_center = (wr_col_ptr >= 5) ? wr_col_ptr - 3'd5 : {LINE_ADDR_WIDTH{1'b0}};

    // Register the output center to keep it stable during window_valid
    reg [LINE_ADDR_WIDTH-1:0] rd_col_ptr;

    // Window capture timing:
    // We want to output a window for center column C when pixel C+2 has been written.
    // This means when wr_col_ptr = C+3, we capture the window for center C.
    //
    // CRITICAL FIX: Create a separate stable capture address register
    // that is updated ONE CYCLE BEFORE the capture fires.
    //
    // Timeline:
    //   wr_col_ptr=4: capture_addr <= 0 (for future center 0 capture)
    //   wr_col_ptr=5: capture fires for center 0, capture_addr <= 1 (for future center 1)
    //   wr_col_ptr=6: capture fires for center 1, capture_addr <= 2 (for future center 2)
    //
    // Key: capture_addr uses wr_col_ptr-4, so at wr_col_ptr=5, capture_addr was set to 0
    // in the previous cycle and is STABLE when capture fires.

    reg [LINE_ADDR_WIDTH-1:0] capture_addr;

    // Update capture_addr at wr_col_ptr >= 4 with value wr_col_ptr - 4.
    // This ensures capture_addr is stable when window_capture fires at wr_col_ptr >= 5.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            capture_addr <= {LINE_ADDR_WIDTH{1'b0}};
        end else if (sof) begin
            capture_addr <= {LINE_ADDR_WIDTH{1'b0}};
        end else if (din_valid && din_ready && !eol && wr_col_ptr >= 4) begin
            // At wr_col_ptr=4: capture_addr <= 0 (for center 0 capture at wr_col_ptr=5)
            // At wr_col_ptr=5: capture_addr <= 1 (for center 1 capture at wr_col_ptr=6)
            capture_addr <= wr_col_ptr - 3'd4;
        end
    end

    // Use the stable capture_addr for capture column
    wire [LINE_ADDR_WIDTH-1:0] capture_col = capture_addr;

    // Column offsets for 5x5 UV window with same-lane horizontal taps:
    // {-4, -2, 0, +2, +4}. The legacy names are kept so existing debug code
    // can still introspect these internal signals.
    wire [LINE_ADDR_WIDTH-1:0] center_col = rd_col_ptr;

    // Left boundary: clamp to 0
    wire [LINE_ADDR_WIDTH-1:0] col_m2 = (center_col < 4) ? {LINE_ADDR_WIDTH{1'b0}} : center_col - 4;
    wire [LINE_ADDR_WIDTH-1:0] col_m1 = (center_col < 2) ? {LINE_ADDR_WIDTH{1'b0}} : center_col - 2;
    wire [LINE_ADDR_WIDTH-1:0] col_0  = center_col;
    wire [LINE_ADDR_WIDTH-1:0] col_p1 = (center_col >= img_width - 2) ? img_width - 1 : center_col + 2;
    wire [LINE_ADDR_WIDTH-1:0] col_p2 = (center_col >= img_width - 4) ? img_width - 1 : center_col + 4;

    // Capture-time column offsets (use stable capture_addr)
    wire [LINE_ADDR_WIDTH-1:0] cap_m2 = (capture_col < 4) ? {LINE_ADDR_WIDTH{1'b0}} : capture_col - 4;
    wire [LINE_ADDR_WIDTH-1:0] cap_m1 = (capture_col < 2) ? {LINE_ADDR_WIDTH{1'b0}} : capture_col - 2;
    wire [LINE_ADDR_WIDTH-1:0] cap_0  = capture_col;
    wire [LINE_ADDR_WIDTH-1:0] cap_p1 = (capture_col >= img_width - 2) ? img_width - 1 : capture_col + 2;
    wire [LINE_ADDR_WIDTH-1:0] cap_p2 = (capture_col >= img_width - 4) ? img_width - 1 : capture_col + 4;

    //=========================================================================
    // Row Boundary Handling - incorporated into win_row_X_phys above
    //=========================================================================

    // Direct multiplexer for memory reads - avoids function timing issues in simulation
    // Helper macro to read from line memory based on row index
    `define READ_LINE_MEM(row_idx, col_addr) \
        ((row_idx) == 0) ? line_mem_0[col_addr] : \
        ((row_idx) == 1) ? line_mem_1[col_addr] : \
        ((row_idx) == 2) ? line_mem_2[col_addr] : \
        ((row_idx) == 3) ? line_mem_3[col_addr] : line_mem_4[col_addr]

    // Generate window outputs (combinational, will be registered below)
    // Window Row 0 (top row)
    wire [DATA_WIDTH-1:0] window_comb_0_0 = `READ_LINE_MEM(win_row_0_phys, col_m2);
    wire [DATA_WIDTH-1:0] window_comb_0_1 = `READ_LINE_MEM(win_row_0_phys, col_m1);
    wire [DATA_WIDTH-1:0] window_comb_0_2 = `READ_LINE_MEM(win_row_0_phys, col_0);
    wire [DATA_WIDTH-1:0] window_comb_0_3 = `READ_LINE_MEM(win_row_0_phys, col_p1);
    wire [DATA_WIDTH-1:0] window_comb_0_4 = `READ_LINE_MEM(win_row_0_phys, col_p2);

    // Window Row 1
    wire [DATA_WIDTH-1:0] window_comb_1_0 = `READ_LINE_MEM(win_row_1_phys, col_m2);
    wire [DATA_WIDTH-1:0] window_comb_1_1 = `READ_LINE_MEM(win_row_1_phys, col_m1);
    wire [DATA_WIDTH-1:0] window_comb_1_2 = `READ_LINE_MEM(win_row_1_phys, col_0);
    wire [DATA_WIDTH-1:0] window_comb_1_3 = `READ_LINE_MEM(win_row_1_phys, col_p1);
    wire [DATA_WIDTH-1:0] window_comb_1_4 = `READ_LINE_MEM(win_row_1_phys, col_p2);

    // Window Row 2 (center row)
    wire [DATA_WIDTH-1:0] window_comb_2_0 = `READ_LINE_MEM(win_row_2_phys, col_m2);
    wire [DATA_WIDTH-1:0] window_comb_2_1 = `READ_LINE_MEM(win_row_2_phys, col_m1);
    wire [DATA_WIDTH-1:0] window_comb_2_2 = `READ_LINE_MEM(win_row_2_phys, col_0);
    wire [DATA_WIDTH-1:0] window_comb_2_3 = `READ_LINE_MEM(win_row_2_phys, col_p1);
    wire [DATA_WIDTH-1:0] window_comb_2_4 = `READ_LINE_MEM(win_row_2_phys, col_p2);

    // Window Row 3
    wire [DATA_WIDTH-1:0] window_comb_3_0 = `READ_LINE_MEM(win_row_3_phys, col_m2);
    wire [DATA_WIDTH-1:0] window_comb_3_1 = `READ_LINE_MEM(win_row_3_phys, col_m1);
    wire [DATA_WIDTH-1:0] window_comb_3_2 = `READ_LINE_MEM(win_row_3_phys, col_0);
    wire [DATA_WIDTH-1:0] window_comb_3_3 = `READ_LINE_MEM(win_row_3_phys, col_p1);
    wire [DATA_WIDTH-1:0] window_comb_3_4 = `READ_LINE_MEM(win_row_3_phys, col_p2);

    // Window Row 4 (bottom row)
    wire [DATA_WIDTH-1:0] window_comb_4_0 = `READ_LINE_MEM(win_row_4_phys, col_m2);
    wire [DATA_WIDTH-1:0] window_comb_4_1 = `READ_LINE_MEM(win_row_4_phys, col_m1);
    wire [DATA_WIDTH-1:0] window_comb_4_2 = `READ_LINE_MEM(win_row_4_phys, col_0);
    wire [DATA_WIDTH-1:0] window_comb_4_3 = `READ_LINE_MEM(win_row_4_phys, col_p1);
    wire [DATA_WIDTH-1:0] window_comb_4_4 = `READ_LINE_MEM(win_row_4_phys, col_p2);

    // Capture-time window signals (use capture_addr for correct timing)
    wire [DATA_WIDTH-1:0] window_cap_0_0 = `READ_LINE_MEM(win_row_0_phys, cap_m2);
    wire [DATA_WIDTH-1:0] window_cap_0_1 = `READ_LINE_MEM(win_row_0_phys, cap_m1);
    wire [DATA_WIDTH-1:0] window_cap_0_2 = `READ_LINE_MEM(win_row_0_phys, cap_0);
    wire [DATA_WIDTH-1:0] window_cap_0_3 = `READ_LINE_MEM(win_row_0_phys, cap_p1);
    wire [DATA_WIDTH-1:0] window_cap_0_4 = `READ_LINE_MEM(win_row_0_phys, cap_p2);

    wire [DATA_WIDTH-1:0] window_cap_1_0 = `READ_LINE_MEM(win_row_1_phys, cap_m2);
    wire [DATA_WIDTH-1:0] window_cap_1_1 = `READ_LINE_MEM(win_row_1_phys, cap_m1);
    wire [DATA_WIDTH-1:0] window_cap_1_2 = `READ_LINE_MEM(win_row_1_phys, cap_0);
    wire [DATA_WIDTH-1:0] window_cap_1_3 = `READ_LINE_MEM(win_row_1_phys, cap_p1);
    wire [DATA_WIDTH-1:0] window_cap_1_4 = `READ_LINE_MEM(win_row_1_phys, cap_p2);

    wire [DATA_WIDTH-1:0] window_cap_2_0 = `READ_LINE_MEM(win_row_2_phys, cap_m2);
    wire [DATA_WIDTH-1:0] window_cap_2_1 = `READ_LINE_MEM(win_row_2_phys, cap_m1);
    wire [DATA_WIDTH-1:0] window_cap_2_2 = `READ_LINE_MEM(win_row_2_phys, cap_0);
    wire [DATA_WIDTH-1:0] window_cap_2_3 = `READ_LINE_MEM(win_row_2_phys, cap_p1);
    wire [DATA_WIDTH-1:0] window_cap_2_4 = `READ_LINE_MEM(win_row_2_phys, cap_p2);

    wire [DATA_WIDTH-1:0] window_cap_3_0 = `READ_LINE_MEM(win_row_3_phys, cap_m2);
    wire [DATA_WIDTH-1:0] window_cap_3_1 = `READ_LINE_MEM(win_row_3_phys, cap_m1);
    wire [DATA_WIDTH-1:0] window_cap_3_2 = `READ_LINE_MEM(win_row_3_phys, cap_0);
    wire [DATA_WIDTH-1:0] window_cap_3_3 = `READ_LINE_MEM(win_row_3_phys, cap_p1);
    wire [DATA_WIDTH-1:0] window_cap_3_4 = `READ_LINE_MEM(win_row_3_phys, cap_p2);

    wire [DATA_WIDTH-1:0] window_cap_4_0 = `READ_LINE_MEM(win_row_4_phys, cap_m2);
    wire [DATA_WIDTH-1:0] window_cap_4_1 = `READ_LINE_MEM(win_row_4_phys, cap_m1);
    wire [DATA_WIDTH-1:0] window_cap_4_2 = `READ_LINE_MEM(win_row_4_phys, cap_0);
    wire [DATA_WIDTH-1:0] window_cap_4_3 = `READ_LINE_MEM(win_row_4_phys, cap_p1);
    wire [DATA_WIDTH-1:0] window_cap_4_4 = `READ_LINE_MEM(win_row_4_phys, cap_p2);

    `undef READ_LINE_MEM

    //=========================================================================
    // Read Pointer and Valid Control with Back-pressure Support
    //=========================================================================
    // Window output timing:
    // For center column C, we need the +2 and +4 taps to be written.
    // When wr_col_ptr points to NEXT column to write, center C is valid when
    // wr_col_ptr > C + 4, i.e., C < wr_col_ptr - 4.
    //
    // Simple approach: Output one window per input pixel.
    // When wr_col_ptr >= 5 (after writing pixel 4 and one more cycle for RAM
    // visibility), output center = wr_col_ptr - 5.
    // This gives us center 0,1,2,... in sequence.
    //
    // Computation:
    //   - output_center = wr_col_ptr - 5 (valid when wr_col_ptr >= 5)
    //   - center_x uses registered output_center
    //
    // Flush logic: After row ends, we need to output remaining windows for centers
    // that don't have a corresponding din_valid (the last 2-3 pixels of each row).

    // Flush state machine

    // Window output delay register - to align with memory write timing
    reg [DATA_WIDTH-1:0] window_reg_0_0, window_reg_0_1, window_reg_0_2, window_reg_0_3, window_reg_0_4;
    reg [DATA_WIDTH-1:0] window_reg_1_0, window_reg_1_1, window_reg_1_2, window_reg_1_3, window_reg_1_4;
    reg [DATA_WIDTH-1:0] window_reg_2_0, window_reg_2_1, window_reg_2_2, window_reg_2_3, window_reg_2_4;
    reg [DATA_WIDTH-1:0] window_reg_3_0, window_reg_3_1, window_reg_3_2, window_reg_3_3, window_reg_3_4;
    reg [DATA_WIDTH-1:0] window_reg_4_0, window_reg_4_1, window_reg_4_2, window_reg_4_3, window_reg_4_4;
    reg [LINE_ADDR_WIDTH-1:0] center_x_reg;
    reg [12:0]                center_y_reg;

    // Register window outputs at posedge clk
    // This ensures window values are stable and aligned with window_valid.
    // The streamed window is emitted two rows behind the current write row, so
    // row_cnt must have reached at least 2 before capture can begin.
    wire window_capture = (row_cnt >= 13'd2) && (wr_col_ptr >= 5) && din_valid && din_ready &&
                          (row_cnt < img_height) && !flush_active && !tail_active && !eol;

    // Capture the output_center value BEFORE wr_col_ptr increments
    // This ensures we capture the correct center for this window
    wire [LINE_ADDR_WIDTH-1:0] capture_center = (wr_col_ptr >= 5) ? wr_col_ptr - 3'd5 : {LINE_ADDR_WIDTH{1'b0}};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            window_reg_0_0 <= 0; window_reg_0_1 <= 0; window_reg_0_2 <= 0; window_reg_0_3 <= 0; window_reg_0_4 <= 0;
            window_reg_1_0 <= 0; window_reg_1_1 <= 0; window_reg_1_2 <= 0; window_reg_1_3 <= 0; window_reg_1_4 <= 0;
            window_reg_2_0 <= 0; window_reg_2_1 <= 0; window_reg_2_2 <= 0; window_reg_2_3 <= 0; window_reg_2_4 <= 0;
            window_reg_3_0 <= 0; window_reg_3_1 <= 0; window_reg_3_2 <= 0; window_reg_3_3 <= 0; window_reg_3_4 <= 0;
            window_reg_4_0 <= 0; window_reg_4_1 <= 0; window_reg_4_2 <= 0; window_reg_4_3 <= 0; window_reg_4_4 <= 0;
            center_x_reg   <= 0;
            center_y_reg   <= 0;
        end else if (window_capture) begin
            // Normal capture: use window_cap_* (based on capture_center)
            window_reg_0_0 <= window_cap_0_0; window_reg_0_1 <= window_cap_0_1; window_reg_0_2 <= window_cap_0_2; window_reg_0_3 <= window_cap_0_3; window_reg_0_4 <= window_cap_0_4;
            window_reg_1_0 <= window_cap_1_0; window_reg_1_1 <= window_cap_1_1; window_reg_1_2 <= window_cap_1_2; window_reg_1_3 <= window_cap_1_3; window_reg_1_4 <= window_cap_1_4;
            window_reg_2_0 <= window_cap_2_0; window_reg_2_1 <= window_cap_2_1; window_reg_2_2 <= window_cap_2_2; window_reg_2_3 <= window_cap_2_3; window_reg_2_4 <= window_cap_2_4;
            window_reg_3_0 <= window_cap_3_0; window_reg_3_1 <= window_cap_3_1; window_reg_3_2 <= window_cap_3_2; window_reg_3_3 <= window_cap_3_3; window_reg_3_4 <= window_cap_3_4;
            window_reg_4_0 <= window_cap_4_0; window_reg_4_1 <= window_cap_4_1; window_reg_4_2 <= window_cap_4_2; window_reg_4_3 <= window_cap_4_3; window_reg_4_4 <= window_cap_4_4;
            center_x_reg   <= capture_center;
            center_y_reg   <= row_cnt - 13'd2;
        end else if ((flush_active && flush_cnt > 0) || tail_active) begin
            // Flush mode: use window_comb_* (based on rd_col_ptr which is set correctly during flush)
            window_reg_0_0 <= window_comb_0_0; window_reg_0_1 <= window_comb_0_1; window_reg_0_2 <= window_comb_0_2; window_reg_0_3 <= window_comb_0_3; window_reg_0_4 <= window_comb_0_4;
            window_reg_1_0 <= window_comb_1_0; window_reg_1_1 <= window_comb_1_1; window_reg_1_2 <= window_comb_1_2; window_reg_1_3 <= window_comb_1_3; window_reg_1_4 <= window_comb_1_4;
            window_reg_2_0 <= window_comb_2_0; window_reg_2_1 <= window_comb_2_1; window_reg_2_2 <= window_comb_2_2; window_reg_2_3 <= window_comb_2_3; window_reg_2_4 <= window_comb_2_4;
            window_reg_3_0 <= window_comb_3_0; window_reg_3_1 <= window_comb_3_1; window_reg_3_2 <= window_comb_3_2; window_reg_3_3 <= window_comb_3_3; window_reg_3_4 <= window_comb_3_4;
            window_reg_4_0 <= window_comb_4_0; window_reg_4_1 <= window_comb_4_1; window_reg_4_2 <= window_comb_4_2; window_reg_4_3 <= window_comb_4_3; window_reg_4_4 <= window_comb_4_4;
            center_x_reg   <= center_col;
            center_y_reg   <= tail_active ? tail_center_y : (flush_row_cnt - 13'd2);
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_col_ptr         <= {LINE_ADDR_WIDTH{1'b0}};
            rd_row_ptr         <= 3'd0;
            window_valid       <= 1'b0;
            frame_started      <= 1'b0;
            flush_cnt          <= 3'd0;
            flush_active       <= 1'b0;
            flush_center       <= {LINE_ADDR_WIDTH{1'b0}};
            flush_row_ptr      <= 3'd0;
            flush_row_cnt      <= 13'd0;
            tail_pending       <= 1'b0;
            tail_active        <= 1'b0;
            tail_base_ptr      <= 3'd0;
            tail_col_ptr       <= {LINE_ADDR_WIDTH{1'b0}};
            tail_center_y      <= 13'd0;
            window_valid_next  <= 1'b0;
        end else if (sof) begin
            rd_col_ptr         <= {LINE_ADDR_WIDTH{1'b0}};
            rd_row_ptr         <= 3'd0;
            window_valid       <= 1'b0;
            frame_started      <= 1'b1;
            flush_cnt          <= 3'd0;
            flush_active       <= 1'b0;
            flush_center       <= {LINE_ADDR_WIDTH{1'b0}};
            flush_row_ptr      <= 3'd0;
            flush_row_cnt      <= 13'd0;
            tail_pending       <= 1'b0;
            tail_active        <= 1'b0;
            tail_base_ptr      <= 3'd0;
            tail_col_ptr       <= {LINE_ADDR_WIDTH{1'b0}};
            tail_center_y      <= 13'd0;
            window_valid_next  <= 1'b0;
        end else if (enable && frame_started) begin
            // window_valid follows window_valid_next with one cycle delay
            // This ensures memory writes complete before window output
            window_valid <= window_valid_next;
            window_valid_next <= 1'b0;  // Default: no window next cycle

            // Back-pressure handling:
            // When window_ready=0, pause updates but keep window_valid high
            if (!window_ready && window_valid) begin
                // Back-pressure: hold all output state, re-assert window_valid_next
                window_valid_next <= 1'b1;
            end
            else if (tail_active) begin
                if (tail_center_y >= img_height) begin
                    window_valid_next <= 1'b0;
                    rd_col_ptr        <= {LINE_ADDR_WIDTH{1'b0}};
                    tail_col_ptr      <= {LINE_ADDR_WIDTH{1'b0}};
                    if (tail_center_y > img_height - 1'b1) begin
                        tail_active   <= 1'b0;
                        tail_pending  <= 1'b0;
                    end
                end else begin
                    rd_col_ptr        <= tail_col_ptr;
                    window_valid_next <= 1'b1;

                    if (tail_col_ptr >= img_width - 1'b1) begin
                        tail_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
                        if (tail_center_y >= img_height - 1'b1)
                            tail_center_y <= img_height;
                        else
                            tail_center_y <= img_height - 1'b1;
                    end else begin
                        tail_col_ptr <= tail_col_ptr + 1'b1;
                    end
                end
            end
            else if (flush_active) begin
                // Flush mode: output remaining windows after EOL
                if (flush_cnt > 0) begin
                    rd_col_ptr         <= flush_center;
                    window_valid_next  <= 1'b1;  // Window valid NEXT cycle
                    flush_center       <= flush_center + 1'b1;
                    flush_cnt          <= flush_cnt - 1'b1;
                end else begin
                    // Flush complete
                    window_valid_next  <= 1'b0;
                    flush_active       <= 1'b0;
                    rd_col_ptr         <= {LINE_ADDR_WIDTH{1'b0}};
                    if (tail_pending) begin
                        tail_active   <= 1'b1;
                        tail_pending  <= 1'b0;
                        tail_col_ptr  <= {LINE_ADDR_WIDTH{1'b0}};
                        tail_center_y <= img_height - 2'd2;
                    end
                end
            end
            else begin
                // Handle EOL to start flush
                if (eol_fire) begin
                    if (row_cnt >= 13'd2) begin
                        // Flush the last five horizontal centers for the row whose
                        // +2 vertical tap just completed.
                        flush_active   <= 1'b1;
                        flush_cnt      <= 3'd5;
                        flush_center   <= output_center + 1'b1;
                        flush_row_ptr  <= wr_row_ptr;
                        flush_row_cnt  <= row_cnt;
                    end
                    if (row_cnt == img_height - 1'b1)
                        tail_base_ptr <= (wr_row_ptr == 3'd4) ? 3'd0 : wr_row_ptr + 1'b1;
                    if (row_cnt == img_height - 1'b1)
                        tail_pending <= 1'b1;
                    window_valid       <= 1'b0;
                end else if (din_valid && din_ready) begin
                    // Simple timing: rd_col_ptr = wr_col_ptr - 4 when wr_col_ptr >= 4.
                    // This ensures rd_col_ptr is stable when capture happens at wr_col_ptr >= 5.
                    if ((row_cnt >= 13'd2) && (wr_col_ptr >= 4) && (row_cnt < img_height)) begin
                        // At wr_col_ptr=4: rd_col_ptr = 0 (for wr_col_ptr=5 capture)
                        // At wr_col_ptr=5: rd_col_ptr = 1 (for wr_col_ptr=6 capture)
                        rd_col_ptr         <= wr_col_ptr - 3'd4;
                    end
                    // Window valid when wr_col_ptr >= 5
                    if ((row_cnt >= 13'd2) && (wr_col_ptr >= 5) && (row_cnt < img_height)) begin
                        window_valid       <= 1'b1;
                    end else begin
                        window_valid       <= 1'b0;
                    end
                end else begin
                    window_valid       <= 1'b0;
                end
            end
        end
    end

    // center_y output uses registered value
    assign center_y = center_y_reg;

    // center_x output uses registered value
    assign center_x = center_x_reg;

    // Window outputs use registered values for timing alignment
    assign window_0_0 = window_reg_0_0; assign window_0_1 = window_reg_0_1; assign window_0_2 = window_reg_0_2; assign window_0_3 = window_reg_0_3; assign window_0_4 = window_reg_0_4;
    assign window_1_0 = window_reg_1_0; assign window_1_1 = window_reg_1_1; assign window_1_2 = window_reg_1_2; assign window_1_3 = window_reg_1_3; assign window_1_4 = window_reg_1_4;
    assign window_2_0 = window_reg_2_0; assign window_2_1 = window_reg_2_1; assign window_2_2 = window_reg_2_2; assign window_2_3 = window_reg_2_3; assign window_2_4 = window_reg_2_4;
    assign window_3_0 = window_reg_3_0; assign window_3_1 = window_reg_3_1; assign window_3_2 = window_reg_3_2; assign window_3_3 = window_reg_3_3; assign window_3_4 = window_reg_3_4;
    assign window_4_0 = window_reg_4_0; assign window_4_1 = window_reg_4_1; assign window_4_2 = window_reg_4_2; assign window_4_3 = window_reg_4_3; assign window_4_4 = window_reg_4_4;

endmodule
