//-----------------------------------------------------------------------------
// Module: isp_csiir_line_buffer
// Purpose: Compatibility wrapper around linebuffer core + patch assembler
// Author: rtl-impl
// Date: 2026-04-07
//-----------------------------------------------------------------------------

module isp_csiir_line_buffer #(
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

    output wire [DATA_WIDTH-1:0]       window_0_0, window_0_1, window_0_2, window_0_3, window_0_4,
    output wire [DATA_WIDTH-1:0]       window_1_0, window_1_1, window_1_2, window_1_3, window_1_4,
    output wire [DATA_WIDTH-1:0]       window_2_0, window_2_1, window_2_2, window_2_3, window_2_4,
    output wire [DATA_WIDTH-1:0]       window_3_0, window_3_1, window_3_2, window_3_3, window_3_4,
    output wire [DATA_WIDTH-1:0]       window_4_0, window_4_1, window_4_2, window_4_3, window_4_4,
    output wire                        window_valid,
    input  wire                        window_ready,
    output wire [LINE_ADDR_WIDTH-1:0]  center_x,
    output wire [12:0]                 center_y,

    // Column output (for stages that need column-based interface)
    output wire [DATA_WIDTH-1:0]      lb_col_0,
    output wire [DATA_WIDTH-1:0]      lb_col_1,
    output wire [DATA_WIDTH-1:0]      lb_col_2,
    output wire [DATA_WIDTH-1:0]      lb_col_3,
    output wire [DATA_WIDTH-1:0]      lb_col_4,
    output wire                        lb_column_valid,
    input  wire                        lb_column_ready
);

    wire [DATA_WIDTH-1:0]      col_0;
    wire [DATA_WIDTH-1:0]      col_1;
    wire [DATA_WIDTH-1:0]      col_2;
    wire [DATA_WIDTH-1:0]      col_3;
    wire [DATA_WIDTH-1:0]      col_4;
    wire                       column_valid;
    wire                       column_ready;
    wire [LINE_ADDR_WIDTH-1:0] column_center_x;
    wire [12:0]                column_center_y;
    wire [DATA_WIDTH*25-1:0]   assembled_patch_5x5;
    wire                       column_issue_allow;

    // Row dependency backpressure must happen at the top-level window accept
    // boundary so the internal column stream can still drain the current row.
    assign column_issue_allow = 1'b1;

    // Column output connections
    assign lb_col_0 = col_0;
    assign lb_col_1 = col_1;
    assign lb_col_2 = col_2;
    assign lb_col_3 = col_3;
    assign lb_col_4 = col_4;
    assign lb_column_valid = column_valid;

    isp_csiir_linebuffer_core #(
        .IMG_WIDTH       (IMG_WIDTH),
        .DATA_WIDTH      (DATA_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH)
    ) u_core (
        .clk             (clk),
        .rst_n           (rst_n),
        .enable          (enable),
        .img_width       (img_width),
        .img_height      (img_height),
        .max_center_y_allow(max_center_y_allow),
        .din             (din),
        .din_valid       (din_valid),
        .din_ready       (din_ready),
        .sof             (sof),
        .eol             (eol),
        .lb_wb_en        (lb_wb_en),
        .lb_wb_data      (lb_wb_data),
        .lb_wb_addr      (lb_wb_addr),
        .lb_wb_row_offset(lb_wb_row_offset),
        .patch_valid     (patch_valid),
        .patch_ready     (patch_ready),
        .patch_center_x  (patch_center_x),
        .patch_center_y  (patch_center_y),
        .patch_5x5       (patch_5x5),
        .col_0           (col_0),
        .col_1           (col_1),
        .col_2           (col_2),
        .col_3           (col_3),
        .col_4           (col_4),
        .column_valid    (column_valid),
        .column_ready    (column_ready),
        .center_x        (column_center_x),
        .center_y        (column_center_y)
    );

    isp_csiir_patch_assembler_5x5 #(
        .IMG_WIDTH       (IMG_WIDTH),
        .DATA_WIDTH      (DATA_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH)
    ) u_assembler (
        .clk             (clk),
        .rst_n           (rst_n),
        .enable          (enable),
        .img_width       (img_width),
        .col_0           (col_0),
        .col_1           (col_1),
        .col_2           (col_2),
        .col_3           (col_3),
        .col_4           (col_4),
        .column_valid    (column_valid),
        .column_ready    (column_ready),
        .column_issue_allow(column_issue_allow),
        .center_x        (column_center_x),
        .center_y        (column_center_y),
        .window_0_0      (window_0_0),
        .window_0_1      (window_0_1),
        .window_0_2      (window_0_2),
        .window_0_3      (window_0_3),
        .window_0_4      (window_0_4),
        .window_1_0      (window_1_0),
        .window_1_1      (window_1_1),
        .window_1_2      (window_1_2),
        .window_1_3      (window_1_3),
        .window_1_4      (window_1_4),
        .window_2_0      (window_2_0),
        .window_2_1      (window_2_1),
        .window_2_2      (window_2_2),
        .window_2_3      (window_2_3),
        .window_2_4      (window_2_4),
        .window_3_0      (window_3_0),
        .window_3_1      (window_3_1),
        .window_3_2      (window_3_2),
        .window_3_3      (window_3_3),
        .window_3_4      (window_3_4),
        .window_4_0      (window_4_0),
        .window_4_1      (window_4_1),
        .window_4_2      (window_4_2),
        .window_4_3      (window_4_3),
        .window_4_4      (window_4_4),
        .window_valid    (window_valid),
        .window_ready    (window_ready),
        .patch_center_x  (center_x),
        .patch_center_y  (center_y),
        .patch_5x5       (assembled_patch_5x5)
    );

    // Column ready signal from linebuffer core
    assign column_ready = lb_column_ready;

endmodule
