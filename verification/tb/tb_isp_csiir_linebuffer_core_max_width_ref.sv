`timescale 1ns/1ps

module tb_isp_csiir_linebuffer_core_max_width_ref;

    /*
    TB_CONTRACT
    - module_name: isp_csiir_linebuffer_core
    - boundary_id: max_width_runtime_contract
    - compare_object: max-width last-column write / eol rollover / writeback-at-last-address
    - expected_source: directed contract expectations for runtime img_width = 5472
    - observed_source: wr_col_ptr / wr_row_ptr / row_cnt / line_mem_x[last]
    - sample_edge: posedge
    - input_valid_ready_contract: final pixel accepted before eol pulse
    - feedback_contract: only lb_wb_en single-cell writeback is enabled in this TB
    */

    localparam MAX_IMG_WIDTH   = 5472;
    localparam DATA_WIDTH      = 10;
    localparam LINE_ADDR_WIDTH = 14;
    localparam CLK_PERIOD      = 10;
    localparam LAST_COL        = MAX_IMG_WIDTH - 1;

    reg                         clk;
    reg                         rst_n;
    reg                         enable;
    reg  [LINE_ADDR_WIDTH-1:0]  img_width;
    reg  [12:0]                 img_height;
    reg  [DATA_WIDTH-1:0]       din;
    reg                         din_valid;
    wire                        din_ready;
    reg                         sof;
    reg                         eol;
    reg                         lb_wb_en;
    reg  [DATA_WIDTH-1:0]       lb_wb_data;
    reg  [LINE_ADDR_WIDTH-1:0]  lb_wb_addr;
    reg  [2:0]                  lb_wb_row_offset;
    reg                         patch_valid;
    wire                        patch_ready;
    reg  [LINE_ADDR_WIDTH-1:0]  patch_center_x;
    reg  [12:0]                 patch_center_y;
    reg  [DATA_WIDTH*25-1:0]    patch_5x5;
    wire [DATA_WIDTH-1:0]       col_0, col_1, col_2, col_3, col_4;
    wire                        column_valid;
    reg                         column_ready;
    wire [LINE_ADDR_WIDTH-1:0]  center_x;
    wire [12:0]                 center_y;

    integer fail_count;

    `define CHECK_EQ_U(TAG, ACT, EXP) \
        if ((ACT) != (EXP)) begin \
            $display("FAIL: %s expected %0d got %0d", TAG, EXP, ACT); \
            fail_count = fail_count + 1; \
        end

    isp_csiir_linebuffer_core #(
        .IMG_WIDTH       (MAX_IMG_WIDTH),
        .DATA_WIDTH      (DATA_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .enable          (enable),
        .img_width       (img_width),
        .img_height      (img_height),
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
        .center_x        (center_x),
        .center_y        (center_y)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    task automatic set_defaults;
        begin
            rst_n           = 1'b0;
            enable          = 1'b0;
            img_width       = MAX_IMG_WIDTH[LINE_ADDR_WIDTH-1:0];
            img_height      = 13'd8;
            din             = {DATA_WIDTH{1'b0}};
            din_valid       = 1'b0;
            sof             = 1'b0;
            eol             = 1'b0;
            lb_wb_en        = 1'b0;
            lb_wb_data      = {DATA_WIDTH{1'b0}};
            lb_wb_addr      = {LINE_ADDR_WIDTH{1'b0}};
            lb_wb_row_offset= 3'd0;
            patch_valid     = 1'b0;
            patch_center_x  = {LINE_ADDR_WIDTH{1'b0}};
            patch_center_y  = 13'd0;
            patch_5x5       = {(DATA_WIDTH*25){1'b0}};
            column_ready    = 1'b1;
        end
    endtask

    task automatic reset_dut;
        begin
            set_defaults();
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            enable = 1'b1;
            sof = 1'b1;
            @(posedge clk);
            sof = 1'b0;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic case_a_last_column_write_and_eol;
        begin
            $display("CASE A: last column write and eol rollover");
            reset_dut();

            dut.wr_row_ptr     = 3'd2;
            dut.wr_col_ptr     = LAST_COL[LINE_ADDR_WIDTH-1:0];
            dut.row_cnt        = 13'd3;
            dut.frame_started  = 1'b1;

            @(negedge clk);
            din       = 10'd321;
            din_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            din_valid = 1'b0;

            `CHECK_EQ_U("caseA last column write", dut.line_mem_2[LAST_COL], 10'd321)
            `CHECK_EQ_U("caseA wr_col_ptr wrap prep", dut.wr_col_ptr, 14'd5472)

            @(negedge clk);
            eol = 1'b1;
            @(posedge clk);
            @(negedge clk);
            eol = 1'b0;

            `CHECK_EQ_U("caseA wr_col_ptr rollover", dut.wr_col_ptr, 14'd0)
            `CHECK_EQ_U("caseA wr_row_ptr increment", dut.wr_row_ptr, 3'd3)
            `CHECK_EQ_U("caseA row_cnt increment", dut.row_cnt, 13'd4)
        end
    endtask

    task automatic case_b_last_column_writeback;
        begin
            $display("CASE B: last column writeback");
            reset_dut();

            dut.wr_row_ptr             = 3'd2;
            dut.line_mem_2[LAST_COL]   = 10'd17;
            dut.line_mem_2[LAST_COL-1] = 10'd23;

            @(negedge clk);
            lb_wb_addr       = LAST_COL[LINE_ADDR_WIDTH-1:0];
            lb_wb_row_offset = 3'd0;
            lb_wb_data       = 10'd777;
            lb_wb_en         = 1'b1;
            @(posedge clk);
            @(negedge clk);
            lb_wb_en         = 1'b0;

            `CHECK_EQ_U("caseB last column updated", dut.line_mem_2[LAST_COL], 10'd777)
            `CHECK_EQ_U("caseB previous column untouched", dut.line_mem_2[LAST_COL-1], 10'd23)
        end
    endtask

    initial begin
        fail_count = 0;

        case_a_last_column_write_and_eol();
        case_b_last_column_writeback();

        if (fail_count != 0) begin
            $display("FAIL: linebuffer_core max-width cases (%0d failures)", fail_count);
            $fatal(1);
        end

        $display("PASS: linebuffer_core max-width cases");
        $finish;
    end

endmodule
