`timescale 1ns/1ps

module tb_stage1_gradient_ref;

    /*
    TB_CONTRACT
    - module_name: stage1_gradient
    - boundary_id: line_buffer_to_stage1
    - compare_object: stage1 gradient outputs, win-size clip, metadata, center pixel, and delayed 5x5 window at stage1 output
    - expected_source: directed reference expectations derived from row/column sums and frozen LUT thresholds
    - observed_source: grad_h / grad_v / grad / win_size_clip / pixel_x_out / pixel_y_out / center_pixel / win_out_*
    - sample_edge: negedge drive, posedge wait, posedge hold checks during pre-output stall
    - alignment_rule: compare on stage1_valid && stage1_ready; pre-output stall must hold pending transaction until ready release
    - in_valid_ready_contract: input transaction accepted only on window_valid && window_ready
    - out_valid_ready_contract: output transaction transfers only on stage1_valid && stage1_ready
    - metadata_scope: pixel_x/y, center_pixel, full delayed 5x5 window
    - boundary_conditions: flat window, row-gradient window, pre-output backpressure, max-width coordinate metadata
    - pipeline_depth: 5
    - max_stall_cycles_policy: 0..pipeline_depth directed stall only in this TB
    - supported_backpressure_modes: directed pre-output stall; fixed-seed random and trace/replay deferred until baseline gate fails
    - trace_schema_version: none in this TB yet
    - pass_fail_predicate: directed semantic cases and pre-output stall case pass without unexplained mismatch
    */

    localparam DATA_WIDTH      = 10;
    localparam GRAD_WIDTH      = 14;
    localparam WIN_SIZE_WIDTH  = 6;
    localparam LINE_ADDR_WIDTH = 14;
    localparam ROW_CNT_WIDTH   = 13;
    localparam CLK_PERIOD      = 10;
    localparam PIPELINE_DEPTH  = 5;
    localparam MAX_PIXEL_X     = 14'd5471;
    localparam MAX_PIXEL_Y     = 13'd3075;

    reg                         clk;
    reg                         rst_n;
    reg                         enable;
    reg  [DATA_WIDTH-1:0]       win [0:4][0:4];
    reg                         window_valid;
    wire                        window_ready;
    reg  [DATA_WIDTH-1:0]       win_size_clip_y_0;
    reg  [DATA_WIDTH-1:0]       win_size_clip_y_1;
    reg  [DATA_WIDTH-1:0]       win_size_clip_y_2;
    reg  [DATA_WIDTH-1:0]       win_size_clip_y_3;
    reg  [7:0]                  win_size_clip_sft_0;
    reg  [7:0]                  win_size_clip_sft_1;
    reg  [7:0]                  win_size_clip_sft_2;
    reg  [7:0]                  win_size_clip_sft_3;
    wire [GRAD_WIDTH-1:0]       grad_h;
    wire [GRAD_WIDTH-1:0]       grad_v;
    wire [GRAD_WIDTH-1:0]       grad;
    wire [WIN_SIZE_WIDTH-1:0]   win_size_clip;
    wire                        stage1_valid;
    reg                         stage1_ready;
    reg  [LINE_ADDR_WIDTH-1:0]  pixel_x;
    reg  [ROW_CNT_WIDTH-1:0]    pixel_y;
    wire [LINE_ADDR_WIDTH-1:0]  pixel_x_out;
    wire [ROW_CNT_WIDTH-1:0]    pixel_y_out;
    wire [DATA_WIDTH-1:0]       center_pixel;
    wire [DATA_WIDTH-1:0]       win_out [0:4][0:4];

    integer fail_count;
    reg [DATA_WIDTH-1:0] exp_win [0:4][0:4];

    `define CHECK_EQ(TAG, ACT, EXP) \
        if ((ACT) !== (EXP)) begin \
            $display("FAIL: %s expected %0d got %0d", TAG, EXP, ACT); \
            fail_count = fail_count + 1; \
        end

    stage1_gradient #(
        .DATA_WIDTH      (DATA_WIDTH),
        .GRAD_WIDTH      (GRAD_WIDTH),
        .WIN_SIZE_WIDTH  (WIN_SIZE_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH),
        .ROW_CNT_WIDTH   (ROW_CNT_WIDTH)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .enable           (enable),
        .window_0_0       (win[0][0]), .window_0_1(win[0][1]), .window_0_2(win[0][2]), .window_0_3(win[0][3]), .window_0_4(win[0][4]),
        .window_1_0       (win[1][0]), .window_1_1(win[1][1]), .window_1_2(win[1][2]), .window_1_3(win[1][3]), .window_1_4(win[1][4]),
        .window_2_0       (win[2][0]), .window_2_1(win[2][1]), .window_2_2(win[2][2]), .window_2_3(win[2][3]), .window_2_4(win[2][4]),
        .window_3_0       (win[3][0]), .window_3_1(win[3][1]), .window_3_2(win[3][2]), .window_3_3(win[3][3]), .window_3_4(win[3][4]),
        .window_4_0       (win[4][0]), .window_4_1(win[4][1]), .window_4_2(win[4][2]), .window_4_3(win[4][3]), .window_4_4(win[4][4]),
        .window_valid     (window_valid),
        .window_ready     (window_ready),
        .win_size_clip_y_0(win_size_clip_y_0),
        .win_size_clip_y_1(win_size_clip_y_1),
        .win_size_clip_y_2(win_size_clip_y_2),
        .win_size_clip_y_3(win_size_clip_y_3),
        .win_size_clip_sft_0(win_size_clip_sft_0),
        .win_size_clip_sft_1(win_size_clip_sft_1),
        .win_size_clip_sft_2(win_size_clip_sft_2),
        .win_size_clip_sft_3(win_size_clip_sft_3),
        .grad_h           (grad_h),
        .grad_v           (grad_v),
        .grad             (grad),
        .win_size_clip    (win_size_clip),
        .stage1_valid     (stage1_valid),
        .stage1_ready     (stage1_ready),
        .pixel_x          (pixel_x),
        .pixel_y          (pixel_y),
        .pixel_x_out      (pixel_x_out),
        .pixel_y_out      (pixel_y_out),
        .center_pixel     (center_pixel),
        .win_out_0_0      (win_out[0][0]), .win_out_0_1(win_out[0][1]), .win_out_0_2(win_out[0][2]), .win_out_0_3(win_out[0][3]), .win_out_0_4(win_out[0][4]),
        .win_out_1_0      (win_out[1][0]), .win_out_1_1(win_out[1][1]), .win_out_1_2(win_out[1][2]), .win_out_1_3(win_out[1][3]), .win_out_1_4(win_out[1][4]),
        .win_out_2_0      (win_out[2][0]), .win_out_2_1(win_out[2][1]), .win_out_2_2(win_out[2][2]), .win_out_2_3(win_out[2][3]), .win_out_2_4(win_out[2][4]),
        .win_out_3_0      (win_out[3][0]), .win_out_3_1(win_out[3][1]), .win_out_3_2(win_out[3][2]), .win_out_3_3(win_out[3][3]), .win_out_3_4(win_out[3][4]),
        .win_out_4_0      (win_out[4][0]), .win_out_4_1(win_out[4][1]), .win_out_4_2(win_out[4][2]), .win_out_4_3(win_out[4][3]), .win_out_4_4(win_out[4][4])
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    function automatic [GRAD_WIDTH-1:0] calc_grad_sum;
        input integer grad_h_abs_i;
        input integer grad_v_abs_i;
        integer grad_full_i;
        integer grad_round_i;
        begin
            grad_full_i = (grad_h_abs_i + grad_v_abs_i) * 205;
            grad_round_i = (grad_full_i >> 10) + ((grad_full_i >> 9) & 1);
            if (grad_round_i > ((1 << GRAD_WIDTH) - 1))
                calc_grad_sum = {GRAD_WIDTH{1'b1}};
            else
                calc_grad_sum = grad_round_i[GRAD_WIDTH-1:0];
        end
    endfunction

    function automatic integer calc_lut_node;
        input integer sft_i;
        begin
            calc_lut_node = 1 << sft_i;
        end
    endfunction

    function automatic [WIN_SIZE_WIDTH-1:0] calc_clip;
        input integer grad_max_i;
        integer x0;
        integer x1;
        integer x2;
        integer x3;
        integer win_size_grad_i;
        begin
            x0 = calc_lut_node(win_size_clip_sft_0);
            x1 = x0 + calc_lut_node(win_size_clip_sft_1);
            x2 = x1 + calc_lut_node(win_size_clip_sft_2);
            x3 = x2 + calc_lut_node(win_size_clip_sft_3);

            if (grad_max_i <= x0)
                win_size_grad_i = win_size_clip_y_0;
            else if (grad_max_i >= x3)
                win_size_grad_i = win_size_clip_y_3;
            else if (grad_max_i <= x1)
                win_size_grad_i = win_size_clip_y_0 + (((grad_max_i - x0) * (win_size_clip_y_1 - win_size_clip_y_0)) + ((x1 - x0) / 2)) / (x1 - x0);
            else if (grad_max_i <= x2)
                win_size_grad_i = win_size_clip_y_1 + (((grad_max_i - x1) * (win_size_clip_y_2 - win_size_clip_y_1)) + ((x2 - x1) / 2)) / (x2 - x1);
            else
                win_size_grad_i = win_size_clip_y_2 + (((grad_max_i - x2) * (win_size_clip_y_3 - win_size_clip_y_2)) + ((x3 - x2) / 2)) / (x3 - x2);

            if (win_size_grad_i < 16)
                calc_clip = 6'd16;
            else if (win_size_grad_i > 40)
                calc_clip = 6'd40;
            else
                calc_clip = win_size_grad_i[WIN_SIZE_WIDTH-1:0];
        end
    endfunction

    task automatic set_defaults;
        integer r;
        integer c;
        begin
            enable            = 1'b1;
            window_valid      = 1'b0;
            stage1_ready      = 1'b1;
            pixel_x           = {LINE_ADDR_WIDTH{1'b0}};
            pixel_y           = {ROW_CNT_WIDTH{1'b0}};
            win_size_clip_y_0 = 10'd15;
            win_size_clip_y_1 = 10'd23;
            win_size_clip_y_2 = 10'd31;
            win_size_clip_y_3 = 10'd39;
            win_size_clip_sft_0 = 8'd2;
            win_size_clip_sft_1 = 8'd2;
            win_size_clip_sft_2 = 8'd2;
            win_size_clip_sft_3 = 8'd2;
            for (r = 0; r < 5; r = r + 1)
                for (c = 0; c < 5; c = c + 1) begin
                    win[r][c] = {DATA_WIDTH{1'b0}};
                    exp_win[r][c] = {DATA_WIDTH{1'b0}};
                end
        end
    endtask

    task automatic reset_dut;
        begin
            rst_n = 1'b0;
            window_valid = 1'b0;
            stage1_ready = 1'b1;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic snapshot_expected_window;
        integer r;
        integer c;
        begin
            for (r = 0; r < 5; r = r + 1)
                for (c = 0; c < 5; c = c + 1)
                    exp_win[r][c] = win[r][c];
        end
    endtask

    task automatic fill_constant_window;
        input [DATA_WIDTH-1:0] value;
        integer r;
        integer c;
        begin
            for (r = 0; r < 5; r = r + 1)
                for (c = 0; c < 5; c = c + 1)
                    win[r][c] = value;
            snapshot_expected_window();
        end
    endtask

    task automatic fill_row_window;
        input [DATA_WIDTH-1:0] row0_v;
        input [DATA_WIDTH-1:0] row1_v;
        input [DATA_WIDTH-1:0] row2_v;
        input [DATA_WIDTH-1:0] row3_v;
        input [DATA_WIDTH-1:0] row4_v;
        integer c;
        begin
            for (c = 0; c < 5; c = c + 1) begin
                win[0][c] = row0_v;
                win[1][c] = row1_v;
                win[2][c] = row2_v;
                win[3][c] = row3_v;
                win[4][c] = row4_v;
            end
            snapshot_expected_window();
        end
    endtask

    task automatic fill_col_window;
        input [DATA_WIDTH-1:0] col0_v;
        input [DATA_WIDTH-1:0] col1_v;
        input [DATA_WIDTH-1:0] col2_v;
        input [DATA_WIDTH-1:0] col3_v;
        input [DATA_WIDTH-1:0] col4_v;
        integer r;
        begin
            for (r = 0; r < 5; r = r + 1) begin
                win[r][0] = col0_v;
                win[r][1] = col1_v;
                win[r][2] = col2_v;
                win[r][3] = col3_v;
                win[r][4] = col4_v;
            end
            snapshot_expected_window();
        end
    endtask

    task automatic drive_sample;
        input [LINE_ADDR_WIDTH-1:0] sample_x;
        input [ROW_CNT_WIDTH-1:0]   sample_y;
        begin
            pixel_x = sample_x;
            pixel_y = sample_y;
            @(negedge clk);
            window_valid = 1'b1;
            while (window_ready !== 1'b1)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            window_valid = 1'b0;
        end
    endtask

    task automatic wait_for_stage1_valid;
        integer cycles;
        begin
            cycles = 0;
            while ((stage1_valid !== 1'b1) && (cycles < 24)) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (stage1_valid !== 1'b1) begin
                $display("FAIL: timeout waiting for stage1_valid");
                $fatal(1);
            end
        end
    endtask

    task automatic check_window_outputs;
        input [255:0] tag;
        integer r;
        integer c;
        begin
            for (r = 0; r < 5; r = r + 1)
                for (c = 0; c < 5; c = c + 1)
                    if (win_out[r][c] !== exp_win[r][c]) begin
                        $display("FAIL: %s win[%0d][%0d] expected %0d got %0d",
                                 tag, r, c, exp_win[r][c], win_out[r][c]);
                        fail_count = fail_count + 1;
                    end
        end
    endtask

    task automatic check_outputs;
        input [255:0] tag;
        input [GRAD_WIDTH-1:0] exp_grad_h;
        input [GRAD_WIDTH-1:0] exp_grad_v;
        input [GRAD_WIDTH-1:0] exp_grad;
        input [WIN_SIZE_WIDTH-1:0] exp_clip;
        input [LINE_ADDR_WIDTH-1:0] exp_x;
        input [ROW_CNT_WIDTH-1:0] exp_y;
        input [DATA_WIDTH-1:0] exp_center;
        begin
            `CHECK_EQ(tag, grad_h, exp_grad_h)
            `CHECK_EQ(tag, grad_v, exp_grad_v)
            `CHECK_EQ(tag, grad, exp_grad)
            `CHECK_EQ(tag, win_size_clip, exp_clip)
            `CHECK_EQ(tag, pixel_x_out, exp_x)
            `CHECK_EQ(tag, pixel_y_out, exp_y)
            `CHECK_EQ(tag, center_pixel, exp_center)
            check_window_outputs(tag);
        end
    endtask

    task automatic case_a_flat_window;
        reg [GRAD_WIDTH-1:0] exp_grad_local;
        begin
            $display("CASE A: flat window should produce zero gradient and aligned metadata");
            set_defaults();
            fill_constant_window(10'd100);
            reset_dut();
            drive_sample(14'd3, 13'd5);
            wait_for_stage1_valid();
            exp_grad_local = calc_grad_sum(0, 0);
            check_outputs("caseA", 0, 0, exp_grad_local, calc_clip(exp_grad_local), 14'd3, 13'd5, 10'd100);
            @(posedge clk);
        end
    endtask

    task automatic case_b_row_gradient;
        reg [GRAD_WIDTH-1:0] exp_grad_local;
        begin
            $display("CASE B: row gradient should produce grad_h-only response");
            set_defaults();
            fill_row_window(10'd50, 10'd30, 10'd20, 10'd15, 10'd10);
            reset_dut();
            drive_sample(14'd9, 13'd11);
            wait_for_stage1_valid();
            exp_grad_local = calc_grad_sum(200, 0);
            check_outputs("caseB", 14'd200, 14'd0, exp_grad_local, calc_clip(exp_grad_local), 14'd9, 13'd11, 10'd20);
            @(posedge clk);
        end
    endtask

    task automatic case_c_pre_output_stall;
        integer cycle_idx;
        reg pending_ok;
        reg [GRAD_WIDTH-1:0] exp_grad_local;
        begin
            $display("CASE C: pre-output stall must preserve pending stage1 transaction");
            set_defaults();
            fill_col_window(10'd60, 10'd30, 10'd20, 10'd10, 10'd0);
            reset_dut();
            drive_sample(14'd15, 13'd2);

            repeat (3) @(posedge clk);
            @(negedge clk);
            stage1_ready = 1'b0;
            pending_ok = 1'b1;

            for (cycle_idx = 0; cycle_idx < PIPELINE_DEPTH; cycle_idx = cycle_idx + 1) begin
                @(posedge clk);
                #1;
                if (window_ready !== 1'b0)
                    pending_ok = 1'b0;
                if (dut.valid_s3 !== 1'b1)
                    pending_ok = 1'b0;
                if (stage1_valid !== 1'b0)
                    pending_ok = 1'b0;
            end

            @(negedge clk);
            stage1_ready = 1'b1;
            wait_for_stage1_valid();

            exp_grad_local = calc_grad_sum(0, 300);
            check_outputs("caseC", 14'd0, 14'd300, exp_grad_local, calc_clip(exp_grad_local), 14'd15, 13'd2, 10'd20);

            if (!pending_ok) begin
                $display("FAIL: stage1 pre-output stall contract violated under %0d-cycle stall", PIPELINE_DEPTH);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task automatic case_d_max_width_coordinate_passthrough;
        reg [GRAD_WIDTH-1:0] exp_grad_local;
        begin
            $display("CASE D: max-width coordinate metadata must pass through stage1 intact");
            set_defaults();
            fill_constant_window(10'd321);
            reset_dut();
            drive_sample(MAX_PIXEL_X, MAX_PIXEL_Y);
            wait_for_stage1_valid();

            exp_grad_local = calc_grad_sum(0, 0);
            check_outputs("caseD", 14'd0, 14'd0, exp_grad_local, calc_clip(exp_grad_local),
                          MAX_PIXEL_X, MAX_PIXEL_Y, 10'd321);
            @(posedge clk);
        end
    endtask

    task automatic case_e_lut_interpolation;
        reg [GRAD_WIDTH-1:0] exp_grad_local;
        begin
            $display("CASE E: LUT interpolation must follow clip_y/clip_sft semantics");
            set_defaults();
            fill_row_window(10'd16, 10'd16, 10'd16, 10'd16, 10'd10);
            reset_dut();
            drive_sample(14'd21, 13'd7);
            wait_for_stage1_valid();

            exp_grad_local = calc_grad_sum(30, 0);
            check_outputs("caseE", 14'd30, 14'd0, exp_grad_local, calc_clip(exp_grad_local), 14'd21, 13'd7, 10'd16);
            @(posedge clk);
        end
    endtask

    initial begin
        fail_count = 0;
        set_defaults();

        case_a_flat_window();
        case_b_row_gradient();
        case_c_pre_output_stall();
        case_d_max_width_coordinate_passthrough();
        case_e_lut_interpolation();

        if (fail_count != 0) begin
            $display("FAIL: stage1 reference cases (%0d failures)", fail_count);
            $fatal(1);
        end

        $display("PASS: stage1 reference cases");
        $finish;
    end

endmodule
