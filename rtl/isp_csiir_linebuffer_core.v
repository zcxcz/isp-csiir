//-----------------------------------------------------------------------------
// Module: isp_csiir_linebuffer_core
// Purpose: 5-row line buffer with SRAM storage and column-stream output
// Author: rtl-impl
// Date: 2026-04-07 (refactored 2026-04-13)
// Description:
//   5 independent SRAMs act as line buffers. This module controls:
//   - Which row (SRAM) receives the incoming pixel each cycle
//   - Read address generation for column capture (5 pixels per column)
//   - Patch write-back (patch_valid) to specific (row, col) positions
//   - Column output reassembly into 5x1 vertical format
//
//   Write priority: din_valid > patch_valid (they are mutually exclusive)
//-----------------------------------------------------------------------------

module isp_csiir_linebuffer_core #(
    parameter IMG_WIDTH       = 5472,
    parameter DATA_WIDTH      = 10,
    parameter LINE_ADDR_WIDTH = 14
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    input  wire [LINE_ADDR_WIDTH-1:0]  img_width,
    input  wire [12:0]                img_height,
    input  wire [12:0]                max_center_y_allow,

    input  wire [DATA_WIDTH-1:0]       din,
    input  wire                        din_valid,
    output wire                        din_ready,
    input  wire                        sof,
    input  wire                        eol,

    input  wire                        lb_wb_en,
    input  wire [DATA_WIDTH-1:0]       lb_wb_data,
    input  wire [LINE_ADDR_WIDTH-1:0]  lb_wb_addr,
    input  wire [2:0]                  lb_wb_row_offset,

    input  wire                        patch_valid,
    output wire                        patch_ready,
    input  wire [LINE_ADDR_WIDTH-1:0]  patch_center_x,
    input  wire [12:0]               patch_center_y,
    input  wire [DATA_WIDTH*25-1:0]  patch_5x5,

    output wire [DATA_WIDTH-1:0]      col_0,
    output wire [DATA_WIDTH-1:0]      col_1,
    output wire [DATA_WIDTH-1:0]      col_2,
    output wire [DATA_WIDTH-1:0]      col_3,
    output wire [DATA_WIDTH-1:0]      col_4,
    output reg                         column_valid,
    input  wire                        column_ready,
    output wire [LINE_ADDR_WIDTH-1:0]  center_x,
    output wire [12:0]                center_y
);

    //=========================================================================
    // Internal Register/Wire Declarations (declared before use in always blocks)
    //=========================================================================
    // Write pointer
    reg [2:0]                    wr_row_ptr;
    reg [LINE_ADDR_WIDTH-1:0]    wr_col_ptr;
    reg [12:0]                   row_cnt;
    reg                          frame_started;
    reg                          eol_pending;

    // Patch write state
    reg                          patch_wr_fire;
    reg [LINE_ADDR_WIDTH-1:0]    patch_wr_addr;
    reg [DATA_WIDTH-1:0]         patch_wr_data;
    reg [2:0]                    patch_wr_row_idx;
    reg                          patch_pixel_fire;
    reg [LINE_ADDR_WIDTH-1:0]    patch_center_x_reg;
    reg [12:0]                   patch_center_y_reg;
    reg [DATA_WIDTH*25-1:0]      patch_5x5_reg;
    integer                      patch_dx;
    integer                      patch_dy;
    integer                      patch_x;
    integer                      patch_y;
    integer                      bit_index;

    // Column capture
    reg                          capture_pending;
    reg [LINE_ADDR_WIDTH-1:0]    capture_col;
    reg [12:0]                   capture_center_y;
    reg [2:0]                    capture_row_0_phys;
    reg [2:0]                    capture_row_1_phys;
    reg [2:0]                    capture_row_2_phys;
    reg [2:0]                    capture_row_3_phys;
    reg [2:0]                    capture_row_4_phys;

    // Tail/flush
    reg                          tail_pending;
    reg                          tail_active;
    reg [2:0]                    tail_base_ptr;
    reg [LINE_ADDR_WIDTH-1:0]    tail_col_ptr;
    reg [12:0]                   tail_center_y;
    reg                          tail_row_turnaround;

    // Column output registers
    reg [DATA_WIDTH-1:0]         col_reg_0;
    reg [DATA_WIDTH-1:0]         col_reg_1;
    reg [DATA_WIDTH-1:0]         col_reg_2;
    reg [DATA_WIDTH-1:0]         col_reg_3;
    reg [DATA_WIDTH-1:0]         col_reg_4;
    reg [LINE_ADDR_WIDTH-1:0]    center_x_reg;
    reg [12:0]                   center_y_reg;

    // SRAM read address (column capture)
    reg [LINE_ADDR_WIDTH-1:0]    rd_col_addr;

    // SRAM write control (driven from always block)
    reg                          sram_0_wr, sram_1_wr, sram_2_wr, sram_3_wr, sram_4_wr;
    reg [LINE_ADDR_WIDTH-1:0]    sram_wr_addr;
    reg [DATA_WIDTH-1:0]         sram_wr_data;

    //=========================================================================
    // SRAM Read Data Wires
    //=========================================================================
    wire [DATA_WIDTH-1:0] sram_0_rd, sram_1_rd, sram_2_rd, sram_3_rd, sram_4_rd;

    //=========================================================================
    // 5 Line SRAM Instances (read port for column capture, write port shared)
    //=========================================================================
    common_sram_model #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (LINE_ADDR_WIDTH),
        .DEPTH      (IMG_WIDTH),
        .OUTPUT_REG (1)
    ) u_sram_0 (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (enable),
        .wr_en    (sram_0_wr),
        .wr_addr  (sram_wr_addr),
        .wr_data  (sram_wr_data),
        .rd_en    (1'b1),
        .rd_addr  (rd_col_addr),
        .rd_data  (sram_0_rd)
    );

    common_sram_model #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (LINE_ADDR_WIDTH),
        .DEPTH      (IMG_WIDTH),
        .OUTPUT_REG (1)
    ) u_sram_1 (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (enable),
        .wr_en    (sram_1_wr),
        .wr_addr  (sram_wr_addr),
        .wr_data  (sram_wr_data),
        .rd_en    (1'b1),
        .rd_addr  (rd_col_addr),
        .rd_data  (sram_1_rd)
    );

    common_sram_model #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (LINE_ADDR_WIDTH),
        .DEPTH      (IMG_WIDTH),
        .OUTPUT_REG (1)
    ) u_sram_2 (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (enable),
        .wr_en    (sram_2_wr),
        .wr_addr  (sram_wr_addr),
        .wr_data  (sram_wr_data),
        .rd_en    (1'b1),
        .rd_addr  (rd_col_addr),
        .rd_data  (sram_2_rd)
    );

    common_sram_model #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (LINE_ADDR_WIDTH),
        .DEPTH      (IMG_WIDTH),
        .OUTPUT_REG (1)
    ) u_sram_3 (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (enable),
        .wr_en    (sram_3_wr),
        .wr_addr  (sram_wr_addr),
        .wr_data  (sram_wr_data),
        .rd_en    (1'b1),
        .rd_addr  (rd_col_addr),
        .rd_data  (sram_3_rd)
    );

    common_sram_model #(
        .DATA_WIDTH (DATA_WIDTH),
        .ADDR_WIDTH (LINE_ADDR_WIDTH),
        .DEPTH      (IMG_WIDTH),
        .OUTPUT_REG (1)
    ) u_sram_4 (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable   (enable),
        .wr_en    (sram_4_wr),
        .wr_addr  (sram_wr_addr),
        .wr_data  (sram_wr_data),
        .rd_en    (1'b1),
        .rd_addr  (rd_col_addr),
        .rd_data  (sram_4_rd)
    );

    //=========================================================================
    // Write-Back SRAM Instances (lb_wb_* interface - separate write ports)
    //=========================================================================
    wire [2:0] lb_wr_row = (wr_row_ptr + lb_wb_row_offset) % 5;

    wire lb_sram_0_wr = (lb_wr_row == 3'd0) && lb_wb_en;
    wire lb_sram_1_wr = (lb_wr_row == 3'd1) && lb_wb_en;
    wire lb_sram_2_wr = (lb_wr_row == 3'd2) && lb_wb_en;
    wire lb_sram_3_wr = (lb_wr_row == 3'd3) && lb_wb_en;
    wire lb_sram_4_wr = (lb_wr_row == 3'd4) && lb_wb_en;

    common_sram_model #(.DATA_WIDTH (DATA_WIDTH), .ADDR_WIDTH (LINE_ADDR_WIDTH), .DEPTH (IMG_WIDTH), .OUTPUT_REG (0))
    u_lb_sram_0 (.clk(clk), .rst_n(rst_n), .enable(enable), .wr_en(lb_sram_0_wr), .wr_addr(lb_wb_addr), .wr_data(lb_wb_data), .rd_en(1'b0), .rd_addr({LINE_ADDR_WIDTH{1'b0}}), .rd_data());
    common_sram_model #(.DATA_WIDTH (DATA_WIDTH), .ADDR_WIDTH (LINE_ADDR_WIDTH), .DEPTH (IMG_WIDTH), .OUTPUT_REG (0))
    u_lb_sram_1 (.clk(clk), .rst_n(rst_n), .enable(enable), .wr_en(lb_sram_1_wr), .wr_addr(lb_wb_addr), .wr_data(lb_wb_data), .rd_en(1'b0), .rd_addr({LINE_ADDR_WIDTH{1'b0}}), .rd_data());
    common_sram_model #(.DATA_WIDTH (DATA_WIDTH), .ADDR_WIDTH (LINE_ADDR_WIDTH), .DEPTH (IMG_WIDTH), .OUTPUT_REG (0))
    u_lb_sram_2 (.clk(clk), .rst_n(rst_n), .enable(enable), .wr_en(lb_sram_2_wr), .wr_addr(lb_wb_addr), .wr_data(lb_wb_data), .rd_en(1'b0), .rd_addr({LINE_ADDR_WIDTH{1'b0}}), .rd_data());
    common_sram_model #(.DATA_WIDTH (DATA_WIDTH), .ADDR_WIDTH (LINE_ADDR_WIDTH), .DEPTH (IMG_WIDTH), .OUTPUT_REG (0))
    u_lb_sram_3 (.clk(clk), .rst_n(rst_n), .enable(enable), .wr_en(lb_sram_3_wr), .wr_addr(lb_wb_addr), .wr_data(lb_wb_data), .rd_en(1'b0), .rd_addr({LINE_ADDR_WIDTH{1'b0}}), .rd_data());
    common_sram_model #(.DATA_WIDTH (DATA_WIDTH), .ADDR_WIDTH (LINE_ADDR_WIDTH), .DEPTH (IMG_WIDTH), .OUTPUT_REG (0))
    u_lb_sram_4 (.clk(clk), .rst_n(rst_n), .enable(enable), .wr_en(lb_sram_4_wr), .wr_addr(lb_wb_addr), .wr_data(lb_wb_data), .rd_en(1'b0), .rd_addr({LINE_ADDR_WIDTH{1'b0}}), .rd_data());

    //=========================================================================
    // Helper Functions
    //=========================================================================
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

    function [DATA_WIDTH-1:0] patch_value_at;
        input integer patch_y;
        input integer patch_x;
        integer bit_index;
        begin
            bit_index = ((patch_y * 5) + patch_x) * DATA_WIDTH;
            patch_value_at = patch_5x5_reg[bit_index +: DATA_WIDTH];
        end
    endfunction

    function [DATA_WIDTH-1:0] read_line_mem;
        input [2:0] row_idx;
        begin
            case (row_idx)
                3'd0: read_line_mem = sram_0_rd;
                3'd1: read_line_mem = sram_1_rd;
                3'd2: read_line_mem = sram_2_rd;
                3'd3: read_line_mem = sram_3_rd;
                default: read_line_mem = sram_4_rd;
            endcase
        end
    endfunction

    function patch_center_uses_raw_x;
        input integer center_abs_x;
        input integer raw_x;
        integer dx;
        integer cand_x;
        begin
            patch_center_uses_raw_x = 1'b0;
            for (dx = -2; dx <= 2; dx = dx + 1) begin
                cand_x = center_abs_x + (dx * 2);
                if (cand_x < 0)
                    cand_x = 0;
                else if (cand_x >= img_width)
                    cand_x = img_width - 1;
                if (cand_x == raw_x)
                    patch_center_uses_raw_x = 1'b1;
            end
        end
    endfunction

    function patch_column_is_safe;
        input integer center_abs_x;
        input integer raw_x;
        integer future_delta;
        begin
            patch_column_is_safe = 1'b1;
            for (future_delta = 1; future_delta <= 4; future_delta = future_delta + 1) begin
                if ((center_abs_x + future_delta) < img_width) begin
                    if (patch_center_uses_raw_x(center_abs_x + future_delta, raw_x))
                        patch_column_is_safe = 1'b0;
                end
            end
        end
    endfunction

    //=========================================================================
    // Control Signals
    //=========================================================================
    assign patch_ready = 1'b1;
    assign din_ready   = enable && frame_started && column_ready;

    wire column_stalled       = !column_ready;
    wire eol_fire             = (eol || eol_pending) && !column_stalled;
    wire [2:0] next_wr_row_ptr = (wr_row_ptr == 3'd4) ? 3'd0 : wr_row_ptr + 1'b1;

    wire [2:0] wr_row_prev   = row_minus_wrap(wr_row_ptr, 3'd1);
    wire [2:0] wr_row_prev2  = row_minus_wrap(wr_row_ptr, 3'd2);
    wire [2:0] wr_row_prev3  = row_minus_wrap(wr_row_ptr, 3'd3);
    wire [2:0] wr_row_prev4  = row_minus_wrap(wr_row_ptr, 3'd4);

    wire [2:0] tail_row_prev1 = row_minus_wrap(tail_base_ptr, 3'd1);
    wire [2:0] tail_row_prev2 = row_minus_wrap(tail_base_ptr, 3'd2);
    wire [2:0] tail_row_prev3 = row_minus_wrap(tail_base_ptr, 3'd3);
    wire [2:0] tail_row_prev4 = row_minus_wrap(tail_base_ptr, 3'd4);

    wire [2:0] stream_row_0_phys = (row_cnt == 13'd2) ? wr_row_prev2 :
                                   (row_cnt == 13'd3) ? wr_row_prev3 :
                                                        wr_row_prev4;
    wire [2:0] stream_row_1_phys = (row_cnt == 13'd2) ? wr_row_prev2 :
                                   (row_cnt == 13'd3) ? wr_row_prev3 :
                                                        wr_row_prev3;
    wire [2:0] stream_row_2_phys = wr_row_prev2;
    wire [2:0] stream_row_3_phys = wr_row_prev;
    wire [2:0] stream_row_4_phys = wr_row_ptr;

    wire [2:0] tail_row_0_phys = (tail_center_y == img_height - 1'b1) ? tail_row_prev3 : tail_row_prev4;
    wire [2:0] tail_row_1_phys = (tail_center_y == img_height - 1'b1) ? tail_row_prev2 : tail_row_prev3;
    wire [2:0] tail_row_2_phys = (tail_center_y == img_height - 1'b1) ? tail_row_prev1 : tail_row_prev2;
    wire [2:0] tail_row_3_phys = tail_row_prev1;
    wire [2:0] tail_row_4_phys = tail_row_prev1;

    wire normal_capture_fire   = din_valid && din_ready && (row_cnt >= 13'd2) && (row_cnt < img_height);
    wire last_row_eol_fire     = eol_fire && (row_cnt == img_height - 1'b1);
    wire tail_capture_allow   = 1'b1;

    //=========================================================================
    // Main Always Block
    //=========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Write pointer
            wr_row_ptr  <= 3'd0;
            wr_col_ptr  <= {LINE_ADDR_WIDTH{1'b0}};
            row_cnt     <= 13'd0;
            eol_pending <= 1'b0;

            // Patch write state
            patch_wr_fire    <= 1'b0;
            patch_wr_addr    <= {LINE_ADDR_WIDTH{1'b0}};
            patch_wr_data    <= {DATA_WIDTH{1'b0}};
            patch_wr_row_idx <= 3'd0;
            patch_pixel_fire <= 1'b0;
            patch_center_x_reg <= {LINE_ADDR_WIDTH{1'b0}};
            patch_center_y_reg <= 13'd0;
            patch_5x5_reg <= {DATA_WIDTH*25{1'b0}};
            patch_dx <= -2;
            patch_dy <= -2;

            // Column capture
            capture_pending    <= 1'b0;
            capture_col        <= {LINE_ADDR_WIDTH{1'b0}};
            capture_center_y   <= 13'd0;
            capture_row_0_phys <= 3'd0;
            capture_row_1_phys <= 3'd0;
            capture_row_2_phys <= 3'd0;
            capture_row_3_phys <= 3'd0;
            capture_row_4_phys <= 3'd0;

            // Tail/flush
            tail_pending       <= 1'b0;
            tail_active        <= 1'b0;
            tail_base_ptr      <= 3'd0;
            tail_col_ptr       <= {LINE_ADDR_WIDTH{1'b0}};
            tail_center_y      <= 13'd0;
            tail_row_turnaround <= 1'b0;

            // Column output
            col_reg_0          <= {DATA_WIDTH{1'b0}};
            col_reg_1          <= {DATA_WIDTH{1'b0}};
            col_reg_2          <= {DATA_WIDTH{1'b0}};
            col_reg_3          <= {DATA_WIDTH{1'b0}};
            col_reg_4          <= {DATA_WIDTH{1'b0}};
            center_x_reg       <= {LINE_ADDR_WIDTH{1'b0}};
            center_y_reg       <= 13'd0;
            column_valid       <= 1'b0;

            // SRAM control
            rd_col_addr        <= {LINE_ADDR_WIDTH{1'b0}};
            sram_0_wr <= 1'b0;
            sram_1_wr <= 1'b0;
            sram_2_wr <= 1'b0;
            sram_3_wr <= 1'b0;
            sram_4_wr <= 1'b0;
            sram_wr_addr <= {LINE_ADDR_WIDTH{1'b0}};
            sram_wr_data <= {DATA_WIDTH{1'b0}};

        end else if (sof) begin
            wr_row_ptr  <= 3'd0;
            wr_col_ptr  <= {LINE_ADDR_WIDTH{1'b0}};
            row_cnt     <= 13'd0;
            eol_pending <= 1'b0;
            patch_wr_fire    <= 1'b0;
            patch_pixel_fire <= 1'b0;
            patch_center_x_reg <= {LINE_ADDR_WIDTH{1'b0}};
            patch_center_y_reg <= 13'd0;
            capture_pending    <= 1'b0;
            tail_pending       <= 1'b0;
            tail_active        <= 1'b0;
            tail_base_ptr      <= 3'd0;
            tail_col_ptr       <= {LINE_ADDR_WIDTH{1'b0}};
            tail_center_y      <= 13'd0;
            tail_row_turnaround <= 1'b0;
            col_reg_0          <= {DATA_WIDTH{1'b0}};
            col_reg_1          <= {DATA_WIDTH{1'b0}};
            col_reg_2          <= {DATA_WIDTH{1'b0}};
            col_reg_3          <= {DATA_WIDTH{1'b0}};
            col_reg_4          <= {DATA_WIDTH{1'b0}};
            center_x_reg       <= {LINE_ADDR_WIDTH{1'b0}};
            center_y_reg       <= 13'd0;
            column_valid       <= 1'b0;
            capture_col        <= {LINE_ADDR_WIDTH{1'b0}};
            capture_center_y   <= 13'd0;
            capture_row_0_phys <= 3'd0;
            capture_row_1_phys <= 3'd0;
            capture_row_2_phys <= 3'd0;
            capture_row_3_phys <= 3'd0;
            capture_row_4_phys <= 3'd0;
            rd_col_addr        <= {LINE_ADDR_WIDTH{1'b0}};
            frame_started      <= 1'b1;
            sram_0_wr <= 1'b0;
            sram_1_wr <= 1'b0;
            sram_2_wr <= 1'b0;
            sram_3_wr <= 1'b0;
            sram_4_wr <= 1'b0;

        end else if (enable && frame_started) begin
            // Default: no SRAM write
            sram_0_wr <= 1'b0;
            sram_1_wr <= 1'b0;
            sram_2_wr <= 1'b0;
            sram_3_wr <= 1'b0;
            sram_4_wr <= 1'b0;

            // EOL handling
            if (eol && column_stalled)
                eol_pending <= 1'b1;
            else if (eol_fire)
                eol_pending <= 1'b0;

            // Row/column advancement
            if (eol_fire) begin
                wr_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
                wr_row_ptr <= next_wr_row_ptr;
                row_cnt    <= row_cnt + 1'b1;
            end

            // Normal pixel write (highest priority)
            if (din_valid && din_ready) begin
                case (wr_row_ptr)
                    3'd0: sram_0_wr <= 1'b1;
                    3'd1: sram_1_wr <= 1'b1;
                    3'd2: sram_2_wr <= 1'b1;
                    3'd3: sram_3_wr <= 1'b1;
                    3'd4: sram_4_wr <= 1'b1;
                endcase
                sram_wr_addr <= wr_col_ptr;
                sram_wr_data <= din;
                wr_col_ptr   <= wr_col_ptr + 1'b1;
            end

            // Patch write-back (pixel-by-pixel, 25 cycles per patch)
            if (patch_valid && patch_ready && !patch_wr_fire) begin
                // Latch patch data and start
                patch_wr_fire      <= 1'b1;
                patch_center_x_reg <= patch_center_x;
                patch_center_y_reg <= patch_center_y;
                patch_5x5_reg      <= patch_5x5;
                patch_dy <= -2;
                patch_dx <= -2;
                patch_wr_addr    <= patch_center_x;
                patch_wr_row_idx <= patch_center_y % 5;
                bit_index = ((2 * 5) + 2) * DATA_WIDTH;
                patch_wr_data <= patch_5x5[bit_index +: DATA_WIDTH];
            end

            if (patch_wr_fire) begin
                // Determine which row to write
                case (patch_wr_row_idx)
                    3'd0: sram_0_wr <= 1'b1;
                    3'd1: sram_1_wr <= 1'b1;
                    3'd2: sram_2_wr <= 1'b1;
                    3'd3: sram_3_wr <= 1'b1;
                    3'd4: sram_4_wr <= 1'b1;
                endcase

                // Advance pixel index (5x5 grid: scan left-to-right, top-to-bottom)
                if (patch_dx < 2) begin
                    patch_dx <= patch_dx + 1;
                end else begin
                    patch_dx <= -2;
                    patch_dy <= patch_dy + 1;
                end

                // Recalculate for next pixel
                patch_x = patch_wr_addr + (patch_dx * 2);
                patch_y = patch_center_y_reg + patch_dy;

                // Clamp
                if (patch_x < 0) patch_x = 0;
                else if (patch_x >= img_width) patch_x = img_width - 1;
                if (patch_y < 0) patch_y = 0;
                else if (patch_y >= img_height) patch_y = img_height - 1;

                patch_wr_addr    <= patch_x;
                patch_wr_row_idx <= patch_y % 5;
                patch_wr_data    <= patch_value_at(patch_dy + 2, patch_dx + 2);

                // Done after pixel (2,2) - bottom-right of 5x5
                if (patch_dy == 2 && patch_dx == 2) begin
                    patch_wr_fire <= 1'b0;
                end
            end

            // Column capture (read side)
            if (column_valid && !column_ready) begin
                column_valid <= 1'b1;
            end else if (!column_ready) begin
                column_valid <= 1'b0;
            end else begin
                if (capture_pending) begin
                    rd_col_addr    <= capture_col;
                    col_reg_0      <= read_line_mem(capture_row_0_phys);
                    col_reg_1      <= read_line_mem(capture_row_1_phys);
                    col_reg_2      <= read_line_mem(capture_row_2_phys);
                    col_reg_3      <= read_line_mem(capture_row_3_phys);
                    col_reg_4      <= read_line_mem(capture_row_4_phys);
                    center_x_reg   <= capture_col;
                    center_y_reg   <= capture_center_y;
                    column_valid   <= 1'b1;
                end else begin
                    column_valid <= 1'b0;
                end

                capture_pending <= 1'b0;

                if (tail_pending && !capture_pending && !tail_active && !normal_capture_fire) begin
                    tail_pending   <= 1'b0;
                    tail_active    <= 1'b1;
                    tail_col_ptr   <= {LINE_ADDR_WIDTH{1'b0}};
                    tail_center_y <= (img_height > 1) ? (img_height - 2'd2) : 13'd0;
                    tail_row_turnaround <= 1'b0;
                end

                if (normal_capture_fire) begin
                    capture_pending    <= 1'b1;
                    capture_col        <= wr_col_ptr;
                    capture_center_y   <= row_cnt - 13'd2;
                    capture_row_0_phys <= stream_row_0_phys;
                    capture_row_1_phys <= stream_row_1_phys;
                    capture_row_2_phys <= stream_row_2_phys;
                    capture_row_3_phys <= stream_row_3_phys;
                    capture_row_4_phys <= stream_row_4_phys;
                end else if (tail_active && tail_capture_allow) begin
                    if (tail_row_turnaround) begin
                        tail_row_turnaround <= 1'b0;
                    end else begin
                        capture_pending    <= 1'b1;
                        capture_col        <= tail_col_ptr;
                        capture_center_y   <= tail_center_y;
                        capture_row_0_phys <= tail_row_0_phys;
                        capture_row_1_phys <= tail_row_1_phys;
                        capture_row_2_phys <= tail_row_2_phys;
                        capture_row_3_phys <= tail_row_3_phys;
                        capture_row_4_phys <= tail_row_4_phys;

                        if (tail_col_ptr >= img_width - 1'b1) begin
                            tail_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
                            if (tail_center_y >= img_height - 1'b1) begin
                                tail_active    <= 1'b0;
                                tail_center_y  <= img_height;
                                tail_row_turnaround <= 1'b0;
                            end else begin
                                tail_center_y <= tail_center_y + 1'b1;
                                tail_row_turnaround <= 1'b1;
                            end
                        end else begin
                            tail_col_ptr <= tail_col_ptr + 1'b1;
                        end
                    end
                end
            end

            if (last_row_eol_fire) begin
                tail_pending  <= 1'b1;
                tail_base_ptr <= next_wr_row_ptr;
            end
        end
    end

    //=========================================================================
    // Output Assignment
    //=========================================================================
    assign col_0      = col_reg_0;
    assign col_1      = col_reg_1;
    assign col_2      = col_reg_2;
    assign col_3      = col_reg_3;
    assign col_4      = col_reg_4;
    assign center_x   = center_x_reg;
    assign center_y   = center_y_reg;

endmodule
