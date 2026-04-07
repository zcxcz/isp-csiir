`timescale 1ns/1ps

module tb_isp_csiir_line_buffer_max_width_ref;

    /*
    TB_CONTRACT
    - module_name: isp_csiir_line_buffer
    - boundary_id: max_width_runtime_contract
    - compare_object: max-width tail-column clamp, eol rollover, and writeback commit at the last valid address
    - expected_source: directed contract expectations derived from runtime img_width = 5472
    - observed_source: col_p1 / col_p2 / cap_p1 / cap_p2 / wr_col_ptr / wr_row_ptr / row_cnt / line_mem_x[last]
    - sample_edge: negedge drive, posedge state transition check
    - input_valid_ready_contract: local state updates only on accepted input or explicit eol_fire
    - writeback_contract: lb_wb_en commits exactly one targeted write at the last valid column
    - boundary_conditions: runtime img_width set to maximum supported width 5472
    - pipeline_depth: 1-cycle registered state update for local counters / window-valid path
    - pass_fail_predicate: all max-width directed checks pass with zero mismatches
    */

    localparam MAX_IMG_WIDTH   = 5472;
    localparam DATA_WIDTH      = 10;
    localparam LINE_ADDR_WIDTH = 14;
    localparam CLK_PERIOD      = 10;

    reg                         clk;
    reg                         rst_n;
    reg                         enable;
    reg  [DATA_WIDTH-1:0]       din;
    reg                         din_valid;
    wire                        din_ready;
    reg                         sof;
    reg                         eol;
    reg                         lb_wb_en;
    reg  [DATA_WIDTH-1:0]       lb_wb_data;
    reg  [LINE_ADDR_WIDTH-1:0]  lb_wb_addr;
    reg  [2:0]                  lb_wb_row_offset;
    reg  [LINE_ADDR_WIDTH-1:0]  runtime_img_width;
    reg  [12:0]                 runtime_img_height;
    reg                         window_ready;
    wire                        window_valid;
    wire [LINE_ADDR_WIDTH-1:0]  center_x;
    wire [12:0]                 center_y;

    integer fail_count;

    `define CHECK_EQ_U(TAG, ACT, EXP) \
        if ((ACT) != (EXP)) begin \
            $display("FAIL: %s expected %0d got %0d", TAG, EXP, ACT); \
            fail_count = fail_count + 1; \
        end

    isp_csiir_line_buffer #(
        .IMG_WIDTH       (MAX_IMG_WIDTH),
        .DATA_WIDTH      (DATA_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .enable           (enable),
        .img_width        (runtime_img_width),
        .img_height       (runtime_img_height),
        .din              (din),
        .din_valid        (din_valid),
        .din_ready        (din_ready),
        .sof              (sof),
        .eol              (eol),
        .lb_wb_en         (lb_wb_en),
        .lb_wb_data       (lb_wb_data),
        .lb_wb_addr       (lb_wb_addr),
        .lb_wb_row_offset (lb_wb_row_offset),
        .window_0_0       (),
        .window_0_1       (),
        .window_0_2       (),
        .window_0_3       (),
        .window_0_4       (),
        .window_1_0       (),
        .window_1_1       (),
        .window_1_2       (),
        .window_1_3       (),
        .window_1_4       (),
        .window_2_0       (),
        .window_2_1       (),
        .window_2_2       (),
        .window_2_3       (),
        .window_2_4       (),
        .window_3_0       (),
        .window_3_1       (),
        .window_3_2       (),
        .window_3_3       (),
        .window_3_4       (),
        .window_4_0       (),
        .window_4_1       (),
        .window_4_2       (),
        .window_4_3       (),
        .window_4_4       (),
        .window_valid     (window_valid),
        .window_ready     (window_ready),
        .center_x         (center_x),
        .center_y         (center_y)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    task automatic reset_dut;
        begin
            rst_n             = 1'b0;
            enable            = 1'b0;
            din               = {DATA_WIDTH{1'b0}};
            din_valid         = 1'b0;
            sof               = 1'b0;
            eol               = 1'b0;
            lb_wb_en          = 1'b0;
            lb_wb_data        = {DATA_WIDTH{1'b0}};
            lb_wb_addr        = {LINE_ADDR_WIDTH{1'b0}};
            lb_wb_row_offset  = 3'd0;
            runtime_img_width = LINE_ADDR_WIDTH'(16);
            runtime_img_height = 13'd16;
            window_ready      = 1'b1;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic case_a_max_width_tail_clamp_and_eol;
        localparam [LINE_ADDR_WIDTH-1:0] LAST_COL = LINE_ADDR_WIDTH'(MAX_IMG_WIDTH - 1);
        begin
            $display("CASE A: max-width tail clamp and eol rollover");
            reset_dut();

            runtime_img_width  = LAST_COL + 1'b1;
            runtime_img_height = 13'd8;
            enable             = 1'b1;
            dut.frame_started   = 1'b1;
            dut.wr_row_ptr      = 3'd2;
            dut.wr_col_ptr      = LAST_COL;
            dut.row_cnt         = 13'd3;
            dut.rd_col_ptr      = LAST_COL;
            dut.capture_addr    = LAST_COL;
            #1;

            `CHECK_EQ_U("caseA col_p1 clamp", dut.col_p1, LAST_COL)
            `CHECK_EQ_U("caseA col_p2 clamp", dut.col_p2, LAST_COL)
            `CHECK_EQ_U("caseA cap_p1 clamp", dut.cap_p1, LAST_COL)
            `CHECK_EQ_U("caseA cap_p2 clamp", dut.cap_p2, LAST_COL)

            @(negedge clk);
            eol = 1'b1;
            @(posedge clk);
            @(negedge clk);
            eol = 1'b0;

            `CHECK_EQ_U("caseA wr_col_ptr rollover", dut.wr_col_ptr, {LINE_ADDR_WIDTH{1'b0}})
            `CHECK_EQ_U("caseA wr_row_ptr increment", dut.wr_row_ptr, 3'd3)
            `CHECK_EQ_U("caseA row_cnt increment", dut.row_cnt, 13'd4)
        end
    endtask

    task automatic case_b_max_width_writeback_last_column;
        localparam [LINE_ADDR_WIDTH-1:0] LAST_COL = LINE_ADDR_WIDTH'(MAX_IMG_WIDTH - 1);
        begin
            $display("CASE B: max-width writeback must update last valid column");
            reset_dut();

            runtime_img_width   = LAST_COL + 1'b1;
            runtime_img_height  = 13'd8;
            enable              = 1'b1;
            dut.wr_row_ptr      = 3'd2;
            dut.line_mem_2[LAST_COL]     = 10'd17;
            dut.line_mem_2[LAST_COL - 1] = 10'd23;
            lb_wb_addr          = LAST_COL;
            lb_wb_row_offset    = 3'd0;
            lb_wb_data          = 10'd777;

            @(negedge clk);
            lb_wb_en = 1'b1;
            @(posedge clk);
            @(negedge clk);
            lb_wb_en = 1'b0;

            `CHECK_EQ_U("caseB last column updated", dut.line_mem_2[LAST_COL], 10'd777)
            `CHECK_EQ_U("caseB previous column untouched", dut.line_mem_2[LAST_COL - 1], 10'd23)
        end
    endtask

    initial begin
        fail_count = 0;

        case_a_max_width_tail_clamp_and_eol();
        case_b_max_width_writeback_last_column();

        if (fail_count != 0) begin
            $display("FAIL: line buffer max-width cases (%0d failures)", fail_count);
            $fatal(1);
        end

        $display("PASS: line buffer max-width cases");
        $finish;
    end

endmodule
