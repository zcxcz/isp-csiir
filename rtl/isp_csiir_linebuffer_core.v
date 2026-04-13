//-----------------------------------------------------------------------------
// Module: isp_csiir_linebuffer_core
// Purpose: 5-row storage core with vertical padding and column-stream output
// Author: rtl-impl
// Date: 2026-04-07
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
    input  wire [12:0]                 img_height,
    input  wire [12:0]                 max_center_y_allow,

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
    input  wire [12:0]                 patch_center_y,
    input  wire [DATA_WIDTH*25-1:0]    patch_5x5,

    output wire [DATA_WIDTH-1:0]       col_0,
    output wire [DATA_WIDTH-1:0]       col_1,
    output wire [DATA_WIDTH-1:0]       col_2,
    output wire [DATA_WIDTH-1:0]       col_3,
    output wire [DATA_WIDTH-1:0]       col_4,
    output reg                         column_valid,
    input  wire                        column_ready,
    output wire [LINE_ADDR_WIDTH-1:0]  center_x,
    output wire [12:0]                 center_y
);

    reg [DATA_WIDTH-1:0] line_mem_0 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] line_mem_1 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] line_mem_2 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] line_mem_3 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] line_mem_4 [0:IMG_WIDTH-1];

    reg [2:0]                wr_row_ptr;
    reg [LINE_ADDR_WIDTH-1:0] wr_col_ptr;
    reg [12:0]               row_cnt;
    reg                      frame_started;
    reg                      eol_pending;

    reg                      capture_pending;
    reg [LINE_ADDR_WIDTH-1:0] capture_col;
    reg [12:0]               capture_center_y;
    reg [2:0]                capture_row_0_phys;
    reg [2:0]                capture_row_1_phys;
    reg [2:0]                capture_row_2_phys;
    reg [2:0]                capture_row_3_phys;
    reg [2:0]                capture_row_4_phys;

    reg                      tail_pending;
    reg                      tail_active;
    reg [2:0]                tail_base_ptr;
    reg [LINE_ADDR_WIDTH-1:0] tail_col_ptr;
    reg [12:0]               tail_center_y;
    reg                      tail_row_turnaround;

    reg [DATA_WIDTH-1:0]     col_reg_0;
    reg [DATA_WIDTH-1:0]     col_reg_1;
    reg [DATA_WIDTH-1:0]     col_reg_2;
    reg [DATA_WIDTH-1:0]     col_reg_3;
    reg [DATA_WIDTH-1:0]     col_reg_4;
    reg [LINE_ADDR_WIDTH-1:0] center_x_reg;
    reg [12:0]               center_y_reg;

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
            patch_value_at = patch_5x5[bit_index +: DATA_WIDTH];
        end
    endfunction

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

    assign patch_ready = 1'b1;
    assign din_ready = enable && frame_started && column_ready;

    wire column_stalled = !column_ready;
    wire eol_fire = (eol || eol_pending) && !column_stalled;
    wire [2:0] lb_wr_row = (wr_row_ptr + lb_wb_row_offset) % 5;

    wire [2:0] wr_row_prev  = row_minus_wrap(wr_row_ptr, 3'd1);
    wire [2:0] wr_row_prev2 = row_minus_wrap(wr_row_ptr, 3'd2);
    wire [2:0] wr_row_prev3 = row_minus_wrap(wr_row_ptr, 3'd3);
    wire [2:0] wr_row_prev4 = row_minus_wrap(wr_row_ptr, 3'd4);

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

    wire normal_capture_fire = din_valid && din_ready && (row_cnt >= 13'd2) && (row_cnt < img_height);
    wire last_row_eol_fire = eol_fire && (row_cnt == img_height - 1'b1);
    wire [2:0] next_wr_row_ptr = (wr_row_ptr == 3'd4) ? 3'd0 : wr_row_ptr + 1'b1;
    // Tail flush is part of draining already-issued work and must not be
    // blocked by row dependency gating.
    wire tail_capture_allow = 1'b1;

    always @(posedge clk or negedge rst_n) begin
        integer patch_dx;
        integer patch_dy;
        integer patch_x;
        integer patch_y;
        integer patch_raw_x;
        reg [DATA_WIDTH-1:0] patch_pixel;
        reg                  patch_col_safe;
        if (!rst_n) begin
            wr_row_ptr  <= 3'd0;
            wr_col_ptr  <= {LINE_ADDR_WIDTH{1'b0}};
            row_cnt     <= 13'd0;
            eol_pending <= 1'b0;
        end else if (sof) begin
            wr_row_ptr  <= 3'd0;
            wr_col_ptr  <= {LINE_ADDR_WIDTH{1'b0}};
            row_cnt     <= 13'd0;
            eol_pending <= 1'b0;
        end else if (enable) begin
            if (eol && column_stalled)
                eol_pending <= 1'b1;
            else if (eol_fire)
                eol_pending <= 1'b0;

            if (eol_fire) begin
                wr_col_ptr <= {LINE_ADDR_WIDTH{1'b0}};
                wr_row_ptr <= next_wr_row_ptr;
                row_cnt    <= row_cnt + 1'b1;
            end

            if (din_valid && din_ready) begin
                case (wr_row_ptr)
                    3'd0: line_mem_0[wr_col_ptr] <= din;
                    3'd1: line_mem_1[wr_col_ptr] <= din;
                    3'd2: line_mem_2[wr_col_ptr] <= din;
                    3'd3: line_mem_3[wr_col_ptr] <= din;
                    3'd4: line_mem_4[wr_col_ptr] <= din;
                endcase
                wr_col_ptr <= wr_col_ptr + 1'b1;
            end

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
                for (patch_dx = -2; patch_dx <= 2; patch_dx = patch_dx + 1) begin
                    patch_raw_x = patch_center_x + (patch_dx * 2);
                    patch_col_safe = (patch_raw_x >= 0) && (patch_raw_x < img_width) &&
                                     patch_column_is_safe(patch_center_x, patch_raw_x);
                    if (patch_col_safe) begin
                        patch_x = patch_raw_x;
                        for (patch_dy = -2; patch_dy <= 2; patch_dy = patch_dy + 1) begin
                            patch_y = patch_center_y + patch_dy;
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
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_started      <= 1'b0;
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
        end else if (sof) begin
            frame_started      <= 1'b1;
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
        end else if (enable && frame_started) begin
            if (column_valid && !column_ready) begin
                column_valid <= 1'b1;
            end else if (!column_ready) begin
                // Do not prefetch tail/flush columns while downstream blocks.
                // The tail rows depend on patch feedback becoming visible, so
                // advancing capture state under backpressure would lock in stale
                // columns before feedback commits land.
                column_valid <= 1'b0;
            end else begin
                if (capture_pending) begin
                    col_reg_0    <= read_line_mem(capture_row_0_phys, capture_col);
                    col_reg_1    <= read_line_mem(capture_row_1_phys, capture_col);
                    col_reg_2    <= read_line_mem(capture_row_2_phys, capture_col);
                    col_reg_3    <= read_line_mem(capture_row_3_phys, capture_col);
                    col_reg_4    <= read_line_mem(capture_row_4_phys, capture_col);
                    center_x_reg <= capture_col;
                    center_y_reg <= capture_center_y;
                    column_valid <= 1'b1;
                end else begin
                    column_valid <= 1'b0;
                end

                capture_pending <= 1'b0;

                if (tail_pending && !capture_pending && !tail_active && !normal_capture_fire) begin
                    tail_pending  <= 1'b0;
                    tail_active   <= 1'b1;
                    tail_col_ptr  <= {LINE_ADDR_WIDTH{1'b0}};
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
                                tail_active   <= 1'b0;
                                tail_center_y <= img_height;
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

    assign col_0 = col_reg_0;
    assign col_1 = col_reg_1;
    assign col_2 = col_reg_2;
    assign col_3 = col_reg_3;
    assign col_4 = col_reg_4;
    assign center_x = center_x_reg;
    assign center_y = center_y_reg;

endmodule
