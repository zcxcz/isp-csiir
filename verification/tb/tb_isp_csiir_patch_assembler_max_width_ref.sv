`timescale 1ns/1ps

module tb_isp_csiir_patch_assembler_max_width_ref;

    /*
    TB_CONTRACT
    - module_name: isp_csiir_patch_assembler_5x5
    - boundary_id: max_width_runtime_contract
    - compare_object: max-width left/right clip patch assembly at runtime img_width = 5472
    - expected_source: directed contract expectations from cached 5x1 columns
    - observed_source: patch_5x5 / patch_center_x / patch_center_y / window_valid
    - sample_edge: posedge
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
    reg  [DATA_WIDTH-1:0]       col_0;
    reg  [DATA_WIDTH-1:0]       col_1;
    reg  [DATA_WIDTH-1:0]       col_2;
    reg  [DATA_WIDTH-1:0]       col_3;
    reg  [DATA_WIDTH-1:0]       col_4;
    reg                         column_valid;
    wire                        column_ready;
    reg  [LINE_ADDR_WIDTH-1:0]  center_x;
    reg  [12:0]                 center_y;
    wire                        window_valid;
    reg                         window_ready;
    wire [LINE_ADDR_WIDTH-1:0]  patch_center_x;
    wire [12:0]                 patch_center_y;
    wire [DATA_WIDTH*25-1:0]    patch_5x5;

    integer fail_count;

    `define CHECK_EQ_U(TAG, ACT, EXP) \
        if ((ACT) != (EXP)) begin \
            $display("FAIL: %s expected %0d got %0d", TAG, EXP, ACT); \
            fail_count = fail_count + 1; \
        end

    function automatic [DATA_WIDTH-1:0] patch_cell;
        input integer row;
        input integer col;
        integer lsb;
        begin
            lsb = ((row * 5) + col) * DATA_WIDTH;
            patch_cell = patch_5x5[lsb +: DATA_WIDTH];
        end
    endfunction

    isp_csiir_patch_assembler_5x5 #(
        .IMG_WIDTH       (MAX_IMG_WIDTH),
        .DATA_WIDTH      (DATA_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH)
    ) dut (
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
        .center_x        (center_x),
        .center_y        (center_y),
        .window_0_0      (), .window_0_1(), .window_0_2(), .window_0_3(), .window_0_4(),
        .window_1_0      (), .window_1_1(), .window_1_2(), .window_1_3(), .window_1_4(),
        .window_2_0      (), .window_2_1(), .window_2_2(), .window_2_3(), .window_2_4(),
        .window_3_0      (), .window_3_1(), .window_3_2(), .window_3_3(), .window_3_4(),
        .window_4_0      (), .window_4_1(), .window_4_2(), .window_4_3(), .window_4_4(),
        .window_valid    (window_valid),
        .window_ready    (window_ready),
        .patch_center_x  (patch_center_x),
        .patch_center_y  (patch_center_y),
        .patch_5x5       (patch_5x5)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    task automatic reset_dut;
        begin
            rst_n        = 1'b0;
            enable       = 1'b0;
            img_width    = MAX_IMG_WIDTH[LINE_ADDR_WIDTH-1:0];
            col_0        = 0;
            col_1        = 0;
            col_2        = 0;
            col_3        = 0;
            col_4        = 0;
            column_valid = 1'b0;
            center_x     = 0;
            center_y     = 0;
            window_ready = 1'b1;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            enable = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic case_a_right_clip_flush;
        begin
            $display("CASE A: right clip at max width");
            reset_dut();

            dut.row_mem_0[LAST_COL-4] = 10'd100;
            dut.row_mem_1[LAST_COL-4] = 10'd110;
            dut.row_mem_2[LAST_COL-4] = 10'd120;
            dut.row_mem_3[LAST_COL-4] = 10'd130;
            dut.row_mem_4[LAST_COL-4] = 10'd140;

            dut.row_mem_0[LAST_COL-2] = 10'd200;
            dut.row_mem_1[LAST_COL-2] = 10'd210;
            dut.row_mem_2[LAST_COL-2] = 10'd220;
            dut.row_mem_3[LAST_COL-2] = 10'd230;
            dut.row_mem_4[LAST_COL-2] = 10'd240;

            dut.row_mem_0[LAST_COL] = 10'd300;
            dut.row_mem_1[LAST_COL] = 10'd310;
            dut.row_mem_2[LAST_COL] = 10'd320;
            dut.row_mem_3[LAST_COL] = 10'd330;
            dut.row_mem_4[LAST_COL] = 10'd340;

            dut.flush_active    = 1'b1;
            dut.flush_remaining = 3'd1;
            dut.flush_center_x  = LAST_COL[LINE_ADDR_WIDTH-1:0];
            dut.flush_center_y  = 13'd7;

            @(posedge clk);

            `CHECK_EQ_U("caseA patch center x", patch_center_x, LAST_COL)
            `CHECK_EQ_U("caseA patch center y", patch_center_y, 13'd7)
            `CHECK_EQ_U("caseA row2 col0", patch_cell(2, 0), 10'd120)
            `CHECK_EQ_U("caseA row2 col1", patch_cell(2, 1), 10'd220)
            `CHECK_EQ_U("caseA row2 col2", patch_cell(2, 2), 10'd320)
            `CHECK_EQ_U("caseA row2 col3", patch_cell(2, 3), 10'd320)
            `CHECK_EQ_U("caseA row2 col4", patch_cell(2, 4), 10'd320)
        end
    endtask

    task automatic case_b_left_clip_direct_emit;
        begin
            $display("CASE B: left clip at max width");
            reset_dut();

            dut.row_mem_0[0] = 10'd11;  dut.row_mem_1[0] = 10'd21;  dut.row_mem_2[0] = 10'd31;  dut.row_mem_3[0] = 10'd41;  dut.row_mem_4[0] = 10'd51;
            dut.row_mem_0[2] = 10'd12;  dut.row_mem_1[2] = 10'd22;  dut.row_mem_2[2] = 10'd32;  dut.row_mem_3[2] = 10'd42;  dut.row_mem_4[2] = 10'd52;
            dut.row_mem_0[4] = 10'd13;  dut.row_mem_1[4] = 10'd23;  dut.row_mem_2[4] = 10'd33;  dut.row_mem_3[4] = 10'd43;  dut.row_mem_4[4] = 10'd53;

            @(negedge clk);
            center_x     = 14'd4;
            center_y     = 13'd5;
            col_0        = 10'd13;
            col_1        = 10'd23;
            col_2        = 10'd33;
            col_3        = 10'd43;
            col_4        = 10'd53;
            column_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            column_valid = 1'b0;

            `CHECK_EQ_U("caseB patch center x", patch_center_x, 14'd0)
            `CHECK_EQ_U("caseB patch center y", patch_center_y, 13'd5)
            `CHECK_EQ_U("caseB row2 col0", patch_cell(2, 0), 10'd31)
            `CHECK_EQ_U("caseB row2 col1", patch_cell(2, 1), 10'd31)
            `CHECK_EQ_U("caseB row2 col2", patch_cell(2, 2), 10'd31)
            `CHECK_EQ_U("caseB row2 col3", patch_cell(2, 3), 10'd32)
            `CHECK_EQ_U("caseB row2 col4", patch_cell(2, 4), 10'd33)
        end
    endtask

    initial begin
        fail_count = 0;

        case_a_right_clip_flush();
        case_b_left_clip_direct_emit();

        if (fail_count != 0) begin
            $display("FAIL: patch_assembler max-width cases (%0d failures)", fail_count);
            $fatal(1);
        end

        $display("PASS: patch_assembler max-width cases");
        $finish;
    end

endmodule
