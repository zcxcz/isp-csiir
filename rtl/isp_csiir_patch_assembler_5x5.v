//-----------------------------------------------------------------------------
// Module: isp_csiir_patch_assembler_5x5
// Purpose: Convert 5x1 column stream into 5x5 patch stream with clip padding
// Author: rtl-impl
// Date: 2026-04-07
//-----------------------------------------------------------------------------

module isp_csiir_patch_assembler_5x5 #(
    parameter IMG_WIDTH       = 5472,
    parameter DATA_WIDTH      = 10,
    parameter LINE_ADDR_WIDTH = 14
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        enable,

    input  wire [LINE_ADDR_WIDTH-1:0]  img_width,

    input  wire [DATA_WIDTH-1:0]       col_0,
    input  wire [DATA_WIDTH-1:0]       col_1,
    input  wire [DATA_WIDTH-1:0]       col_2,
    input  wire [DATA_WIDTH-1:0]       col_3,
    input  wire [DATA_WIDTH-1:0]       col_4,
    input  wire                        column_valid,
    output wire                        column_ready,
    input  wire                        column_issue_allow,
    input  wire [LINE_ADDR_WIDTH-1:0]  center_x,
    input  wire [12:0]                 center_y,

    output wire [DATA_WIDTH-1:0]       window_0_0, window_0_1, window_0_2, window_0_3, window_0_4,
    output wire [DATA_WIDTH-1:0]       window_1_0, window_1_1, window_1_2, window_1_3, window_1_4,
    output wire [DATA_WIDTH-1:0]       window_2_0, window_2_1, window_2_2, window_2_3, window_2_4,
    output wire [DATA_WIDTH-1:0]       window_3_0, window_3_1, window_3_2, window_3_3, window_3_4,
    output wire [DATA_WIDTH-1:0]       window_4_0, window_4_1, window_4_2, window_4_3, window_4_4,
    output reg                         window_valid,
    input  wire                        window_ready,
    output wire [LINE_ADDR_WIDTH-1:0]  patch_center_x,
    output wire [12:0]                 patch_center_y,
    output reg  [DATA_WIDTH*25-1:0]    patch_5x5
);

    reg [DATA_WIDTH-1:0] row_mem_0 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] row_mem_1 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] row_mem_2 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] row_mem_3 [0:IMG_WIDTH-1];
    reg [DATA_WIDTH-1:0] row_mem_4 [0:IMG_WIDTH-1];

    reg                        flush_active;
    reg [2:0]                  flush_remaining;
    reg [LINE_ADDR_WIDTH-1:0]  flush_center_x;
    reg [12:0]                 flush_center_y;
    reg [LINE_ADDR_WIDTH-1:0]  patch_center_x_reg;
    reg [12:0]                 patch_center_y_reg;

    integer init_i;
    initial begin
        for (init_i = 0; init_i < IMG_WIDTH; init_i = init_i + 1) begin
            row_mem_0[init_i] = {DATA_WIDTH{1'b0}};
            row_mem_1[init_i] = {DATA_WIDTH{1'b0}};
            row_mem_2[init_i] = {DATA_WIDTH{1'b0}};
            row_mem_3[init_i] = {DATA_WIDTH{1'b0}};
            row_mem_4[init_i] = {DATA_WIDTH{1'b0}};
        end
    end

    function [LINE_ADDR_WIDTH-1:0] clip_x;
        input integer value;
        integer max_x;
        begin
            max_x = img_width - 1;
            if (value < 0)
                clip_x = {LINE_ADDR_WIDTH{1'b0}};
            else if (value > max_x)
                clip_x = max_x[LINE_ADDR_WIDTH-1:0];
            else
                clip_x = value[LINE_ADDR_WIDTH-1:0];
        end
    endfunction

    function [DATA_WIDTH-1:0] read_row_mem;
        input [2:0] row_idx;
        input [LINE_ADDR_WIDTH-1:0] col_addr;
        begin
            case (row_idx)
                3'd0: read_row_mem = row_mem_0[col_addr];
                3'd1: read_row_mem = row_mem_1[col_addr];
                3'd2: read_row_mem = row_mem_2[col_addr];
                3'd3: read_row_mem = row_mem_3[col_addr];
                default: read_row_mem = row_mem_4[col_addr];
            endcase
        end
    endfunction

    function [DATA_WIDTH-1:0] select_pixel;
        input [2:0] row_idx;
        input [LINE_ADDR_WIDTH-1:0] col_addr;
        begin
            if (column_valid && column_ready && (col_addr == center_x)) begin
                case (row_idx)
                    3'd0: select_pixel = col_0;
                    3'd1: select_pixel = col_1;
                    3'd2: select_pixel = col_2;
                    3'd3: select_pixel = col_3;
                    default: select_pixel = col_4;
                endcase
            end else begin
                select_pixel = read_row_mem(row_idx, col_addr);
            end
        end
    endfunction

    task automatic load_patch_for_center;
        input [LINE_ADDR_WIDTH-1:0] center_abs_x;
        reg [LINE_ADDR_WIDTH-1:0] tap_x0;
        reg [LINE_ADDR_WIDTH-1:0] tap_x1;
        reg [LINE_ADDR_WIDTH-1:0] tap_x2;
        reg [LINE_ADDR_WIDTH-1:0] tap_x3;
        reg [LINE_ADDR_WIDTH-1:0] tap_x4;
        begin
            tap_x0 = clip_x($signed({1'b0, center_abs_x}) - 4);
            tap_x1 = clip_x($signed({1'b0, center_abs_x}) - 2);
            tap_x2 = center_abs_x;
            tap_x3 = clip_x($signed({1'b0, center_abs_x}) + 2);
            tap_x4 = clip_x($signed({1'b0, center_abs_x}) + 4);

            patch_5x5[0*DATA_WIDTH +: DATA_WIDTH]  <= select_pixel(3'd0, tap_x0);
            patch_5x5[1*DATA_WIDTH +: DATA_WIDTH]  <= select_pixel(3'd0, tap_x1);
            patch_5x5[2*DATA_WIDTH +: DATA_WIDTH]  <= select_pixel(3'd0, tap_x2);
            patch_5x5[3*DATA_WIDTH +: DATA_WIDTH]  <= select_pixel(3'd0, tap_x3);
            patch_5x5[4*DATA_WIDTH +: DATA_WIDTH]  <= select_pixel(3'd0, tap_x4);
            patch_5x5[5*DATA_WIDTH +: DATA_WIDTH]  <= select_pixel(3'd1, tap_x0);
            patch_5x5[6*DATA_WIDTH +: DATA_WIDTH]  <= select_pixel(3'd1, tap_x1);
            patch_5x5[7*DATA_WIDTH +: DATA_WIDTH]  <= select_pixel(3'd1, tap_x2);
            patch_5x5[8*DATA_WIDTH +: DATA_WIDTH]  <= select_pixel(3'd1, tap_x3);
            patch_5x5[9*DATA_WIDTH +: DATA_WIDTH]  <= select_pixel(3'd1, tap_x4);
            patch_5x5[10*DATA_WIDTH +: DATA_WIDTH] <= select_pixel(3'd2, tap_x0);
            patch_5x5[11*DATA_WIDTH +: DATA_WIDTH] <= select_pixel(3'd2, tap_x1);
            patch_5x5[12*DATA_WIDTH +: DATA_WIDTH] <= select_pixel(3'd2, tap_x2);
            patch_5x5[13*DATA_WIDTH +: DATA_WIDTH] <= select_pixel(3'd2, tap_x3);
            patch_5x5[14*DATA_WIDTH +: DATA_WIDTH] <= select_pixel(3'd2, tap_x4);
            patch_5x5[15*DATA_WIDTH +: DATA_WIDTH] <= select_pixel(3'd3, tap_x0);
            patch_5x5[16*DATA_WIDTH +: DATA_WIDTH] <= select_pixel(3'd3, tap_x1);
            patch_5x5[17*DATA_WIDTH +: DATA_WIDTH] <= select_pixel(3'd3, tap_x2);
            patch_5x5[18*DATA_WIDTH +: DATA_WIDTH] <= select_pixel(3'd3, tap_x3);
            patch_5x5[19*DATA_WIDTH +: DATA_WIDTH] <= select_pixel(3'd3, tap_x4);
            patch_5x5[20*DATA_WIDTH +: DATA_WIDTH] <= select_pixel(3'd4, tap_x0);
            patch_5x5[21*DATA_WIDTH +: DATA_WIDTH] <= select_pixel(3'd4, tap_x1);
            patch_5x5[22*DATA_WIDTH +: DATA_WIDTH] <= select_pixel(3'd4, tap_x2);
            patch_5x5[23*DATA_WIDTH +: DATA_WIDTH] <= select_pixel(3'd4, tap_x3);
            patch_5x5[24*DATA_WIDTH +: DATA_WIDTH] <= select_pixel(3'd4, tap_x4);
        end
    endtask

    assign column_ready = enable && window_ready && !flush_active && column_issue_allow;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flush_active       <= 1'b0;
            flush_remaining    <= 3'd0;
            flush_center_x     <= {LINE_ADDR_WIDTH{1'b0}};
            flush_center_y     <= 13'd0;
            patch_center_x_reg <= {LINE_ADDR_WIDTH{1'b0}};
            patch_center_y_reg <= 13'd0;
            patch_5x5          <= {(DATA_WIDTH*25){1'b0}};
            window_valid       <= 1'b0;
        end else if (enable) begin
            if (window_valid && !window_ready) begin
                window_valid <= 1'b1;
            end else begin
                window_valid <= 1'b0;

                if (flush_active) begin
                    load_patch_for_center(flush_center_x);
                    patch_center_x_reg <= flush_center_x;
                    patch_center_y_reg <= flush_center_y;
                    window_valid       <= 1'b1;

                    if (flush_remaining == 3'd1) begin
                        flush_active    <= 1'b0;
                        flush_remaining <= 3'd0;
                    end else begin
                        flush_remaining <= flush_remaining - 1'b1;
                        flush_center_x  <= flush_center_x + 1'b1;
                    end
                end else if (column_valid && column_ready) begin
                    row_mem_0[center_x] <= col_0;
                    row_mem_1[center_x] <= col_1;
                    row_mem_2[center_x] <= col_2;
                    row_mem_3[center_x] <= col_3;
                    row_mem_4[center_x] <= col_4;

                    if (center_x >= 4) begin
                        load_patch_for_center(center_x - 4);
                        patch_center_x_reg <= center_x - 4;
                        patch_center_y_reg <= center_y;
                        window_valid       <= 1'b1;
                    end

                    if (center_x == img_width - 1'b1) begin
                        flush_active    <= (img_width > 5) || (img_width < 5);
                        flush_remaining <= (img_width > 4) ? 3'd4 : img_width[2:0];
                        flush_center_x  <= (img_width > 4) ? (img_width - 4) : {LINE_ADDR_WIDTH{1'b0}};
                        flush_center_y  <= center_y;
                    end
                end
            end
        end
    end

    assign patch_center_x = patch_center_x_reg;
    assign patch_center_y = patch_center_y_reg;

    assign window_0_0 = patch_5x5[0*DATA_WIDTH +: DATA_WIDTH];
    assign window_0_1 = patch_5x5[1*DATA_WIDTH +: DATA_WIDTH];
    assign window_0_2 = patch_5x5[2*DATA_WIDTH +: DATA_WIDTH];
    assign window_0_3 = patch_5x5[3*DATA_WIDTH +: DATA_WIDTH];
    assign window_0_4 = patch_5x5[4*DATA_WIDTH +: DATA_WIDTH];
    assign window_1_0 = patch_5x5[5*DATA_WIDTH +: DATA_WIDTH];
    assign window_1_1 = patch_5x5[6*DATA_WIDTH +: DATA_WIDTH];
    assign window_1_2 = patch_5x5[7*DATA_WIDTH +: DATA_WIDTH];
    assign window_1_3 = patch_5x5[8*DATA_WIDTH +: DATA_WIDTH];
    assign window_1_4 = patch_5x5[9*DATA_WIDTH +: DATA_WIDTH];
    assign window_2_0 = patch_5x5[10*DATA_WIDTH +: DATA_WIDTH];
    assign window_2_1 = patch_5x5[11*DATA_WIDTH +: DATA_WIDTH];
    assign window_2_2 = patch_5x5[12*DATA_WIDTH +: DATA_WIDTH];
    assign window_2_3 = patch_5x5[13*DATA_WIDTH +: DATA_WIDTH];
    assign window_2_4 = patch_5x5[14*DATA_WIDTH +: DATA_WIDTH];
    assign window_3_0 = patch_5x5[15*DATA_WIDTH +: DATA_WIDTH];
    assign window_3_1 = patch_5x5[16*DATA_WIDTH +: DATA_WIDTH];
    assign window_3_2 = patch_5x5[17*DATA_WIDTH +: DATA_WIDTH];
    assign window_3_3 = patch_5x5[18*DATA_WIDTH +: DATA_WIDTH];
    assign window_3_4 = patch_5x5[19*DATA_WIDTH +: DATA_WIDTH];
    assign window_4_0 = patch_5x5[20*DATA_WIDTH +: DATA_WIDTH];
    assign window_4_1 = patch_5x5[21*DATA_WIDTH +: DATA_WIDTH];
    assign window_4_2 = patch_5x5[22*DATA_WIDTH +: DATA_WIDTH];
    assign window_4_3 = patch_5x5[23*DATA_WIDTH +: DATA_WIDTH];
    assign window_4_4 = patch_5x5[24*DATA_WIDTH +: DATA_WIDTH];

endmodule
