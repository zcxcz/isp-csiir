`timescale 1ns/1ps

module tb_stage3_gradient_fusion_ref;

    /*
    TB_CONTRACT
    - module_name: stage3_gradient_fusion
    - boundary_id: stage2_to_stage3
    - compare_object: signed blend outputs plus passthrough metadata at stage3 output, feedback off
    - expected_source: directed reference expectations derived from stable rank / fallback semantics
    - observed_source: blend0_dir_avg / blend1_dir_avg / pixel_x_out / pixel_y_out / avg0_u_out / avg1_u_out / win_size_clip_out / center_pixel_out
    - sample_edge: negedge drive, posedge wait, posedge hold checks during output stall
    - alignment_rule: output compare occurs on stage3_valid && stage3_ready; stalled cycles must hold stage3_valid and payload stable
    - in_valid_ready_contract: stage2 transaction accepted only on stage2_valid && stage2_ready
    - out_valid_ready_contract: stage3 output transfer completes only on stage3_valid && stage3_ready
    - metadata_scope: pixel_x/y, avg0_u_out, avg1_u_out, win_size_clip_out, center_pixel_out
    - boundary_conditions: direction binding, zero-sum fallback, right-neighbor independence, tie-rank stability
    - pipeline_depth: 6
    - max_stall_cycles_policy: 0..pipeline_depth with fixed-seed random output stalls capped at pipeline_depth
    - supported_backpressure_modes: directed output stall and fixed-seed pseudo-random output backpressure
    - trace_schema_version: stage3_ref_v1 (case_mode, stall_cycles)
    - pass_fail_predicate: all directed, backpressure, and replay checks pass with zero mismatches
    */

    localparam DATA_WIDTH      = 10;
    localparam SIGNED_WIDTH    = 11;
    localparam GRAD_WIDTH      = 14;
    localparam WIN_SIZE_WIDTH  = 6;
    localparam LINE_ADDR_WIDTH = 14;
    localparam ROW_CNT_WIDTH   = 13;
    localparam BUF_DEPTH       = 8;
    localparam CLK_PERIOD      = 10;
    localparam PIPELINE_DEPTH  = 6;
    localparam MAX_STALL_CYCLES = PIPELINE_DEPTH;
    localparam RANDOM_SEED_RUNS = 3;
    localparam CHECK_MODE_CASE_A = 0;
    localparam CHECK_MODE_CASE_B = 1;
    localparam CHECK_MODE_CASE_C = 2;
    localparam CHECK_MODE_CASE_D = 3;

    reg                             clk;
    reg                             rst_n;
    reg                             enable;
    reg signed [SIGNED_WIDTH-1:0]   avg0_c;
    reg signed [SIGNED_WIDTH-1:0]   avg0_u;
    reg signed [SIGNED_WIDTH-1:0]   avg0_d;
    reg signed [SIGNED_WIDTH-1:0]   avg0_l;
    reg signed [SIGNED_WIDTH-1:0]   avg0_r;
    reg signed [SIGNED_WIDTH-1:0]   avg1_c;
    reg signed [SIGNED_WIDTH-1:0]   avg1_u;
    reg signed [SIGNED_WIDTH-1:0]   avg1_d;
    reg signed [SIGNED_WIDTH-1:0]   avg1_l;
    reg signed [SIGNED_WIDTH-1:0]   avg1_r;
    reg                             stage2_valid;
    reg  [GRAD_WIDTH-1:0]           grad;
    reg  [WIN_SIZE_WIDTH-1:0]       win_size_clip;
    reg  [DATA_WIDTH-1:0]           center_pixel;
    wire                            stage2_ready;
    reg  [ROW_CNT_WIDTH-1:0]        img_height;
    reg  [LINE_ADDR_WIDTH-1:0]      img_width;
    wire signed [SIGNED_WIDTH-1:0]  blend0_dir_avg;
    wire signed [SIGNED_WIDTH-1:0]  blend1_dir_avg;
    wire                            stage3_valid;
    reg                             stage3_ready;
    reg  [LINE_ADDR_WIDTH-1:0]      pixel_x;
    reg  [ROW_CNT_WIDTH-1:0]        pixel_y;
    wire [LINE_ADDR_WIDTH-1:0]      pixel_x_out;
    wire [ROW_CNT_WIDTH-1:0]        pixel_y_out;
    wire signed [SIGNED_WIDTH-1:0]  avg0_u_out;
    wire signed [SIGNED_WIDTH-1:0]  avg1_u_out;
    wire [WIN_SIZE_WIDTH-1:0]       win_size_clip_out;
    wire [DATA_WIDTH-1:0]           center_pixel_out;

    integer fail_count;
    integer random_seed_table [0:RANDOM_SEED_RUNS-1];
    integer trace_txn_fd;
    integer replay_txn_fd;

    `define CHECK_EQ_S(TAG, ACT, EXP) \
        if ($signed(ACT) != $signed(EXP)) begin \
            $display("FAIL: %s expected %0d got %0d", TAG, $signed(EXP), $signed(ACT)); \
            fail_count = fail_count + 1; \
        end

    `define CHECK_EQ_U(TAG, ACT, EXP) \
        if ((ACT) != (EXP)) begin \
            $display("FAIL: %s expected %0d got %0d", TAG, EXP, ACT); \
            fail_count = fail_count + 1; \
        end

    stage3_gradient_fusion #(
        .DATA_WIDTH      (DATA_WIDTH),
        .SIGNED_WIDTH    (SIGNED_WIDTH),
        .GRAD_WIDTH      (GRAD_WIDTH),
        .WIN_SIZE_WIDTH  (WIN_SIZE_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH),
        .ROW_CNT_WIDTH   (ROW_CNT_WIDTH),
        .IMG_WIDTH       (BUF_DEPTH)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .enable          (enable),
        .avg0_c          (avg0_c),
        .avg0_u          (avg0_u),
        .avg0_d          (avg0_d),
        .avg0_l          (avg0_l),
        .avg0_r          (avg0_r),
        .avg1_c          (avg1_c),
        .avg1_u          (avg1_u),
        .avg1_d          (avg1_d),
        .avg1_l          (avg1_l),
        .avg1_r          (avg1_r),
        .stage2_valid    (stage2_valid),
        .grad            (grad),
        .win_size_clip   (win_size_clip),
        .center_pixel    (center_pixel),
        .stage2_ready    (stage2_ready),
        .img_height      (img_height),
        .img_width       (img_width),
        .blend0_dir_avg  (blend0_dir_avg),
        .blend1_dir_avg  (blend1_dir_avg),
        .stage3_valid    (stage3_valid),
        .stage3_ready    (stage3_ready),
        .pixel_x         (pixel_x),
        .pixel_y         (pixel_y),
        .pixel_x_out     (pixel_x_out),
        .pixel_y_out     (pixel_y_out),
        .avg0_u_out      (avg0_u_out),
        .avg1_u_out      (avg1_u_out),
        .win_size_clip_out(win_size_clip_out),
        .center_pixel_out(center_pixel_out)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    initial begin
        random_seed_table[0] = 32'h0000_61a5;
        random_seed_table[1] = 32'h0000_72b6;
        random_seed_table[2] = 32'h0000_83c7;
    end

    task automatic set_defaults;
        begin
            enable        = 1'b1;
            avg0_c        = {SIGNED_WIDTH{1'b0}};
            avg0_u        = {SIGNED_WIDTH{1'b0}};
            avg0_d        = {SIGNED_WIDTH{1'b0}};
            avg0_l        = {SIGNED_WIDTH{1'b0}};
            avg0_r        = {SIGNED_WIDTH{1'b0}};
            avg1_c        = {SIGNED_WIDTH{1'b0}};
            avg1_u        = {SIGNED_WIDTH{1'b0}};
            avg1_d        = {SIGNED_WIDTH{1'b0}};
            avg1_l        = {SIGNED_WIDTH{1'b0}};
            avg1_r        = {SIGNED_WIDTH{1'b0}};
            stage2_valid  = 1'b0;
            grad          = {GRAD_WIDTH{1'b0}};
            win_size_clip = 6'd24;
            center_pixel  = 10'd512;
            img_width     = 14'd3;
            img_height    = 13'd4;
            stage3_ready  = 1'b1;
            pixel_x       = {LINE_ADDR_WIDTH{1'b0}};
            pixel_y       = {ROW_CNT_WIDTH{1'b0}};
        end
    endtask

    task automatic reset_dut;
        begin
            rst_n = 1'b0;
            stage2_valid = 1'b0;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic clear_internal_state;
        integer i;
        begin
            for (i = 0; i < BUF_DEPTH; i = i + 1) begin
                dut.grad_line_buf_0[i] = {GRAD_WIDTH{1'b0}};
                dut.grad_line_buf_1[i] = {GRAD_WIDTH{1'b0}};
                dut.avg0_c_buf_0[i] = {SIGNED_WIDTH{1'b0}};
                dut.avg0_u_buf_0[i] = {SIGNED_WIDTH{1'b0}};
                dut.avg0_d_buf_0[i] = {SIGNED_WIDTH{1'b0}};
                dut.avg0_l_buf_0[i] = {SIGNED_WIDTH{1'b0}};
                dut.avg0_r_buf_0[i] = {SIGNED_WIDTH{1'b0}};
                dut.avg1_c_buf_0[i] = {SIGNED_WIDTH{1'b0}};
                dut.avg1_u_buf_0[i] = {SIGNED_WIDTH{1'b0}};
                dut.avg1_d_buf_0[i] = {SIGNED_WIDTH{1'b0}};
                dut.avg1_l_buf_0[i] = {SIGNED_WIDTH{1'b0}};
                dut.avg1_r_buf_0[i] = {SIGNED_WIDTH{1'b0}};
                dut.center_buf_0[i] = {DATA_WIDTH{1'b0}};
                dut.win_size_buf_0[i] = {WIN_SIZE_WIDTH{1'b0}};
                dut.pixel_x_buf_0[i] = {LINE_ADDR_WIDTH{1'b0}};
                dut.pixel_y_buf_0[i] = {ROW_CNT_WIDTH{1'b0}};
                dut.valid_buf_0[i] = 1'b0;

                dut.avg0_c_buf_1[i] = {SIGNED_WIDTH{1'b0}};
                dut.avg0_u_buf_1[i] = {SIGNED_WIDTH{1'b0}};
                dut.avg0_d_buf_1[i] = {SIGNED_WIDTH{1'b0}};
                dut.avg0_l_buf_1[i] = {SIGNED_WIDTH{1'b0}};
                dut.avg0_r_buf_1[i] = {SIGNED_WIDTH{1'b0}};
                dut.avg1_c_buf_1[i] = {SIGNED_WIDTH{1'b0}};
                dut.avg1_u_buf_1[i] = {SIGNED_WIDTH{1'b0}};
                dut.avg1_d_buf_1[i] = {SIGNED_WIDTH{1'b0}};
                dut.avg1_l_buf_1[i] = {SIGNED_WIDTH{1'b0}};
                dut.avg1_r_buf_1[i] = {SIGNED_WIDTH{1'b0}};
                dut.center_buf_1[i] = {DATA_WIDTH{1'b0}};
                dut.win_size_buf_1[i] = {WIN_SIZE_WIDTH{1'b0}};
                dut.pixel_x_buf_1[i] = {LINE_ADDR_WIDTH{1'b0}};
                dut.pixel_y_buf_1[i] = {ROW_CNT_WIDTH{1'b0}};
                dut.valid_buf_1[i] = 1'b0;
            end

            dut.row_counter   = {ROW_CNT_WIDTH{1'b0}};
            dut.row_valid     = 1'b0;
            dut.col_counter   = {LINE_ADDR_WIDTH{1'b0}};
            dut.flush_active  = 1'b0;
            dut.flush_counter = {LINE_ADDR_WIDTH{1'b0}};
            dut.flush_done    = 1'b0;
            dut.stage2_valid_d = 1'b0;
            dut.rd_col_d      = {LINE_ADDR_WIDTH{1'b0}};
            dut.row_valid_d   = 1'b0;
            dut.stage2_valid_d2 = 1'b0;
            dut.grad_buf_sel  = 1'b0;
            dut.avg_buf_sel   = 1'b0;
            dut.avg_buf_sel_d = 1'b0;
        end
    endtask

    task automatic configure_read_slot;
        input [LINE_ADDR_WIDTH-1:0] slot_x;
        input [ROW_CNT_WIDTH-1:0]   slot_y;
        input [LINE_ADDR_WIDTH-1:0] runtime_width;
        begin
            img_width  = runtime_width;
            img_height = 13'd4;

            dut.row_counter = slot_y;
            dut.row_valid   = 1'b1;
            dut.col_counter = slot_x;
            dut.flush_active = 1'b0;
            dut.flush_done   = 1'b0;
            dut.grad_buf_sel = 1'b0;
            dut.avg_buf_sel  = 1'b0;
            dut.valid_buf_1[slot_x]   = 1'b1;
            dut.pixel_x_buf_1[slot_x] = slot_x;
            dut.pixel_y_buf_1[slot_x] = slot_y;
            dut.center_buf_1[slot_x]  = 10'd512;
            dut.win_size_buf_1[slot_x] = 6'd24;
        end
    endtask

    task automatic pulse_stage2;
        input [GRAD_WIDTH-1:0] grad_next_row;
        begin
            grad = grad_next_row;
            @(negedge clk);
            stage2_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            stage2_valid = 1'b0;
            grad = {GRAD_WIDTH{1'b0}};
        end
    endtask

    task automatic wait_for_stage3_valid;
        input integer stall_cycles;
        integer cycles;
        reg signed [SIGNED_WIDTH-1:0] hold_blend0;
        reg signed [SIGNED_WIDTH-1:0] hold_blend1;
        reg [LINE_ADDR_WIDTH-1:0]     hold_pixel_x;
        reg [ROW_CNT_WIDTH-1:0]       hold_pixel_y;
        reg signed [SIGNED_WIDTH-1:0] hold_avg0_u;
        reg signed [SIGNED_WIDTH-1:0] hold_avg1_u;
        reg [WIN_SIZE_WIDTH-1:0]      hold_win_size;
        reg [DATA_WIDTH-1:0]          hold_center;
        integer cycle_idx;
        begin
            if (stall_cycles > 0) begin
                @(negedge clk);
                stage3_ready = 1'b0;
            end

            cycles = 0;
            while ((stage3_valid !== 1'b1) && (cycles < 24)) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (stage3_valid !== 1'b1) begin
                $display("FAIL: timeout waiting for stage3_valid");
                $fatal(1);
            end

            if (stall_cycles > 0) begin
                #1;
                hold_blend0  = blend0_dir_avg;
                hold_blend1  = blend1_dir_avg;
                hold_pixel_x = pixel_x_out;
                hold_pixel_y = pixel_y_out;
                hold_avg0_u  = avg0_u_out;
                hold_avg1_u  = avg1_u_out;
                hold_win_size = win_size_clip_out;
                hold_center   = center_pixel_out;

                for (cycle_idx = 0; cycle_idx < stall_cycles; cycle_idx = cycle_idx + 1) begin
                    if (stage3_valid !== 1'b1) begin
                        $display("FAIL: stage3_valid dropped during output stall");
                        fail_count = fail_count + 1;
                    end
                    `CHECK_EQ_U("stall stage2_ready", stage2_ready, 1'b0)
                    `CHECK_EQ_S("stall blend0 hold", blend0_dir_avg, hold_blend0)
                    `CHECK_EQ_S("stall blend1 hold", blend1_dir_avg, hold_blend1)
                    `CHECK_EQ_U("stall pixel_x hold", pixel_x_out, hold_pixel_x)
                    `CHECK_EQ_U("stall pixel_y hold", pixel_y_out, hold_pixel_y)
                    `CHECK_EQ_S("stall avg0_u hold", avg0_u_out, hold_avg0_u)
                    `CHECK_EQ_S("stall avg1_u hold", avg1_u_out, hold_avg1_u)
                    `CHECK_EQ_U("stall win_size hold", win_size_clip_out, hold_win_size)
                    `CHECK_EQ_U("stall center hold", center_pixel_out, hold_center)
                    if (cycle_idx + 1 < stall_cycles) begin
                        @(posedge clk);
                        #1;
                    end
                end

                @(negedge clk);
                stage3_ready = 1'b1;
            end
        end
    endtask

    task automatic case_a_direction_binding;
        input integer stall_cycles;
        begin
            $display("CASE A: direction binding must survive gradient sorting");
            set_defaults();
            reset_dut();
            clear_internal_state();
            configure_read_slot(14'd1, 13'd1, 14'd2);

            dut.grad_line_buf_0[1] = 14'd100;
            dut.grad_line_buf_1[0] = 14'd60;
            dut.grad_line_buf_1[1] = 14'd20;

            dut.avg0_c_buf_1[1] = 11'sd100;
            dut.avg0_u_buf_1[1] = 11'sd200;
            dut.avg0_d_buf_1[1] = -11'sd100;
            dut.avg0_l_buf_1[1] = 11'sd50;
            dut.avg0_r_buf_1[1] = -11'sd50;

            dut.avg1_c_buf_1[1] = -11'sd120;
            dut.avg1_u_buf_1[1] = 11'sd60;
            dut.avg1_d_buf_1[1] = 11'sd180;
            dut.avg1_l_buf_1[1] = -11'sd30;
            dut.avg1_r_buf_1[1] = 11'sd90;

            pulse_stage2(14'd80);

            while (dut.valid_s2 !== 1'b1) @(posedge clk);
            $display("DBG caseA s2 g={%0d,%0d,%0d,%0d,%0d} avg0={%0d,%0d,%0d,%0d,%0d} avg1={%0d,%0d,%0d,%0d,%0d}",
                     dut.g_s2[0], dut.g_s2[1], dut.g_s2[2], dut.g_s2[3], dut.g_s2[4],
                     dut.avg0_s2[0], dut.avg0_s2[1], dut.avg0_s2[2], dut.avg0_s2[3], dut.avg0_s2[4],
                     dut.avg1_s2[0], dut.avg1_s2[1], dut.avg1_s2[2], dut.avg1_s2[3], dut.avg1_s2[4]);
            while (dut.valid_s4 !== 1'b1) @(posedge clk);
            $display("DBG caseA s4 blend_sum={%0d,%0d} grad_sum=%0d", dut.blend0_sum_s4, dut.blend1_sum_s4, dut.grad_sum_s4);
            while (dut.div_valid !== 1'b1) @(posedge clk);
            $display("DBG caseA div quot={%0d,%0d}", dut.blend0_quot, dut.blend1_quot);

            wait_for_stage3_valid(stall_cycles);

            `CHECK_EQ_U("caseA pixel_x", pixel_x_out, 14'd1)
            `CHECK_EQ_U("caseA pixel_y", pixel_y_out, 13'd1)
            `CHECK_EQ_S("caseA avg0_u passthrough", avg0_u_out, 11'sd200)
            `CHECK_EQ_S("caseA avg1_u passthrough", avg1_u_out, 11'sd60)
            `CHECK_EQ_S("caseA blend0", blend0_dir_avg, 11'sd37)
            `CHECK_EQ_S("caseA blend1", blend1_dir_avg, -11'sd2)

            @(posedge clk);
        end
    endtask

    task automatic case_b_zero_sum_fallback;
        input integer stall_cycles;
        begin
            $display("CASE B: grad_sum==0 must use rounded 5-way average");
            set_defaults();
            reset_dut();
            clear_internal_state();
            configure_read_slot(14'd0, 13'd1, 14'd1);

            dut.grad_line_buf_0[0] = 14'd0;
            dut.grad_line_buf_1[0] = 14'd0;

            dut.avg0_c_buf_1[0] = -11'sd8;
            dut.avg0_u_buf_1[0] = -11'sd8;
            dut.avg0_d_buf_1[0] = -11'sd8;
            dut.avg0_l_buf_1[0] = -11'sd8;
            dut.avg0_r_buf_1[0] = -11'sd8;

            dut.avg1_c_buf_1[0] = -11'sd8;
            dut.avg1_u_buf_1[0] = -11'sd8;
            dut.avg1_d_buf_1[0] = -11'sd8;
            dut.avg1_l_buf_1[0] = -11'sd8;
            dut.avg1_r_buf_1[0] = -11'sd8;

            pulse_stage2(14'd0);

            while (dut.valid_s2 !== 1'b1) @(posedge clk);
            $display("DBG caseB avg_sum={%0d,%0d} avg_avg={%0d,%0d}", dut.avg0_sum_s2, dut.avg1_sum_s2, dut.avg0_avg_s2, dut.avg1_avg_s2);
            while (dut.div_valid !== 1'b1) @(posedge clk);
            $display("DBG caseB s5 grad_sum=%0d fallback={%0d,%0d}", dut.grad_sum_s5, dut.avg0_avg_s5, dut.avg1_avg_s5);

            wait_for_stage3_valid(stall_cycles);

            `CHECK_EQ_U("caseB pixel_x", pixel_x_out, 14'd0)
            `CHECK_EQ_U("caseB pixel_y", pixel_y_out, 13'd1)
            `CHECK_EQ_S("caseB blend0", blend0_dir_avg, -11'sd8)
            `CHECK_EQ_S("caseB blend1", blend1_dir_avg, -11'sd8)

            @(posedge clk);
        end
    endtask

    task automatic case_c_grad_r_independence;
        input integer stall_cycles;
        begin
            $display("CASE C: grad_r must come from true right neighbor");
            set_defaults();
            reset_dut();
            clear_internal_state();
            configure_read_slot(14'd1, 13'd1, 14'd4);

            dut.grad_line_buf_0[1] = 14'd10;
            dut.grad_line_buf_1[0] = 14'd10;
            dut.grad_line_buf_1[1] = 14'd10;
            dut.grad_line_buf_1[3] = 14'd100;

            dut.avg0_c_buf_1[1] = 11'sd0;
            dut.avg0_u_buf_1[1] = 11'sd0;
            dut.avg0_d_buf_1[1] = 11'sd0;
            dut.avg0_l_buf_1[1] = 11'sd0;
            dut.avg0_r_buf_1[1] = 11'sd100;

            dut.avg1_c_buf_1[1] = 11'sd0;
            dut.avg1_u_buf_1[1] = 11'sd0;
            dut.avg1_d_buf_1[1] = 11'sd0;
            dut.avg1_l_buf_1[1] = 11'sd0;
            dut.avg1_r_buf_1[1] = -11'sd100;

            pulse_stage2(14'd10);

            while (dut.valid_s0 !== 1'b1) @(posedge clk);
            $display("DBG caseC s0 grads={c:%0d u:%0d d:%0d l:%0d r:%0d} avg0={c:%0d u:%0d d:%0d l:%0d r:%0d} avg1={c:%0d u:%0d d:%0d l:%0d r:%0d}",
                     dut.grad_c_s0, dut.grad_u_s0, dut.grad_d_s0, dut.grad_l_s0, dut.grad_r_s0,
                     dut.avg0_c_s0, dut.avg0_u_s0, dut.avg0_d_s0, dut.avg0_l_s0, dut.avg0_r_s0,
                     dut.avg1_c_s0, dut.avg1_u_s0, dut.avg1_d_s0, dut.avg1_l_s0, dut.avg1_r_s0);

            while (dut.valid_s2 !== 1'b1) @(posedge clk);
            $display("DBG caseC s2 g={%0d,%0d,%0d,%0d,%0d} avg0={%0d,%0d,%0d,%0d,%0d} avg1={%0d,%0d,%0d,%0d,%0d} avg0_avg=%0d avg1_avg=%0d",
                     dut.g_s2[0], dut.g_s2[1], dut.g_s2[2], dut.g_s2[3], dut.g_s2[4],
                     dut.avg0_s2[0], dut.avg0_s2[1], dut.avg0_s2[2], dut.avg0_s2[3], dut.avg0_s2[4],
                     dut.avg1_s2[0], dut.avg1_s2[1], dut.avg1_s2[2], dut.avg1_s2[3], dut.avg1_s2[4],
                     dut.avg0_avg_s2, dut.avg1_avg_s2);

            while (dut.valid_s4 !== 1'b1) @(posedge clk);
            $display("DBG caseC s4 blend_sum={%0d,%0d} grad_sum=%0d signs={%0d,%0d} avg_fallback={%0d,%0d}",
                     dut.blend0_sum_s4, dut.blend1_sum_s4, dut.grad_sum_s4,
                     dut.blend0_sign_s4, dut.blend1_sign_s4, dut.avg0_avg_s4, dut.avg1_avg_s4);

            while (dut.div_valid !== 1'b1) @(posedge clk);
            $display("DBG caseC div quot={%0d,%0d} s5 grad_sum=%0d fallback={%0d,%0d}",
                     dut.blend0_quot, dut.blend1_quot, dut.grad_sum_s5, dut.avg0_avg_s5, dut.avg1_avg_s5);

            wait_for_stage3_valid(stall_cycles);
            $display("DBG caseC out blend={%0d,%0d} pixel={%0d,%0d}",
                     blend0_dir_avg, blend1_dir_avg, pixel_x_out, pixel_y_out);

            `CHECK_EQ_U("caseC pixel_x", pixel_x_out, 14'd1)
            `CHECK_EQ_U("caseC pixel_y", pixel_y_out, 13'd1)
            `CHECK_EQ_S("caseC blend0", blend0_dir_avg, 11'sd7)
            `CHECK_EQ_S("caseC blend1", blend1_dir_avg, -11'sd7)

            @(posedge clk);
        end
    endtask

    task automatic case_d_tie_rank_stability;
        input integer stall_cycles;
        begin
            $display("CASE D: equal gradients must preserve stable rank order");
            set_defaults();
            reset_dut();
            clear_internal_state();
            configure_read_slot(14'd1, 13'd1, 14'd4);

            dut.grad_line_buf_0[1] = 14'd10;
            dut.grad_line_buf_1[0] = 14'd7;
            dut.grad_line_buf_1[1] = 14'd1;
            dut.grad_line_buf_1[3] = 14'd5;

            dut.avg0_c_buf_1[1] = 11'sd0;
            dut.avg0_u_buf_1[1] = 11'sd33;
            dut.avg0_d_buf_1[1] = -11'sd33;
            dut.avg0_l_buf_1[1] = 11'sd0;
            dut.avg0_r_buf_1[1] = 11'sd0;

            dut.avg1_c_buf_1[1] = 11'sd0;
            dut.avg1_u_buf_1[1] = 11'sd66;
            dut.avg1_d_buf_1[1] = -11'sd66;
            dut.avg1_l_buf_1[1] = 11'sd0;
            dut.avg1_r_buf_1[1] = 11'sd0;

            pulse_stage2(14'd10);

            while (dut.valid_s2 !== 1'b1) @(posedge clk);
            $display("DBG caseD s2 g={%0d,%0d,%0d,%0d,%0d}",
                     dut.g_s2[0], dut.g_s2[1], dut.g_s2[2], dut.g_s2[3], dut.g_s2[4]);

            `CHECK_EQ_U("caseD g_inv_c", dut.g_s2[0], 14'd10)
            `CHECK_EQ_U("caseD g_inv_u", dut.g_s2[1], 14'd1)
            `CHECK_EQ_U("caseD g_inv_d", dut.g_s2[2], 14'd1)
            `CHECK_EQ_U("caseD g_inv_l", dut.g_s2[3], 14'd10)
            `CHECK_EQ_U("caseD g_inv_r", dut.g_s2[4], 14'd5)

            wait_for_stage3_valid(stall_cycles);
            `CHECK_EQ_U("caseD pixel_x", pixel_x_out, 14'd1)
            `CHECK_EQ_U("caseD pixel_y", pixel_y_out, 13'd1)
            `CHECK_EQ_S("caseD avg0_u passthrough", avg0_u_out, 11'sd33)
            `CHECK_EQ_S("caseD avg1_u passthrough", avg1_u_out, 11'sd66)
            `CHECK_EQ_S("caseD blend0", blend0_dir_avg, 11'sd0)
            `CHECK_EQ_S("caseD blend1", blend1_dir_avg, 11'sd0)

            @(posedge clk);
        end
    endtask

    task automatic case_e_pre_output_backpressure_must_not_drop_transaction;
        begin
            $display("CASE E: pre-output backpressure must not drop pending transaction");
            case_a_direction_binding(PIPELINE_DEPTH);
        end
    endtask

    task automatic case_f_fixed_seed_random_backpressure;
        integer seed_idx;
        integer seed_value;
        integer rand_value;
        integer stall_cycles;
        begin
            $display("CASE F: fixed-seed random output backpressure on stable reference case");
            for (seed_idx = 0; seed_idx < RANDOM_SEED_RUNS; seed_idx = seed_idx + 1) begin
                seed_value = random_seed_table[seed_idx];
                rand_value = $random(seed_value);
                if (rand_value < 0)
                    rand_value = -rand_value;
                stall_cycles = rand_value % (MAX_STALL_CYCLES + 1);
                case_a_direction_binding(stall_cycles);
            end
        end
    endtask

    task automatic open_trace_txn_record;
        begin
            trace_txn_fd = $fopen("verification/stage3_gradient_fusion_txn_trace.txt", "w");
            if (trace_txn_fd == 0) begin
                $display("FAIL: unable to open stage3 trace file for write");
                $fatal(1);
            end
        end
    endtask

    task automatic close_trace_txn_record;
        begin
            if (trace_txn_fd != 0) begin
                $fclose(trace_txn_fd);
                trace_txn_fd = 0;
            end
        end
    endtask

    task automatic record_trace_txn;
        input integer check_mode;
        input integer stall_cycles;
        begin
            $fwrite(trace_txn_fd, "%0d %0d\n", check_mode, stall_cycles);
        end
    endtask

    task automatic replay_trace_txn_file;
        integer scan_count;
        integer check_mode_i;
        integer stall_cycles_i;
        begin
            replay_txn_fd = $fopen("verification/stage3_gradient_fusion_txn_trace.txt", "r");
            if (replay_txn_fd == 0) begin
                $display("FAIL: unable to open stage3 trace file for replay");
                $fatal(1);
            end

            scan_count = $fscanf(replay_txn_fd, "%d %d\n", check_mode_i, stall_cycles_i);
            while (scan_count == 2) begin
                case (check_mode_i)
                    CHECK_MODE_CASE_A: case_a_direction_binding(stall_cycles_i);
                    CHECK_MODE_CASE_B: case_b_zero_sum_fallback(stall_cycles_i);
                    default: begin
                        $display("FAIL: unsupported replay check_mode %0d", check_mode_i);
                        fail_count = fail_count + 1;
                    end
                endcase
                scan_count = $fscanf(replay_txn_fd, "%d %d\n", check_mode_i, stall_cycles_i);
            end

            $fclose(replay_txn_fd);
            replay_txn_fd = 0;
        end
    endtask

    task automatic case_g_trace_record_and_replay;
        begin
            $display("CASE G: transaction trace record and replay");
            open_trace_txn_record();
            record_trace_txn(CHECK_MODE_CASE_A, 2);
            record_trace_txn(CHECK_MODE_CASE_B, 1);
            close_trace_txn_record();
            replay_trace_txn_file();
        end
    endtask

    initial begin
        fail_count = 0;
        trace_txn_fd = 0;
        replay_txn_fd = 0;
        set_defaults();

        case_a_direction_binding(0);
        case_b_zero_sum_fallback(0);
        case_c_grad_r_independence(0);
        case_d_tie_rank_stability(0);
        case_e_pre_output_backpressure_must_not_drop_transaction();
        case_f_fixed_seed_random_backpressure();
        case_g_trace_record_and_replay();

        if (fail_count != 0) begin
            $display("FAIL: stage3 reference cases (%0d failures)", fail_count);
            $fatal(1);
        end

        $display("PASS: stage3 reference cases");
        $finish;
    end

endmodule
