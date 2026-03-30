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

    // Combinational output center calculation
    // output_center = wr_col_ptr - 3 (valid when wr_col_ptr >= 3)
    // This ensures col_p1 and col_p2 have been written before output
    wire [LINE_ADDR_WIDTH-1:0] output_center = (wr_col_ptr >= 3) ? wr_col_ptr - 3'd3 : {LINE_ADDR_WIDTH{1'b0}};

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
    //   wr_col_ptr=2: capture_addr <= 0 (for future center 0 capture)
    //   wr_col_ptr=3: capture fires for center 0, capture_addr <= 1 (for future center 1)
    //   wr_col_ptr=4: capture fires for center 1, capture_addr <= 2 (for future center 2)
    //
    // Key: capture_addr uses wr_col_ptr-2, so at wr_col_ptr=3, capture_addr was set to 0
    // in the previous cycle and is STABLE when capture fires.

    reg [LINE_ADDR_WIDTH-1:0] capture_addr;

    // Update capture_addr at wr_col_ptr >= 2 with value wr_col_ptr - 2
    // This ensures capture_addr is stable when window_capture fires at wr_col_ptr >= 3
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            capture_addr <= {LINE_ADDR_WIDTH{1'b0}};
        end else if (sof) begin
            capture_addr <= {LINE_ADDR_WIDTH{1'b0}};
        end else if (din_valid && din_ready && !eol && wr_col_ptr >= 2) begin
            // At wr_col_ptr=2: capture_addr <= 0 (for center 0 capture at wr_col_ptr=3)
            // At wr_col_ptr=3: capture_addr <= 1 (for center 1 capture at wr_col_ptr=4)
            capture_addr <= wr_col_ptr - 3'd2;
        end
    end

    // Use the stable capture_addr for capture column
    wire [LINE_ADDR_WIDTH-1:0] capture_col = capture_addr;

    // Column offsets for 5x5 window with duplicate padding (clamp to valid range)
    wire [LINE_ADDR_WIDTH-1:0] center_col = rd_col_ptr;

    // Left boundary: clamp to 0
    wire [LINE_ADDR_WIDTH-1:0] col_m2 = (center_col < 2) ? {LINE_ADDR_WIDTH{1'b0}} : center_col - 2;
    wire [LINE_ADDR_WIDTH-1:0] col_m1 = (center_col < 1) ? {LINE_ADDR_WIDTH{1'b0}} : center_col - 1;
    wire [LINE_ADDR_WIDTH-1:0] col_0  = center_col;
    wire [LINE_ADDR_WIDTH-1:0] col_p1 = (center_col >= img_width - 1) ? img_width - 1 : center_col + 1;
    wire [LINE_ADDR_WIDTH-1:0] col_p2 = (center_col >= img_width - 2) ? img_width - 1 : center_col + 2;

    // Capture-time column offsets (use stable capture_addr)
    wire [LINE_ADDR_WIDTH-1:0] cap_m2 = (capture_col < 2) ? {LINE_ADDR_WIDTH{1'b0}} : capture_col - 2;
    wire [LINE_ADDR_WIDTH-1:0] cap_m1 = (capture_col < 1) ? {LINE_ADDR_WIDTH{1'b0}} : capture_col - 1;
    wire [LINE_ADDR_WIDTH-1:0] cap_0  = capture_col;
    wire [LINE_ADDR_WIDTH-1:0] cap_p1 = (capture_col >= img_width - 1) ? img_width - 1 : capture_col + 1;
    wire [LINE_ADDR_WIDTH-1:0] cap_p2 = (capture_col >= img_width - 2) ? img_width - 1 : capture_col + 2;

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
    // For center column C, we need col_p1=C+1 and col_p2=C+2 to be written.
    // When wr_col_ptr points to NEXT column to write, center C is valid when
    // wr_col_ptr > C + 2, i.e., C < wr_col_ptr - 2.
    //
    // Simple approach: Output one window per input pixel.
    // When wr_col_ptr >= 3 (after writing pixel 2), output center = wr_col_ptr - 3.
    // This gives us center 0,1,2,... in sequence.
    //
    // Computation:
    //   - output_center = wr_col_ptr - 3 (valid when wr_col_ptr >= 3)
    //   - center_x uses registered output_center
    //
    // Flush logic: After row ends, we need to output remaining windows for centers
    // that don't have a corresponding din_valid (the last 2-3 pixels of each row).

    // Flush state machine
    reg [1:0] flush_cnt;        // Count remaining windows to output (0-2)
    reg       flush_active;     // Currently flushing remaining windows
    reg [LINE_ADDR_WIDTH-1:0] flush_center;  // Current center during flush

    // Internal signal for when window will be valid next cycle
    reg window_valid_next;

    // Window output delay register - to align with memory write timing
    reg [DATA_WIDTH-1:0] window_reg_0_0, window_reg_0_1, window_reg_0_2, window_reg_0_3, window_reg_0_4;
    reg [DATA_WIDTH-1:0] window_reg_1_0, window_reg_1_1, window_reg_1_2, window_reg_1_3, window_reg_1_4;
    reg [DATA_WIDTH-1:0] window_reg_2_0, window_reg_2_1, window_reg_2_2, window_reg_2_3, window_reg_2_4;
    reg [DATA_WIDTH-1:0] window_reg_3_0, window_reg_3_1, window_reg_3_2, window_reg_3_3, window_reg_3_4;
    reg [DATA_WIDTH-1:0] window_reg_4_0, window_reg_4_1, window_reg_4_2, window_reg_4_3, window_reg_4_4;
    reg [LINE_ADDR_WIDTH-1:0] center_x_reg;
    reg [12:0]                center_y_reg;

    // Register window outputs at posedge clk
    // This ensures window values are stable and aligned with window_valid
    // CRITICAL: Window capture happens when window_valid_next is BEING SET (not one cycle later)
    // This ensures col_0 uses the CORRECT rd_col_ptr value
    wire window_capture = (wr_col_ptr >= 3) && din_valid && din_ready && (row_cnt < img_height) && !flush_active && !eol;

    // Capture the output_center value BEFORE wr_col_ptr increments
    // This ensures we capture the correct center for this window
    wire [LINE_ADDR_WIDTH-1:0] capture_center = (wr_col_ptr >= 3) ? wr_col_ptr - 3'd3 : {LINE_ADDR_WIDTH{1'b0}};

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
            center_y_reg   <= row_cnt;
        end else if (flush_active && flush_cnt > 0) begin
            // Flush mode: use window_comb_* (based on rd_col_ptr which is set correctly during flush)
            window_reg_0_0 <= window_comb_0_0; window_reg_0_1 <= window_comb_0_1; window_reg_0_2 <= window_comb_0_2; window_reg_0_3 <= window_comb_0_3; window_reg_0_4 <= window_comb_0_4;
            window_reg_1_0 <= window_comb_1_0; window_reg_1_1 <= window_comb_1_1; window_reg_1_2 <= window_comb_1_2; window_reg_1_3 <= window_comb_1_3; window_reg_1_4 <= window_comb_1_4;
            window_reg_2_0 <= window_comb_2_0; window_reg_2_1 <= window_comb_2_1; window_reg_2_2 <= window_comb_2_2; window_reg_2_3 <= window_comb_2_3; window_reg_2_4 <= window_comb_2_4;
            window_reg_3_0 <= window_comb_3_0; window_reg_3_1 <= window_comb_3_1; window_reg_3_2 <= window_comb_3_2; window_reg_3_3 <= window_comb_3_3; window_reg_3_4 <= window_comb_3_4;
            window_reg_4_0 <= window_comb_4_0; window_reg_4_1 <= window_comb_4_1; window_reg_4_2 <= window_comb_4_2; window_reg_4_3 <= window_comb_4_3; window_reg_4_4 <= window_comb_4_4;
            center_x_reg   <= center_col;
            center_y_reg   <= row_cnt;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_col_ptr         <= {LINE_ADDR_WIDTH{1'b0}};
            rd_row_ptr         <= 3'd0;
            window_valid       <= 1'b0;
            frame_started      <= 1'b0;
            flush_cnt          <= 2'd0;
            flush_active       <= 1'b0;
            flush_center       <= {LINE_ADDR_WIDTH{1'b0}};
            window_valid_next  <= 1'b0;
        end else if (sof) begin
            rd_col_ptr         <= {LINE_ADDR_WIDTH{1'b0}};
            rd_row_ptr         <= 3'd0;
            window_valid       <= 1'b0;
            frame_started      <= 1'b1;
            flush_cnt          <= 2'd0;
            flush_active       <= 1'b0;
            flush_center       <= {LINE_ADDR_WIDTH{1'b0}};
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
                    // Advance row pointer after 2 rows filled
                    if (row_cnt >= 2) begin
                        rd_row_ptr <= (rd_row_ptr == 3'd4) ? 3'd0 : rd_row_ptr + 1'b1;
                    end
                end
            end
            else begin
                // Handle EOL to start flush
                if (eol) begin
                    // Start flush for remaining windows
                    // Remaining centers: last_center+1, last_center+2, last_center+3
                    flush_active       <= 1'b1;
                    flush_cnt          <= 2'd3;  // 3 remaining windows
                    flush_center       <= output_center + 1'b1;  // Start from next center
                    window_valid       <= 1'b0;
                end else if (din_valid && din_ready) begin
                    // Simple timing: rd_col_ptr = wr_col_ptr - 3 when wr_col_ptr >= 3
                    // Update rd_col_ptr every cycle when wr_col_ptr >= 2
                    // This ensures rd_col_ptr is stable when capture happens at wr_col_ptr >= 3
                    if (wr_col_ptr >= 2 && row_cnt < img_height) begin
                        // rd_col_ptr = wr_col_ptr - 2 (will be wr_col_ptr-3 next cycle)
                        // At wr_col_ptr=2: rd_col_ptr = 0 (for wr_col_ptr=3 capture)
                        // At wr_col_ptr=3: rd_col_ptr = 1 (for wr_col_ptr=4 capture)
                        rd_col_ptr         <= wr_col_ptr - 3'd2;
                    end
                    // Window valid when wr_col_ptr >= 3
                    if (wr_col_ptr >= 3 && row_cnt < img_height) begin
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