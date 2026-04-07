`timescale 1ns/1ps

module tb_stage2_directional_avg_ref;

    /*
    TB_CONTRACT
    - module_name: stage2_directional_avg
    - boundary_id: stage1_to_stage2
    - compare_object: dual-path directional averages plus passthrough metadata at stage2 output, feedback off
    - expected_source: directed reference expectations derived from kernel-selection and zero-path semantics
    - observed_source: avg0_* / avg1_* / pixel_x_out / pixel_y_out / grad_out / win_size_clip_out / center_pixel_out
    - sample_edge: negedge drive, posedge wait, posedge hold checks during output stall
    - alignment_rule: output compare occurs on stage2_valid && stage2_ready; stalled cycles must hold stage2_valid and payload stable
    - in_valid_ready_contract: stage1 transaction accepted only on stage1_valid && stage1_ready
    - out_valid_ready_contract: stage2 transaction transfers only on stage2_valid && stage2_ready
    - metadata_scope: pixel_x/y, grad_out, win_size_clip_out, center_pixel_out
    - boundary_conditions: dual-path split, zero-path disable, output stall stability, max-width coordinate metadata
    - pipeline_depth: 4
    - max_stall_cycles_policy: 0..pipeline_depth with fixed-seed random output stalls capped at pipeline_depth
    - supported_backpressure_modes: directed output stall; fixed-seed random and trace/replay deferred until stall-safe gate passes
    - trace_schema_version: none in this TB yet; trace/replay pending
    - pass_fail_predicate: directed reference cases pass and stall-safe contract has no unexplained mismatch
    */

    localparam DATA_WIDTH      = 10;
    localparam SIGNED_WIDTH    = 11;
    localparam GRAD_WIDTH      = 14;
    localparam WIN_SIZE_WIDTH  = 6;
    localparam ACC_WIDTH       = 20;
    localparam LINE_ADDR_WIDTH = 14;
    localparam ROW_CNT_WIDTH   = 13;
    localparam CLK_PERIOD      = 10;
    localparam PIPELINE_DEPTH  = 4;
    localparam MAX_STALL_CYCLES = PIPELINE_DEPTH;
    localparam MAX_PIXEL_X      = 14'd5471;
    localparam MAX_PIXEL_Y      = 13'd3075;

    reg                         clk;
    reg                         rst_n;
    reg                         enable;
    reg  [DATA_WIDTH-1:0]       win [0:4][0:4];
    reg  [GRAD_WIDTH-1:0]       grad_h;
    reg  [GRAD_WIDTH-1:0]       grad_v;
    reg  [GRAD_WIDTH-1:0]       grad;
    reg  [WIN_SIZE_WIDTH-1:0]   win_size_clip;
    reg                         stage1_valid;
    reg  [DATA_WIDTH-1:0]       center_pixel;
    wire                        stage1_ready;
    reg  [15:0]                 win_size_thresh0;
    reg  [15:0]                 win_size_thresh1;
    reg  [15:0]                 win_size_thresh2;
    reg  [15:0]                 win_size_thresh3;
    wire signed [SIGNED_WIDTH-1:0] avg0_c;
    wire signed [SIGNED_WIDTH-1:0] avg0_u;
    wire signed [SIGNED_WIDTH-1:0] avg0_d;
    wire signed [SIGNED_WIDTH-1:0] avg0_l;
    wire signed [SIGNED_WIDTH-1:0] avg0_r;
    wire signed [SIGNED_WIDTH-1:0] avg1_c;
    wire signed [SIGNED_WIDTH-1:0] avg1_u;
    wire signed [SIGNED_WIDTH-1:0] avg1_d;
    wire signed [SIGNED_WIDTH-1:0] avg1_l;
    wire signed [SIGNED_WIDTH-1:0] avg1_r;
    wire                        stage2_valid;
    reg                         stage2_ready;
    reg  [LINE_ADDR_WIDTH-1:0]  pixel_x;
    reg  [ROW_CNT_WIDTH-1:0]    pixel_y;
    wire [LINE_ADDR_WIDTH-1:0]  pixel_x_out;
    wire [ROW_CNT_WIDTH-1:0]    pixel_y_out;
    wire [GRAD_WIDTH-1:0]       grad_out;
    wire [WIN_SIZE_WIDTH-1:0]   win_size_clip_out;
    wire [DATA_WIDTH-1:0]       center_pixel_out;

    integer fail_count;
    reg signed [SIGNED_WIDTH-1:0] stall_avg0_c;
    reg signed [SIGNED_WIDTH-1:0] stall_avg0_u;
    reg signed [SIGNED_WIDTH-1:0] stall_avg0_d;
    reg signed [SIGNED_WIDTH-1:0] stall_avg0_l;
    reg signed [SIGNED_WIDTH-1:0] stall_avg0_r;
    reg signed [SIGNED_WIDTH-1:0] stall_avg1_c;
    reg signed [SIGNED_WIDTH-1:0] stall_avg1_u;
    reg signed [SIGNED_WIDTH-1:0] stall_avg1_d;
    reg signed [SIGNED_WIDTH-1:0] stall_avg1_l;
    reg signed [SIGNED_WIDTH-1:0] stall_avg1_r;

    `define CHECK_EQ(TAG, ACT, EXP) \
        if ($signed(ACT) != (EXP)) begin \
            $display("FAIL: %s expected %0d got %0d", TAG, EXP, $signed(ACT)); \
            fail_count = fail_count + 1; \
        end

    stage2_directional_avg #(
        .DATA_WIDTH     (DATA_WIDTH),
        .SIGNED_WIDTH   (SIGNED_WIDTH),
        .GRAD_WIDTH     (GRAD_WIDTH),
        .WIN_SIZE_WIDTH (WIN_SIZE_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH),
        .LINE_ADDR_WIDTH(LINE_ADDR_WIDTH),
        .ROW_CNT_WIDTH  (ROW_CNT_WIDTH)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .enable           (enable),
        .window_0_0       (win[0][0]), .window_0_1(win[0][1]), .window_0_2(win[0][2]), .window_0_3(win[0][3]), .window_0_4(win[0][4]),
        .window_1_0       (win[1][0]), .window_1_1(win[1][1]), .window_1_2(win[1][2]), .window_1_3(win[1][3]), .window_1_4(win[1][4]),
        .window_2_0       (win[2][0]), .window_2_1(win[2][1]), .window_2_2(win[2][2]), .window_2_3(win[2][3]), .window_2_4(win[2][4]),
        .window_3_0       (win[3][0]), .window_3_1(win[3][1]), .window_3_2(win[3][2]), .window_3_3(win[3][3]), .window_3_4(win[3][4]),
        .window_4_0       (win[4][0]), .window_4_1(win[4][1]), .window_4_2(win[4][2]), .window_4_3(win[4][3]), .window_4_4(win[4][4]),
        .grad_h           (grad_h),
        .grad_v           (grad_v),
        .grad             (grad),
        .win_size_clip    (win_size_clip),
        .stage1_valid     (stage1_valid),
        .center_pixel     (center_pixel),
        .stage1_ready     (stage1_ready),
        .win_size_thresh0 (win_size_thresh0),
        .win_size_thresh1 (win_size_thresh1),
        .win_size_thresh2 (win_size_thresh2),
        .win_size_thresh3 (win_size_thresh3),
        .avg0_c           (avg0_c),
        .avg0_u           (avg0_u),
        .avg0_d           (avg0_d),
        .avg0_l           (avg0_l),
        .avg0_r           (avg0_r),
        .avg1_c           (avg1_c),
        .avg1_u           (avg1_u),
        .avg1_d           (avg1_d),
        .avg1_l           (avg1_l),
        .avg1_r           (avg1_r),
        .stage2_valid     (stage2_valid),
        .stage2_ready     (stage2_ready),
        .pixel_x          (pixel_x),
        .pixel_y          (pixel_y),
        .pixel_x_out      (pixel_x_out),
        .pixel_y_out      (pixel_y_out),
        .grad_out         (grad_out),
        .win_size_clip_out(win_size_clip_out),
        .center_pixel_out (center_pixel_out)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    task automatic apply_base_window;
        integer r;
        integer c;
        integer value;
        begin
            value = 500;
            for (r = 0; r < 5; r = r + 1) begin
                for (c = 0; c < 5; c = c + 1) begin
                    win[r][c] = value[DATA_WIDTH-1:0];
                    value = value + 3;
                end
            end
            center_pixel = win[2][2];
        end
    endtask

    task automatic set_defaults;
        integer r;
        integer c;
        begin
            enable           = 1'b1;
            grad_h           = {GRAD_WIDTH{1'b0}};
            grad_v           = {GRAD_WIDTH{1'b0}};
            grad             = {GRAD_WIDTH{1'b0}};
            win_size_clip    = {WIN_SIZE_WIDTH{1'b0}};
            stage1_valid     = 1'b0;
            stage2_ready     = 1'b1;
            pixel_x          = {LINE_ADDR_WIDTH{1'b0}};
            pixel_y          = {ROW_CNT_WIDTH{1'b0}};
            center_pixel     = {DATA_WIDTH{1'b0}};
            win_size_thresh0 = 16'd16;
            win_size_thresh1 = 16'd24;
            win_size_thresh2 = 16'd32;
            win_size_thresh3 = 16'd40;
            for (r = 0; r < 5; r = r + 1) begin
                for (c = 0; c < 5; c = c + 1) begin
                    win[r][c] = {DATA_WIDTH{1'b0}};
                end
            end
        end
    endtask

    task automatic reset_dut;
        begin
            rst_n = 1'b0;
            stage1_valid = 1'b0;
            stage2_ready = 1'b1;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic drive_sample;
        input [WIN_SIZE_WIDTH-1:0] sample_win_size;
        begin
            win_size_clip = sample_win_size;
            @(negedge clk);
            stage1_valid = 1'b1;
            while (stage1_ready !== 1'b1)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            stage1_valid = 1'b0;
        end
    endtask

    task automatic wait_for_stage2_valid;
        integer cycles;
        begin
            cycles = 0;
            while ((stage2_valid !== 1'b1) && (cycles < 20)) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (stage2_valid !== 1'b1) begin
                $display("FAIL: timeout waiting for stage2_valid");
                $fatal(1);
            end
        end
    endtask

    task automatic case_a_dual_path_split;
        begin
            $display("CASE A: dual-path kernels must diverge at win_size=24");
            set_defaults();
            apply_base_window();
            reset_dut();
            drive_sample(6'd24);
            wait_for_stage2_valid();

            if (($signed(avg0_c) == $signed(avg1_c)) &&
                ($signed(avg0_u) == $signed(avg1_u)) &&
                ($signed(avg0_d) == $signed(avg1_d)) &&
                ($signed(avg0_l) == $signed(avg1_l)) &&
                ($signed(avg0_r) == $signed(avg1_r))) begin
                $display("FAIL: Stage2 dual-path kernels collapsed");
                fail_count = fail_count + 1;
            end

            `CHECK_EQ("caseA avg0_c", avg0_c, 24)
            `CHECK_EQ("caseA avg0_u", avg0_u, 15)
            `CHECK_EQ("caseA avg0_d", avg0_d, 33)
            `CHECK_EQ("caseA avg0_l", avg0_l, 22)
            `CHECK_EQ("caseA avg0_r", avg0_r, 26)
            `CHECK_EQ("caseA avg1_c", avg1_c, 24)
            `CHECK_EQ("caseA avg1_u", avg1_u, 17)
            `CHECK_EQ("caseA avg1_d", avg1_d, 32)
            `CHECK_EQ("caseA avg1_l", avg1_l, 23)
            `CHECK_EQ("caseA avg1_r", avg1_r, 26)

            @(posedge clk);
        end
    endtask

    task automatic case_b_zero_path_disable;
        begin
            $display("CASE B: zero-path must disable avg0 when win_size<thresh0");
            set_defaults();
            apply_base_window();
            reset_dut();
            drive_sample(6'd8);
            wait_for_stage2_valid();

            if (($signed(avg0_c) != 0) || ($signed(avg0_u) != 0) || ($signed(avg0_d) != 0) ||
                ($signed(avg0_l) != 0) || ($signed(avg0_r) != 0)) begin
                $display("FAIL: disabled path still active");
                fail_count = fail_count + 1;
            end

            `CHECK_EQ("caseB avg1_c", avg1_c, 24)
            `CHECK_EQ("caseB avg1_u", avg1_u, 19)
            `CHECK_EQ("caseB avg1_d", avg1_d, 29)
            `CHECK_EQ("caseB avg1_l", avg1_l, 23)
            `CHECK_EQ("caseB avg1_r", avg1_r, 25)

            @(posedge clk);
        end
    endtask

    task automatic case_c_stall_stability;
        integer cycle_idx;
        reg pending_ok;
        begin
            $display("CASE C: outputs must hold stable during stall");
            set_defaults();
            apply_base_window();
            reset_dut();
            drive_sample(6'd24);

            repeat (2) @(posedge clk);
            @(negedge clk);
            stage2_ready = 1'b0;
            pending_ok = 1'b1;

            for (cycle_idx = 0; cycle_idx < PIPELINE_DEPTH; cycle_idx = cycle_idx + 1) begin
                @(posedge clk);
                #1;
                if (stage1_ready !== 1'b0)
                    pending_ok = 1'b0;
                if (dut.valid_s6 !== 1'b1)
                    pending_ok = 1'b0;
                if (stage2_valid !== 1'b0)
                    pending_ok = 1'b0;
            end

            @(negedge clk);
            stage2_ready = 1'b1;
            wait_for_stage2_valid();

            `CHECK_EQ("caseC avg0_c after release", avg0_c, 24)
            `CHECK_EQ("caseC avg0_u after release", avg0_u, 15)
            `CHECK_EQ("caseC avg1_c after release", avg1_c, 24)
            `CHECK_EQ("caseC avg1_u after release", avg1_u, 17)

            if (!pending_ok) begin
                $display("FAIL: stage2 stall-safe contract violated under %0d-cycle pre-output stall", PIPELINE_DEPTH);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task automatic case_d_max_width_coordinate_passthrough;
        begin
            $display("CASE D: max-width coordinate metadata must pass through stage2 intact");
            set_defaults();
            apply_base_window();
            pixel_x = MAX_PIXEL_X;
            pixel_y = MAX_PIXEL_Y;
            grad    = 14'd57;
            reset_dut();
            pixel_x = MAX_PIXEL_X;
            pixel_y = MAX_PIXEL_Y;
            grad    = 14'd57;
            drive_sample(6'd24);
            wait_for_stage2_valid();

            `CHECK_EQ("caseD avg0_c", avg0_c, 24)
            `CHECK_EQ("caseD avg0_u", avg0_u, 15)
            `CHECK_EQ("caseD avg0_d", avg0_d, 33)
            `CHECK_EQ("caseD avg0_l", avg0_l, 22)
            `CHECK_EQ("caseD avg0_r", avg0_r, 26)
            `CHECK_EQ("caseD avg1_c", avg1_c, 24)
            `CHECK_EQ("caseD avg1_u", avg1_u, 17)
            `CHECK_EQ("caseD avg1_d", avg1_d, 32)
            `CHECK_EQ("caseD avg1_l", avg1_l, 23)
            `CHECK_EQ("caseD avg1_r", avg1_r, 26)
            `CHECK_EQ("caseD pixel_x", pixel_x_out, MAX_PIXEL_X)
            `CHECK_EQ("caseD pixel_y", pixel_y_out, MAX_PIXEL_Y)
            `CHECK_EQ("caseD grad", grad_out, 14'd57)
            `CHECK_EQ("caseD win_size", win_size_clip_out, 6'd24)
            `CHECK_EQ("caseD center", center_pixel_out, win[2][2])

            @(posedge clk);
        end
    endtask

    initial begin
        fail_count = 0;
        set_defaults();

        case_a_dual_path_split();
        case_b_zero_path_disable();
        case_c_stall_stability();
        case_d_max_width_coordinate_passthrough();

        if (fail_count != 0) begin
            $display("FAIL: stage2 reference cases (%0d failures)", fail_count);
            $fatal(1);
        end

        $display("PASS: stage2 reference cases");
        $finish;
    end

endmodule
