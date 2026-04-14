//-----------------------------------------------------------------------------
// Module: isp_csiir_line_buffer
// Purpose: Wrapper around linebuffer core with 1P-2P serialization
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

    // 1P input (single pixel per cycle)
    input  wire [DATA_WIDTH-1:0]       din,
    input  wire                        din_valid,
    output wire                        din_ready,
    input  wire                        sof,
    input  wire                        eol,

    // Patch feedback from stage4
    input  wire                        patch_valid,
    output wire                        patch_ready,
    input  wire [LINE_ADDR_WIDTH-1:0]  patch_center_x,
    input  wire [12:0]                 patch_center_y,
    input  wire [DATA_WIDTH*25-1:0]    patch_5x5,

    // Legacy writeback (disabled - tied off in top)
    input  wire                        lb_wb_en,
    input  wire [DATA_WIDTH-1:0]       lb_wb_data,
    input  wire [LINE_ADDR_WIDTH-1:0]  lb_wb_addr,
    input  wire [2:0]                  lb_wb_row_offset,

    // Window output (for legacy stage1)
    output wire [DATA_WIDTH-1:0]       window_0_0, window_0_1, window_0_2, window_0_3, window_0_4,
    output wire [DATA_WIDTH-1:0]       window_1_0, window_1_1, window_1_2, window_1_3, window_1_4,
    output wire [DATA_WIDTH-1:0]       window_2_0, window_2_1, window_2_2, window_2_3, window_2_4,
    output wire [DATA_WIDTH-1:0]       window_3_0, window_3_1, window_3_2, window_3_3, window_3_4,
    output wire [DATA_WIDTH-1:0]       window_4_0, window_4_1, window_4_2, window_4_3, window_4_4,
    output wire                        window_valid,
    input  wire                        window_ready,
    output wire [LINE_ADDR_WIDTH-1:0]  center_x,
    output wire [12:0]                 center_y,

    // Column output (for isp_csiir_gradient)
    output wire [DATA_WIDTH-1:0]      lb_col_0,
    output wire [DATA_WIDTH-1:0]      lb_col_1,
    output wire [DATA_WIDTH-1:0]      lb_col_2,
    output wire [DATA_WIDTH-1:0]      lb_col_3,
    output wire [DATA_WIDTH-1:0]      lb_col_4,
    output wire                        lb_column_valid,
    input  wire                        lb_column_ready
);

    //=========================================================================
    // 1P to 2P Serializer
    //=========================================================================
    wire [DATA_WIDTH*2-1:0] ser_dout;
    wire                  ser_dout_valid;
    wire                  ser_even_col;

    common_parallel_serializer #(
        .DATA_WIDTH (DATA_WIDTH)
    ) u_serializer (
        .clk           (clk),
        .rst_n         (rst_n),
        .enable        (enable),
        .sof           (sof),
        .din           (din),
        .din_valid     (din_valid),
        .din_ready     (din_ready),
        .dout          (ser_dout),
        .dout_valid    (ser_dout_valid),
        .dout_ready    (1'b1),  // core always ready when not writing
        .even_col      (ser_even_col)
    );

    //=========================================================================
    // Internal signals
    //=========================================================================
    wire [DATA_WIDTH-1:0]      col_0;
    wire [DATA_WIDTH-1:0]      col_1;
    wire [DATA_WIDTH-1:0]      col_2;
    wire [DATA_WIDTH-1:0]      col_3;
    wire [DATA_WIDTH-1:0]      col_4;
    wire                        col_valid;
    wire                        col_ready;
    wire [LINE_ADDR_WIDTH-1:0] col_center_x;
    wire [12:0]                col_center_y;

    wire [DATA_WIDTH*25-1:0]   assembled_patch_5x5;
    wire                        column_issue_allow;

    // Patch feedback state machine
    reg                         patch_active;
    reg [2:0]                  patch_col_counter;  // 0-4 for 5 columns
    reg [LINE_ADDR_WIDTH-1:0]  patch_base_x;
    reg [12:0]                 patch_base_y;

    wire                       patch_col_req;
    wire                       patch_col_ready;
    wire [LINE_ADDR_WIDTH-1:0] patch_col_addr;
    wire                       patch_col_wr;
    wire [LINE_ADDR_WIDTH-1:0] patch_col_wr_addr;
    wire [DATA_WIDTH*5-1:0]   patch_col_wr_data;

    // Row dependency - always allow for now
    assign column_issue_allow = 1'b1;

    // Column output connections
    assign lb_col_0 = col_0;
    assign lb_col_1 = col_1;
    assign lb_col_2 = col_2;
    assign lb_col_3 = col_3;
    assign lb_col_4 = col_4;
    assign lb_column_valid = col_valid;

    //=========================================================================
    // Patch feedback FSM - convert patch_5x5 to column writes
    //=========================================================================
    // Extract column from patch_5x5
    // patch_5x5 format: row*5*DATA_WIDTH + col*DATA_WIDTH + bit
    // Column c has pixels at patch_5x5[c*DATA_WIDTH +: DATA_WIDTH] for each row
    wire [DATA_WIDTH*5-1:0] patch_col_data;
    genvar c, r;
    generate
        for (c = 0; c < 5; c = c + 1) begin : gen_patch_col_extract
            for (r = 0; r < 5; r = r + 1) begin : gen_patch_row_extract
                assign patch_col_data[c * DATA_WIDTH +: DATA_WIDTH] =
                       patch_5x5[r * 5 * DATA_WIDTH + c * DATA_WIDTH +: DATA_WIDTH];
            end
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            patch_active <= 1'b0;
            patch_col_counter <= 3'd0;
        end else if (sof) begin
            patch_active <= 1'b0;
            patch_col_counter <= 3'd0;
        end else if (enable) begin
            if (patch_valid && !patch_active) begin
                // Start of new patch feedback
                patch_active <= 1'b1;
                patch_base_x <= patch_center_x;
                patch_base_y <= patch_center_y;
                patch_col_counter <= 3'd0;
            end else if (patch_active && patch_col_wr && patch_col_ready) begin
                if (patch_col_counter >= 3'd4) begin
                    // All 5 columns written
                    patch_active <= 1'b0;
                end
                patch_col_counter <= patch_col_counter + 1'b1;
            end
        end
    end

    assign patch_col_req = patch_active && !patch_valid;  // Request when active
    assign patch_col_addr = patch_base_x >> 1;  // Convert to SRAM address
    assign patch_col_wr = patch_active && patch_col_ready;
    assign patch_col_wr_addr = (patch_base_x + patch_col_counter * 2) >> 1;
    assign patch_col_wr_data = patch_col_data;

    assign patch_ready = 1'b1;  // Always ready to accept new patch

    //=========================================================================
    // Linebuffer Core Instance
    //=========================================================================
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
        .din_even        (ser_dout[0 +: DATA_WIDTH]),
        .din_odd         (ser_dout[DATA_WIDTH +: DATA_WIDTH]),
        .din_valid       (ser_dout_valid),
        .din_col_even    (ser_even_col),
        .din_ready       (),  // Not used - serializer controls ready
        .sof             (sof),
        .eol             (eol),
        .patch_col_req   (patch_col_req),
        .patch_col_ready (patch_col_ready),
        .patch_col_addr  (patch_col_addr),
        .patch_col_wr    (patch_col_wr),
        .patch_col_wr_addr (patch_col_wr_addr),
        .patch_col_wr_data (patch_col_wr_data),
        .col_0           (col_0),
        .col_1           (col_1),
        .col_2           (col_2),
        .col_3           (col_3),
        .col_4           (col_4),
        .col_valid       (col_valid),
        .col_ready       (lb_column_ready),
        .col_center_x    (col_center_x),
        .col_center_y    (col_center_y),
        .bypass_even     (),
        .bypass_odd      (),
        .bypass_valid    (),
        .bypass_ready    (1'b0)
    );

    //=========================================================================
    // Patch Assembler Instance
    //=========================================================================
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
        .column_valid    (col_valid),
        .column_ready    (lb_column_ready),
        .column_issue_allow(column_issue_allow),
        .center_x        (col_center_x),
        .center_y        (col_center_y),
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
        .window_valid     (window_valid),
        .window_ready     (window_ready),
        .patch_center_x   (center_x),
        .patch_center_y   (center_y),
        .patch_5x5        (assembled_patch_5x5)
    );

endmodule
