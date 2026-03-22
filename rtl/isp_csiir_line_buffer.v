//-----------------------------------------------------------------------------
// Module: isp_csiir_line_buffer
// Purpose: 5-row line buffer with 5x5 window generation
// Author: rtl-impl
// Date: 2026-03-22
// Version: v2.0 - Updated writeback interface naming
//-----------------------------------------------------------------------------
// Description:
//   Implements 5-row circular line buffer for 5x5 sliding window generation.
//   Supports:
//   - 5-row pixel storage for 5x5 window
//   - Line buffer feedback writeback (u10 format from Stage 4)
//   - Configurable image width
//
// Data Format:
//   - Storage: u10 (10-bit unsigned)
//   - Writeback input: u10 from Stage 4 output
//-----------------------------------------------------------------------------

module isp_csiir_line_buffer #(
    parameter IMG_WIDTH       = 5472,
    parameter DATA_WIDTH      = 10,
    parameter LINE_ADDR_WIDTH = 14
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    // Input pixel stream
    input  wire [DATA_WIDTH-1:0]       din,
    input  wire                        din_valid,
    input  wire                        sof,          // Start of frame
    input  wire                        eol,          // End of line

    // Line buffer feedback writeback (u10 format from Stage 4)
    input  wire                        lb_wb_en,
    input  wire [DATA_WIDTH-1:0]       lb_wb_data,
    input  wire [LINE_ADDR_WIDTH-1:0]  lb_wb_addr,
    input  wire [2:0]                  lb_wb_row_offset,

    // 5x5 Window output
    output wire [DATA_WIDTH-1:0]       window_0_0, window_0_1, window_0_2, window_0_3, window_0_4,
    output wire [DATA_WIDTH-1:0]       window_1_0, window_1_1, window_1_2, window_1_3, window_1_4,
    output wire [DATA_WIDTH-1:0]       window_2_0, window_2_1, window_2_2, window_2_3, window_2_4,
    output wire [DATA_WIDTH-1:0]       window_3_0, window_3_1, window_3_2, window_3_3, window_3_4,
    output wire [DATA_WIDTH-1:0]       window_4_0, window_4_1, window_4_2, window_4_3, window_4_4,
    output reg                         window_valid,
    output reg  [LINE_ADDR_WIDTH-1:0]  center_x,
    output reg  [12:0]                 center_y
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
    // Write Logic
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_row_ptr <= 3'd0;
            wr_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
            row_cnt    <= 13'd0;
        end else if (enable && din_valid) begin
            // Write to current line memory
            case (wr_row_ptr)
                3'd0: line_mem_0[wr_col_ptr] <= din;
                3'd1: line_mem_1[wr_col_ptr] <= din;
                3'd2: line_mem_2[wr_col_ptr] <= din;
                3'd3: line_mem_3[wr_col_ptr] <= din;
                3'd4: line_mem_4[wr_col_ptr] <= din;
            endcase

            // Update column pointer
            if (eol) begin
                wr_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
                wr_row_ptr <= (wr_row_ptr == 3'd4) ? 3'd0 : wr_row_ptr + 1'b1;
                row_cnt    <= row_cnt + 1'b1;
            end else begin
                wr_col_ptr <= wr_col_ptr + 1'b1;
            end
        end else if (sof) begin
            wr_row_ptr <= 3'd0;
            wr_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
            row_cnt    <= 13'd0;
        end
    end

    //=========================================================================
    // Line Buffer Feedback Writeback Logic
    //=========================================================================
    wire [2:0] lb_wr_row = (wr_row_ptr + lb_wb_row_offset) % 5;

    always @(posedge clk) begin
        if (enable && lb_wb_en) begin
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
    // Read Logic - Generate 5x5 Window
    //=========================================================================
    // Calculate read row pointers (5 consecutive rows)
    wire [2:0] rd_row_0 = rd_row_ptr;
    wire [2:0] rd_row_1 = (rd_row_ptr == 3'd4) ? 3'd0 : rd_row_ptr + 1'b1;
    wire [2:0] rd_row_2 = (rd_row_ptr >= 3'd3) ? rd_row_ptr - 3'd3 : rd_row_ptr + 3'd2;
    wire [2:0] rd_row_3 = (rd_row_ptr >= 3'd2) ? rd_row_ptr - 3'd2 : rd_row_ptr + 3'd3;
    wire [2:0] rd_row_4 = (rd_row_ptr >= 3'd1) ? rd_row_ptr - 3'd1 : rd_row_ptr + 3'd4;

    // Column offsets for 5x5 window
    wire [LINE_ADDR_WIDTH-1:0] col_m2 = (rd_col_ptr < 2) ? {LINE_ADDR_WIDTH{1'b0}} : rd_col_ptr - 2;
    wire [LINE_ADDR_WIDTH-1:0] col_m1 = (rd_col_ptr < 1) ? {LINE_ADDR_WIDTH{1'b0}} : rd_col_ptr - 1;
    wire [LINE_ADDR_WIDTH-1:0] col_0  = rd_col_ptr;
    wire [LINE_ADDR_WIDTH-1:0] col_p1 = rd_col_ptr + 1;
    wire [LINE_ADDR_WIDTH-1:0] col_p2 = rd_col_ptr + 2;

    // Generate window outputs (asynchronous read from line memories)
    // Row 0
    assign window_0_0 = (rd_row_0 == 0) ? line_mem_0[col_m2] :
                        (rd_row_0 == 1) ? line_mem_1[col_m2] :
                        (rd_row_0 == 2) ? line_mem_2[col_m2] :
                        (rd_row_0 == 3) ? line_mem_3[col_m2] : line_mem_4[col_m2];
    assign window_0_1 = (rd_row_0 == 0) ? line_mem_0[col_m1] :
                        (rd_row_0 == 1) ? line_mem_1[col_m1] :
                        (rd_row_0 == 2) ? line_mem_2[col_m1] :
                        (rd_row_0 == 3) ? line_mem_3[col_m1] : line_mem_4[col_m1];
    assign window_0_2 = (rd_row_0 == 0) ? line_mem_0[col_0] :
                        (rd_row_0 == 1) ? line_mem_1[col_0] :
                        (rd_row_0 == 2) ? line_mem_2[col_0] :
                        (rd_row_0 == 3) ? line_mem_3[col_0] : line_mem_4[col_0];
    assign window_0_3 = (rd_row_0 == 0) ? line_mem_0[col_p1] :
                        (rd_row_0 == 1) ? line_mem_1[col_p1] :
                        (rd_row_0 == 2) ? line_mem_2[col_p1] :
                        (rd_row_0 == 3) ? line_mem_3[col_p1] : line_mem_4[col_p1];
    assign window_0_4 = (rd_row_0 == 0) ? line_mem_0[col_p2] :
                        (rd_row_0 == 1) ? line_mem_1[col_p2] :
                        (rd_row_0 == 2) ? line_mem_2[col_p2] :
                        (rd_row_0 == 3) ? line_mem_3[col_p2] : line_mem_4[col_p2];

    // Row 1
    assign window_1_0 = (rd_row_1 == 0) ? line_mem_0[col_m2] :
                        (rd_row_1 == 1) ? line_mem_1[col_m2] :
                        (rd_row_1 == 2) ? line_mem_2[col_m2] :
                        (rd_row_1 == 3) ? line_mem_3[col_m2] : line_mem_4[col_m2];
    assign window_1_1 = (rd_row_1 == 0) ? line_mem_0[col_m1] :
                        (rd_row_1 == 1) ? line_mem_1[col_m1] :
                        (rd_row_1 == 2) ? line_mem_2[col_m1] :
                        (rd_row_1 == 3) ? line_mem_3[col_m1] : line_mem_4[col_m1];
    assign window_1_2 = (rd_row_1 == 0) ? line_mem_0[col_0] :
                        (rd_row_1 == 1) ? line_mem_1[col_0] :
                        (rd_row_1 == 2) ? line_mem_2[col_0] :
                        (rd_row_1 == 3) ? line_mem_3[col_0] : line_mem_4[col_0];
    assign window_1_3 = (rd_row_1 == 0) ? line_mem_0[col_p1] :
                        (rd_row_1 == 1) ? line_mem_1[col_p1] :
                        (rd_row_1 == 2) ? line_mem_2[col_p1] :
                        (rd_row_1 == 3) ? line_mem_3[col_p1] : line_mem_4[col_p1];
    assign window_1_4 = (rd_row_1 == 0) ? line_mem_0[col_p2] :
                        (rd_row_1 == 1) ? line_mem_1[col_p2] :
                        (rd_row_1 == 2) ? line_mem_2[col_p2] :
                        (rd_row_1 == 3) ? line_mem_3[col_p2] : line_mem_4[col_p2];

    // Row 2 (center row)
    assign window_2_0 = (rd_row_2 == 0) ? line_mem_0[col_m2] :
                        (rd_row_2 == 1) ? line_mem_1[col_m2] :
                        (rd_row_2 == 2) ? line_mem_2[col_m2] :
                        (rd_row_2 == 3) ? line_mem_3[col_m2] : line_mem_4[col_m2];
    assign window_2_1 = (rd_row_2 == 0) ? line_mem_0[col_m1] :
                        (rd_row_2 == 1) ? line_mem_1[col_m1] :
                        (rd_row_2 == 2) ? line_mem_2[col_m1] :
                        (rd_row_2 == 3) ? line_mem_3[col_m1] : line_mem_4[col_m1];
    assign window_2_2 = (rd_row_2 == 0) ? line_mem_0[col_0] :
                        (rd_row_2 == 1) ? line_mem_1[col_0] :
                        (rd_row_2 == 2) ? line_mem_2[col_0] :
                        (rd_row_2 == 3) ? line_mem_3[col_0] : line_mem_4[col_0];
    assign window_2_3 = (rd_row_2 == 0) ? line_mem_0[col_p1] :
                        (rd_row_2 == 1) ? line_mem_1[col_p1] :
                        (rd_row_2 == 2) ? line_mem_2[col_p1] :
                        (rd_row_2 == 3) ? line_mem_3[col_p1] : line_mem_4[col_p1];
    assign window_2_4 = (rd_row_2 == 0) ? line_mem_0[col_p2] :
                        (rd_row_2 == 1) ? line_mem_1[col_p2] :
                        (rd_row_2 == 2) ? line_mem_2[col_p2] :
                        (rd_row_2 == 3) ? line_mem_3[col_p2] : line_mem_4[col_p2];

    // Row 3
    assign window_3_0 = (rd_row_3 == 0) ? line_mem_0[col_m2] :
                        (rd_row_3 == 1) ? line_mem_1[col_m2] :
                        (rd_row_3 == 2) ? line_mem_2[col_m2] :
                        (rd_row_3 == 3) ? line_mem_3[col_m2] : line_mem_4[col_m2];
    assign window_3_1 = (rd_row_3 == 0) ? line_mem_0[col_m1] :
                        (rd_row_3 == 1) ? line_mem_1[col_m1] :
                        (rd_row_3 == 2) ? line_mem_2[col_m1] :
                        (rd_row_3 == 3) ? line_mem_3[col_m1] : line_mem_4[col_m1];
    assign window_3_2 = (rd_row_3 == 0) ? line_mem_0[col_0] :
                        (rd_row_3 == 1) ? line_mem_1[col_0] :
                        (rd_row_3 == 2) ? line_mem_2[col_0] :
                        (rd_row_3 == 3) ? line_mem_3[col_0] : line_mem_4[col_0];
    assign window_3_3 = (rd_row_3 == 0) ? line_mem_0[col_p1] :
                        (rd_row_3 == 1) ? line_mem_1[col_p1] :
                        (rd_row_3 == 2) ? line_mem_2[col_p1] :
                        (rd_row_3 == 3) ? line_mem_3[col_p1] : line_mem_4[col_p1];
    assign window_3_4 = (rd_row_3 == 0) ? line_mem_0[col_p2] :
                        (rd_row_3 == 1) ? line_mem_1[col_p2] :
                        (rd_row_3 == 2) ? line_mem_2[col_p2] :
                        (rd_row_3 == 3) ? line_mem_3[col_p2] : line_mem_4[col_p2];

    // Row 4
    assign window_4_0 = (rd_row_4 == 0) ? line_mem_0[col_m2] :
                        (rd_row_4 == 1) ? line_mem_1[col_m2] :
                        (rd_row_4 == 2) ? line_mem_2[col_m2] :
                        (rd_row_4 == 3) ? line_mem_3[col_m2] : line_mem_4[col_m2];
    assign window_4_1 = (rd_row_4 == 0) ? line_mem_0[col_m1] :
                        (rd_row_4 == 1) ? line_mem_1[col_m1] :
                        (rd_row_4 == 2) ? line_mem_2[col_m1] :
                        (rd_row_4 == 3) ? line_mem_3[col_m1] : line_mem_4[col_m1];
    assign window_4_2 = (rd_row_4 == 0) ? line_mem_0[col_0] :
                        (rd_row_4 == 1) ? line_mem_1[col_0] :
                        (rd_row_4 == 2) ? line_mem_2[col_0] :
                        (rd_row_4 == 3) ? line_mem_3[col_0] : line_mem_4[col_0];
    assign window_4_3 = (rd_row_4 == 0) ? line_mem_0[col_p1] :
                        (rd_row_4 == 1) ? line_mem_1[col_p1] :
                        (rd_row_4 == 2) ? line_mem_2[col_p1] :
                        (rd_row_4 == 3) ? line_mem_3[col_p1] : line_mem_4[col_p1];
    assign window_4_4 = (rd_row_4 == 0) ? line_mem_0[col_p2] :
                        (rd_row_4 == 1) ? line_mem_1[col_p2] :
                        (rd_row_4 == 2) ? line_mem_2[col_p2] :
                        (rd_row_4 == 3) ? line_mem_3[col_p2] : line_mem_4[col_p2];

    //=========================================================================
    // Read Pointer and Valid Control
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_col_ptr    <= {LINE_ADDR_WIDTH{1'b0}};
            rd_row_ptr    <= 3'd0;
            window_valid  <= 1'b0;
            frame_started <= 1'b0;
            valid_delay   <= 4'd0;
            center_x      <= {LINE_ADDR_WIDTH{1'b0}};
            center_y      <= 13'd0;
        end else if (sof) begin
            rd_col_ptr    <= {LINE_ADDR_WIDTH{1'b0}};
            rd_row_ptr    <= 3'd0;
            window_valid  <= 1'b0;
            frame_started <= 1'b1;
            valid_delay   <= 4'd0;
            center_x      <= {LINE_ADDR_WIDTH{1'b0}};
            center_y      <= 13'd0;
        end else if (enable && din_valid && frame_started) begin
            // Update read column pointer
            if (eol) begin
                rd_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
                // Advance row pointer after 2 rows filled
                if (row_cnt >= 2) begin
                    rd_row_ptr <= (rd_row_ptr == 3'd4) ? 3'd0 : rd_row_ptr + 1'b1;
                    center_y   <= center_y + 1'b1;
                end
            end else begin
                rd_col_ptr <= rd_col_ptr + 1'b1;
            end

            // Valid generation: need 2 rows + 2 columns minimum
            if (row_cnt >= 2 && rd_col_ptr >= 2) begin
                window_valid <= 1'b1;
                center_x     <= rd_col_ptr - 2;  // Center of window
            end else begin
                window_valid <= 1'b0;
            end
        end
    end

endmodule