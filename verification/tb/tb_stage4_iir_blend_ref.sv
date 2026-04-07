`timescale 1ns/1ps

module tb_stage4_iir_blend_ref;

    /*
    TB_CONTRACT
    - module_name: stage4_iir_blend
    - boundary_id: stage3_to_stage4
    - compare_object: atomic stream output + patch-center semantics, feedback on
    - expected_source: fixed reference values derived from stage4 reference semantics cases
    - observed_source: dout / patch_5x5 / pixel_x_out / pixel_y_out / patch_center_x / patch_center_y / lb_wb_en / lb_wb_addr
    - sample_edge: negedge drive, negedge wait_for_outputs, posedge hold checks
    - alignment_rule: valid-ready aligned atomic output; dout_valid and patch_valid must rise together
    - in_valid_ready_contract: stage3_valid accepted when stage3_ready is high
    - out_valid_ready_contract: dout_valid and patch_valid are atomic; output transfer completes only when dout_ready && patch_ready
    - metadata_scope: win_size_clip, pixel_x/y passthrough, patch center coordinates
    - boundary_conditions: include ordinary interior coordinates, boundary coordinate (0,0), and max-width coordinate writeback
    - pipeline_depth: 5
    - max_stall_cycles_policy: 0..pipeline_depth derived sweep, with fixed-seed random stalls capped at pipeline_depth
    - supported_backpressure_modes: directed stall sweep, fixed-seed pseudo-random output backpressure
    - trace_schema_version: none in this TB yet; trace/replay still pending
    */

    localparam DATA_WIDTH       = 10;
    localparam SIGNED_WIDTH     = 11;
    localparam GRAD_WIDTH       = 14;
    localparam WIN_SIZE_WIDTH   = 6;
    localparam LINE_ADDR_WIDTH  = 14;
    localparam ROW_CNT_WIDTH    = 13;
    localparam PATCH_ELEMS      = 25;
    localparam PATCH_WIDTH      = DATA_WIDTH * PATCH_ELEMS;
    localparam CLK_PERIOD       = 10;
    localparam PIPELINE_DEPTH   = 5;
    localparam MAX_STALL_CYCLES = PIPELINE_DEPTH;
    localparam RANDOM_SEED_RUNS = 5;
    localparam RANDOM_TXNS      = 4;
    localparam CHECK_MODE_CASE_A      = 0;
    localparam CHECK_MODE_CENTER_ONLY = 1;
    localparam MAX_PIXEL_X      = 14'd5471;
    localparam MAX_PIXEL_Y      = 13'd3075;

    reg                             clk;
    reg                             rst_n;
    reg                             enable;
    reg signed [SIGNED_WIDTH-1:0]   blend0_dir_avg;
    reg signed [SIGNED_WIDTH-1:0]   blend1_dir_avg;
    reg                             stage3_valid;
    wire                            stage3_ready;
    reg signed [SIGNED_WIDTH-1:0]   avg0_u;
    reg signed [SIGNED_WIDTH-1:0]   avg1_u;
    reg  [WIN_SIZE_WIDTH-1:0]       win_size_clip;
    reg  [PATCH_WIDTH-1:0]          src_patch_5x5;
    reg  [GRAD_WIDTH-1:0]           grad_h;
    reg  [GRAD_WIDTH-1:0]           grad_v;
    reg  [7:0]                      reg_edge_protect;
    reg  [7:0]                      blending_ratio_0;
    reg  [7:0]                      blending_ratio_1;
    reg  [7:0]                      blending_ratio_2;
    reg  [7:0]                      blending_ratio_3;
    wire [DATA_WIDTH-1:0]           dout;
    wire                            dout_valid;
    reg                             dout_ready;
    reg  [LINE_ADDR_WIDTH-1:0]      pixel_x;
    reg  [ROW_CNT_WIDTH-1:0]        pixel_y;
    wire [LINE_ADDR_WIDTH-1:0]      pixel_x_out;
    wire [ROW_CNT_WIDTH-1:0]        pixel_y_out;
    wire                            patch_valid;
    reg                             patch_ready;
    wire [LINE_ADDR_WIDTH-1:0]      patch_center_x;
    wire [ROW_CNT_WIDTH-1:0]        patch_center_y;
    wire [PATCH_WIDTH-1:0]          patch_5x5;
    wire                            lb_wb_en;
    wire [LINE_ADDR_WIDTH-1:0]      lb_wb_addr;
    wire [DATA_WIDTH-1:0]           lb_wb_data;

    integer fail_count;

    integer random_seed_table [0:RANDOM_SEED_RUNS-1];
    integer trace_txn_fd;
    integer replay_txn_fd;

    `define CHECK_EQ_U(TAG, ACT, EXP) \
        if ((ACT) != (EXP)) begin \
            $display("FAIL: %s expected %0d got %0d", TAG, EXP, ACT); \
            fail_count = fail_count + 1; \
        end

    function automatic [DATA_WIDTH-1:0] patch_cell;
        input [PATCH_WIDTH-1:0] patch;
        input integer row;
        input integer col;
        integer lsb;
        begin
            lsb = ((row * 5) + col) * DATA_WIDTH;
            patch_cell = patch[lsb +: DATA_WIDTH];
        end
    endfunction

    task automatic fill_uniform_patch;
        input [DATA_WIDTH-1:0] value;
        integer idx;
        begin
            for (idx = 0; idx < PATCH_ELEMS; idx = idx + 1)
                src_patch_5x5[idx * DATA_WIDTH +: DATA_WIDTH] = value;
        end
    endtask

    function automatic [DATA_WIDTH-1:0] expected_center_from_win_size;
        input [WIN_SIZE_WIDTH-1:0] sample_win_size;
        begin
            case (sample_win_size)
                6'd15: expected_center_from_win_size = 10'd454;
                6'd24: expected_center_from_win_size = 10'd422;
                6'd32: expected_center_from_win_size = 10'd487;
                6'd40: expected_center_from_win_size = 10'd582;
                default: expected_center_from_win_size = 10'd0;
            endcase
        end
    endfunction

    stage4_iir_blend #(
        .DATA_WIDTH      (DATA_WIDTH),
        .SIGNED_WIDTH    (SIGNED_WIDTH),
        .GRAD_WIDTH      (GRAD_WIDTH),
        .WIN_SIZE_WIDTH  (WIN_SIZE_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH),
        .ROW_CNT_WIDTH   (ROW_CNT_WIDTH)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .enable           (enable),
        .blend0_dir_avg   (blend0_dir_avg),
        .blend1_dir_avg   (blend1_dir_avg),
        .stage3_valid     (stage3_valid),
        .stage3_ready     (stage3_ready),
        .avg0_u           (avg0_u),
        .avg1_u           (avg1_u),
        .win_size_clip    (win_size_clip),
        .src_patch_5x5    (src_patch_5x5),
        .grad_h           (grad_h),
        .grad_v           (grad_v),
        .reg_edge_protect (reg_edge_protect),
        .blending_ratio_0 (blending_ratio_0),
        .blending_ratio_1 (blending_ratio_1),
        .blending_ratio_2 (blending_ratio_2),
        .blending_ratio_3 (blending_ratio_3),
        .dout             (dout),
        .dout_valid       (dout_valid),
        .dout_ready       (dout_ready),
        .pixel_x          (pixel_x),
        .pixel_y          (pixel_y),
        .pixel_x_out      (pixel_x_out),
        .pixel_y_out      (pixel_y_out),
        .patch_valid      (patch_valid),
        .patch_ready      (patch_ready),
        .patch_center_x   (patch_center_x),
        .patch_center_y   (patch_center_y),
        .patch_5x5        (patch_5x5),
        .lb_wb_en         (lb_wb_en),
        .lb_wb_addr       (lb_wb_addr),
        .lb_wb_data       (lb_wb_data)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    initial begin
        random_seed_table[0] = 32'h0000_11a5;
        random_seed_table[1] = 32'h0000_22b6;
        random_seed_table[2] = 32'h0000_33c7;
        random_seed_table[3] = 32'h0000_44d8;
        random_seed_table[4] = 32'h0000_55e9;
    end

    task automatic set_defaults;
        begin
            enable           = 1'b1;
            blend0_dir_avg   = 11'sd0;
            blend1_dir_avg   = 11'sd0;
            stage3_valid     = 1'b0;
            avg0_u           = 11'sd0;
            avg1_u           = 11'sd0;
            win_size_clip    = 6'd24;
            src_patch_5x5    = {PATCH_WIDTH{1'b0}};
            grad_h           = {GRAD_WIDTH{1'b0}};
            grad_v           = {GRAD_WIDTH{1'b0}};
            reg_edge_protect = 8'd32;
            blending_ratio_0 = 8'd32;
            blending_ratio_1 = 8'd32;
            blending_ratio_2 = 8'd32;
            blending_ratio_3 = 8'd32;
            dout_ready       = 1'b1;
            patch_ready      = 1'b1;
            pixel_x          = {LINE_ADDR_WIDTH{1'b0}};
            pixel_y          = {ROW_CNT_WIDTH{1'b0}};
        end
    endtask

    task automatic reset_dut;
        begin
            rst_n = 1'b0;
            stage3_valid = 1'b0;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic drive_sample;
        input [WIN_SIZE_WIDTH-1:0]     sample_win_size;
        input signed [SIGNED_WIDTH-1:0] sample_blend0;
        input signed [SIGNED_WIDTH-1:0] sample_blend1;
        input signed [SIGNED_WIDTH-1:0] sample_avg0_u;
        input signed [SIGNED_WIDTH-1:0] sample_avg1_u;
        input [GRAD_WIDTH-1:0]         sample_grad_h;
        input [GRAD_WIDTH-1:0]         sample_grad_v;
        input [DATA_WIDTH-1:0]         patch_fill;
        input [LINE_ADDR_WIDTH-1:0]    sample_x;
        input [ROW_CNT_WIDTH-1:0]      sample_y;
        begin
            win_size_clip  = sample_win_size;
            blend0_dir_avg = sample_blend0;
            blend1_dir_avg = sample_blend1;
            avg0_u         = sample_avg0_u;
            avg1_u         = sample_avg1_u;
            grad_h         = sample_grad_h;
            grad_v         = sample_grad_v;
            pixel_x        = sample_x;
            pixel_y        = sample_y;
            fill_uniform_patch(patch_fill);

            @(negedge clk);
            stage3_valid = 1'b1;
            while (stage3_ready !== 1'b1)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            stage3_valid = 1'b0;
        end
    endtask

    task automatic wait_for_outputs;
        integer cycles;
        begin
            cycles = 0;
            while (((dout_valid !== 1'b1) || (patch_valid !== 1'b1)) && (cycles < (32 + MAX_STALL_CYCLES))) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if ((dout_valid !== 1'b1) || (patch_valid !== 1'b1)) begin
                $display("FAIL: timeout waiting for atomic Stage4 outputs");
                $fatal(1);
            end
        end
    endtask

    task automatic check_case_a_reference_outputs;
        input [LINE_ADDR_WIDTH-1:0] expected_x;
        input [ROW_CNT_WIDTH-1:0]   expected_y;
        begin
            `CHECK_EQ_U("caseA dout center", dout, 10'd454)
            `CHECK_EQ_U("caseA pixel_x", pixel_x_out, expected_x)
            `CHECK_EQ_U("caseA pixel_y", pixel_y_out, expected_y)
            `CHECK_EQ_U("caseA patch_x", patch_center_x, expected_x)
            `CHECK_EQ_U("caseA patch_y", patch_center_y, expected_y)
            `CHECK_EQ_U("caseA patch center", patch_cell(patch_5x5, 2, 2), 10'd454)
            `CHECK_EQ_U("caseA patch left", patch_cell(patch_5x5, 2, 1), 10'd432)
            `CHECK_EQ_U("caseA patch right", patch_cell(patch_5x5, 2, 3), 10'd432)
            `CHECK_EQ_U("caseA patch up", patch_cell(patch_5x5, 1, 2), 10'd421)
            `CHECK_EQ_U("caseA patch down", patch_cell(patch_5x5, 3, 2), 10'd421)
        end
    endtask

    task automatic check_center_only_outputs;
        input [WIN_SIZE_WIDTH-1:0] expected_win_size;
        input [LINE_ADDR_WIDTH-1:0] expected_x;
        input [ROW_CNT_WIDTH-1:0]   expected_y;
        reg [DATA_WIDTH-1:0] expected_center;
        begin
            expected_center = expected_center_from_win_size(expected_win_size);
            `CHECK_EQ_U("center-only dout", dout, expected_center)
            `CHECK_EQ_U("center-only patch center", patch_cell(patch_5x5, 2, 2), expected_center)
            `CHECK_EQ_U("center-only pixel_x", pixel_x_out, expected_x)
            `CHECK_EQ_U("center-only pixel_y", pixel_y_out, expected_y)
            `CHECK_EQ_U("center-only patch_x", patch_center_x, expected_x)
            `CHECK_EQ_U("center-only patch_y", patch_center_y, expected_y)
        end
    endtask

    task automatic check_outputs_by_mode;
        input integer check_mode;
        input [WIN_SIZE_WIDTH-1:0] expected_win_size;
        input [LINE_ADDR_WIDTH-1:0] expected_x;
        input [ROW_CNT_WIDTH-1:0]   expected_y;
        begin
            case (check_mode)
                CHECK_MODE_CASE_A:
                    check_case_a_reference_outputs(expected_x, expected_y);
                CHECK_MODE_CENTER_ONLY:
                    check_center_only_outputs(expected_win_size, expected_x, expected_y);
                default: begin
                    $display("FAIL: unsupported check_mode %0d", check_mode);
                    fail_count = fail_count + 1;
                end
            endcase
        end
    endtask

    task automatic apply_output_backpressure;
        input integer stall_cycles;
        reg [DATA_WIDTH-1:0]          hold_dout;
        reg [LINE_ADDR_WIDTH-1:0]     hold_patch_x;
        reg [ROW_CNT_WIDTH-1:0]       hold_patch_y;
        reg [DATA_WIDTH-1:0]          hold_patch_center;
        integer cycle_idx;
        reg hold_captured;
        begin
            hold_captured = 1'b0;
            if (stall_cycles > 0) begin
                @(negedge clk);
                dout_ready  = 1'b0;
                patch_ready = 1'b0;

                for (cycle_idx = 0; cycle_idx < stall_cycles; cycle_idx = cycle_idx + 1) begin
                    @(posedge clk);
                    if ((dout_valid === 1'b1) || (patch_valid === 1'b1)) begin
                        if ((dout_valid !== 1'b1) || (patch_valid !== 1'b1)) begin
                            $display("FAIL: atomic valid mismatch during backpressure stall");
                            fail_count = fail_count + 1;
                        end
                        if (!hold_captured) begin
                            hold_dout         = dout;
                            hold_patch_x      = patch_center_x;
                            hold_patch_y      = patch_center_y;
                            hold_patch_center = patch_cell(patch_5x5, 2, 2);
                            hold_captured     = 1'b1;
                        end else begin
                            `CHECK_EQ_U("stall hold dout", dout, hold_dout)
                            `CHECK_EQ_U("stall hold patch_x", patch_center_x, hold_patch_x)
                            `CHECK_EQ_U("stall hold patch_y", patch_center_y, hold_patch_y)
                            `CHECK_EQ_U("stall hold patch center", patch_cell(patch_5x5, 2, 2), hold_patch_center)
                        end
                    end
                end

                @(negedge clk);
                dout_ready  = 1'b1;
                patch_ready = 1'b1;
            end
        end
    endtask

    task automatic case_a_patch_semantics_orientation;
        begin
            $display("CASE A: patch feedback must preserve 5x5 orientation semantics");
            set_defaults();
            reset_dut();
            drive_sample(6'd15, 11'sd120, -11'sd40, 11'sd20, -11'sd10, 14'd10, 14'd50, 10'd400, 14'd3, 13'd2);
            wait_for_outputs();

            check_case_a_reference_outputs(14'd3, 13'd2);

            @(posedge clk);
        end
    endtask

    task automatic case_b_bucket_rules;
        begin
            $display("CASE B: win_size buckets must select the reference patch centers");

            set_defaults();
            reset_dut();
            drive_sample(6'd15, 11'sd120, -11'sd40, 11'sd20, -11'sd10, 14'd10, 14'd50, 10'd400, 14'd0, 13'd0);
            wait_for_outputs();
            `CHECK_EQ_U("caseB ws15 dout", dout, 10'd454)
            `CHECK_EQ_U("caseB ws15 patch center", patch_cell(patch_5x5, 2, 2), 10'd454)
            @(posedge clk);

            set_defaults();
            reset_dut();
            drive_sample(6'd24, 11'sd120, -11'sd40, 11'sd20, -11'sd10, 14'd10, 14'd50, 10'd400, 14'd1, 13'd0);
            wait_for_outputs();
            `CHECK_EQ_U("caseB ws24 dout", dout, 10'd422)
            `CHECK_EQ_U("caseB ws24 patch center", patch_cell(patch_5x5, 2, 2), 10'd422)
            @(posedge clk);

            set_defaults();
            reset_dut();
            drive_sample(6'd32, 11'sd120, -11'sd40, 11'sd20, -11'sd10, 14'd10, 14'd50, 10'd400, 14'd2, 13'd0);
            wait_for_outputs();
            `CHECK_EQ_U("caseB ws32 dout", dout, 10'd487)
            `CHECK_EQ_U("caseB ws32 patch center", patch_cell(patch_5x5, 2, 2), 10'd487)
            @(posedge clk);

            set_defaults();
            reset_dut();
            drive_sample(6'd40, 11'sd120, -11'sd40, 11'sd20, -11'sd10, 14'd10, 14'd50, 10'd400, 14'd3, 13'd0);
            wait_for_outputs();
            `CHECK_EQ_U("caseB ws40 dout", dout, 10'd582)
            `CHECK_EQ_U("caseB ws40 patch center", patch_cell(patch_5x5, 2, 2), 10'd582)
            @(posedge clk);
        end
    endtask

    task automatic case_c_stall_stability;
        reg [DATA_WIDTH-1:0]          hold_dout;
        reg [LINE_ADDR_WIDTH-1:0]     hold_patch_x;
        reg [ROW_CNT_WIDTH-1:0]       hold_patch_y;
        reg [DATA_WIDTH-1:0]          hold_patch_center;
        integer cycles;
        begin
            $display("CASE C: dout and patch bus must hold stable during atomic stall");
            set_defaults();
            reset_dut();
            drive_sample(6'd15, 11'sd120, -11'sd40, 11'sd20, -11'sd10, 14'd10, 14'd50, 10'd400, 14'd5, 13'd1);
            wait_for_outputs();

            hold_dout         = dout;
            hold_patch_x      = patch_center_x;
            hold_patch_y      = patch_center_y;
            hold_patch_center = patch_cell(patch_5x5, 2, 2);

            dout_ready  = 1'b0;
            patch_ready = 1'b0;
            for (cycles = 0; cycles < 3; cycles = cycles + 1) begin
                @(posedge clk);
                if ((dout_valid !== 1'b1) || (patch_valid !== 1'b1)) begin
                    $display("FAIL: valid dropped during atomic stall");
                    fail_count = fail_count + 1;
                end
                `CHECK_EQ_U("caseC stall dout", dout, hold_dout)
                `CHECK_EQ_U("caseC stall patch_x", patch_center_x, hold_patch_x)
                `CHECK_EQ_U("caseC stall patch_y", patch_center_y, hold_patch_y)
                `CHECK_EQ_U("caseC stall patch center", patch_cell(patch_5x5, 2, 2), hold_patch_center)
            end

            dout_ready  = 1'b1;
            patch_ready = 1'b1;
            @(posedge clk);
        end
    endtask

    task automatic case_d_max_width_writeback_metadata;
        begin
            $display("CASE D: max-width coordinate must drive patch center and writeback address");
            set_defaults();
            reset_dut();
            drive_sample(6'd24, 11'sd120, -11'sd40, 11'sd20, -11'sd10, 14'd10, 14'd50, 10'd400,
                         MAX_PIXEL_X, MAX_PIXEL_Y);
            wait_for_outputs();

            check_center_only_outputs(6'd24, MAX_PIXEL_X, MAX_PIXEL_Y);
            `CHECK_EQ_U("caseD lb_wb_en", lb_wb_en, 1'b1)
            `CHECK_EQ_U("caseD lb_wb_addr", lb_wb_addr, MAX_PIXEL_X)
            `CHECK_EQ_U("caseD lb_wb_data", lb_wb_data, dout)

            @(posedge clk);
        end
    endtask

    task automatic case_e_pipeline_depth_stall_sweep;
        integer stall_cycles;
        begin
            $display("CASE E: stall sweep covers 0..pipeline_depth with ordinary and boundary-sensitive coordinates");

            for (stall_cycles = 0; stall_cycles <= MAX_STALL_CYCLES; stall_cycles = stall_cycles + 1) begin
                set_defaults();
                reset_dut();
                drive_sample(6'd15, 11'sd120, -11'sd40, 11'sd20, -11'sd10, 14'd10, 14'd50, 10'd400, 14'd3, 13'd2);
                apply_output_backpressure(stall_cycles);
                wait_for_outputs();
                check_case_a_reference_outputs(14'd3, 13'd2);
                @(posedge clk);

                set_defaults();
                reset_dut();
                drive_sample(6'd15, 11'sd120, -11'sd40, 11'sd20, -11'sd10, 14'd10, 14'd50, 10'd400, 14'd0, 13'd0);
                apply_output_backpressure(stall_cycles);
                wait_for_outputs();
                check_case_a_reference_outputs(14'd0, 13'd0);
                @(posedge clk);
            end
        end
    endtask

    task automatic case_f_fixed_seed_random_backpressure;
        integer seed_idx;
        integer txn_idx;
        integer seed_value;
        integer rand_value;
        integer stall_cycles;
        reg [WIN_SIZE_WIDTH-1:0] sample_win_size;
        reg [LINE_ADDR_WIDTH-1:0] sample_x;
        reg [ROW_CNT_WIDTH-1:0]   sample_y;
        begin
            $display("CASE F: fixed-seed random backpressure sweep capped by pipeline depth");

            for (seed_idx = 0; seed_idx < RANDOM_SEED_RUNS; seed_idx = seed_idx + 1) begin
                seed_value = random_seed_table[seed_idx];
                for (txn_idx = 0; txn_idx < RANDOM_TXNS; txn_idx = txn_idx + 1) begin
                    case (txn_idx)
                        0: sample_win_size = 6'd15;
                        1: sample_win_size = 6'd24;
                        2: sample_win_size = 6'd32;
                        default: sample_win_size = 6'd40;
                    endcase

                    if ((txn_idx & 1) == 0) begin
                        sample_x = 14'd0;
                        sample_y = 13'd0;
                    end else begin
                        sample_x = 14'd5 + txn_idx;
                        sample_y = 13'd1;
                    end

                    rand_value = $random(seed_value);
                    if (rand_value < 0)
                        rand_value = -rand_value;
                    stall_cycles = rand_value % (MAX_STALL_CYCLES + 1);

                    set_defaults();
                    reset_dut();
                    drive_sample(sample_win_size, 11'sd120, -11'sd40, 11'sd20, -11'sd10,
                                 14'd10, 14'd50, 10'd400, sample_x, sample_y);
                    apply_output_backpressure(stall_cycles);
                    wait_for_outputs();
                    check_center_only_outputs(sample_win_size, sample_x, sample_y);
                    @(posedge clk);
                end
            end
        end
    endtask

    task automatic open_trace_txn_record;
        begin
            trace_txn_fd = $fopen("verification/stage4_iir_blend_txn_trace.txt", "w");
            if (trace_txn_fd == 0) begin
                $display("FAIL: unable to open trace txn file for write");
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
        input integer txn_id;
        input integer check_mode;
        input [WIN_SIZE_WIDTH-1:0] sample_win_size;
        input signed [SIGNED_WIDTH-1:0] sample_blend0;
        input signed [SIGNED_WIDTH-1:0] sample_blend1;
        input signed [SIGNED_WIDTH-1:0] sample_avg0_u;
        input signed [SIGNED_WIDTH-1:0] sample_avg1_u;
        input [GRAD_WIDTH-1:0] sample_grad_h;
        input [GRAD_WIDTH-1:0] sample_grad_v;
        input [DATA_WIDTH-1:0] patch_fill;
        input [LINE_ADDR_WIDTH-1:0] sample_x;
        input [ROW_CNT_WIDTH-1:0] sample_y;
        input integer stall_cycles;
        input [DATA_WIDTH-1:0] expected_dout;
        input [DATA_WIDTH-1:0] expected_patch_center;
        input [LINE_ADDR_WIDTH-1:0] expected_patch_x;
        input [ROW_CNT_WIDTH-1:0] expected_patch_y;
        begin
            $fwrite(trace_txn_fd,
                    "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                    txn_id, check_mode, sample_win_size, sample_blend0, sample_blend1,
                    sample_avg0_u, sample_avg1_u, sample_grad_h, sample_grad_v,
                    patch_fill, sample_x, sample_y, stall_cycles,
                    expected_dout, expected_patch_center, expected_patch_x, expected_patch_y);
        end
    endtask

    task automatic replay_trace_txn_file;
        integer txn_id;
        integer check_mode;
        integer sample_win_size_i;
        integer sample_blend0_i;
        integer sample_blend1_i;
        integer sample_avg0_i;
        integer sample_avg1_i;
        integer sample_grad_h_i;
        integer sample_grad_v_i;
        integer patch_fill_i;
        integer sample_x_i;
        integer sample_y_i;
        integer stall_cycles_i;
        integer expected_dout_i;
        integer expected_patch_center_i;
        integer expected_patch_x_i;
        integer expected_patch_y_i;
        integer scan_count;
        begin
            replay_txn_fd = $fopen("verification/stage4_iir_blend_txn_trace.txt", "r");
            if (replay_txn_fd == 0) begin
                $display("FAIL: unable to open trace txn file for replay");
                $fatal(1);
            end

            scan_count = $fscanf(replay_txn_fd,
                                 "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                                 txn_id, check_mode, sample_win_size_i, sample_blend0_i, sample_blend1_i,
                                 sample_avg0_i, sample_avg1_i, sample_grad_h_i, sample_grad_v_i,
                                 patch_fill_i, sample_x_i, sample_y_i, stall_cycles_i,
                                 expected_dout_i, expected_patch_center_i, expected_patch_x_i, expected_patch_y_i);
            while (scan_count == 17) begin
                set_defaults();
                reset_dut();
                drive_sample(sample_win_size_i[WIN_SIZE_WIDTH-1:0],
                             sample_blend0_i[SIGNED_WIDTH-1:0],
                             sample_blend1_i[SIGNED_WIDTH-1:0],
                             sample_avg0_i[SIGNED_WIDTH-1:0],
                             sample_avg1_i[SIGNED_WIDTH-1:0],
                             sample_grad_h_i[GRAD_WIDTH-1:0],
                             sample_grad_v_i[GRAD_WIDTH-1:0],
                             patch_fill_i[DATA_WIDTH-1:0],
                             sample_x_i[LINE_ADDR_WIDTH-1:0],
                             sample_y_i[ROW_CNT_WIDTH-1:0]);
                apply_output_backpressure(stall_cycles_i);
                wait_for_outputs();

                `CHECK_EQ_U("trace replay dout", dout, expected_dout_i)
                `CHECK_EQ_U("trace replay patch center", patch_cell(patch_5x5, 2, 2), expected_patch_center_i)
                `CHECK_EQ_U("trace replay patch_x", patch_center_x, expected_patch_x_i)
                `CHECK_EQ_U("trace replay patch_y", patch_center_y, expected_patch_y_i)
                check_outputs_by_mode(check_mode,
                                      sample_win_size_i[WIN_SIZE_WIDTH-1:0],
                                      sample_x_i[LINE_ADDR_WIDTH-1:0],
                                      sample_y_i[ROW_CNT_WIDTH-1:0]);
                @(posedge clk);

                scan_count = $fscanf(replay_txn_fd,
                                     "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                                     txn_id, check_mode, sample_win_size_i, sample_blend0_i, sample_blend1_i,
                                     sample_avg0_i, sample_avg1_i, sample_grad_h_i, sample_grad_v_i,
                                     patch_fill_i, sample_x_i, sample_y_i, stall_cycles_i,
                                     expected_dout_i, expected_patch_center_i, expected_patch_x_i, expected_patch_y_i);
            end

            $fclose(replay_txn_fd);
            replay_txn_fd = 0;
        end
    endtask

    task automatic case_g_trace_record_and_replay;
        begin
            $display("CASE G: transaction trace record and replay");

            open_trace_txn_record();

            set_defaults();
            reset_dut();
            drive_sample(6'd15, 11'sd120, -11'sd40, 11'sd20, -11'sd10, 14'd10, 14'd50, 10'd400, 14'd3, 13'd2);
            apply_output_backpressure(PIPELINE_DEPTH);
            wait_for_outputs();
            check_case_a_reference_outputs(14'd3, 13'd2);
            record_trace_txn(0, CHECK_MODE_CASE_A, 6'd15, 11'sd120, -11'sd40, 11'sd20, -11'sd10,
                             14'd10, 14'd50, 10'd400, 14'd3, 13'd2, PIPELINE_DEPTH,
                             10'd454, 10'd454, 14'd3, 13'd2);
            @(posedge clk);

            set_defaults();
            reset_dut();
            drive_sample(6'd32, 11'sd120, -11'sd40, 11'sd20, -11'sd10, 14'd10, 14'd50, 10'd400, 14'd0, 13'd0);
            apply_output_backpressure(2);
            wait_for_outputs();
            check_center_only_outputs(6'd32, 14'd0, 13'd0);
            record_trace_txn(1, CHECK_MODE_CENTER_ONLY, 6'd32, 11'sd120, -11'sd40, 11'sd20, -11'sd10,
                             14'd10, 14'd50, 10'd400, 14'd0, 13'd0, 2,
                             10'd487, 10'd487, 14'd0, 13'd0);
            @(posedge clk);

            close_trace_txn_record();
            replay_trace_txn_file();
        end
    endtask

    initial begin
        fail_count = 0;
        set_defaults();
        trace_txn_fd  = 0;
        replay_txn_fd = 0;

        case_a_patch_semantics_orientation();
        case_b_bucket_rules();
        case_c_stall_stability();
        case_d_max_width_writeback_metadata();
        case_e_pipeline_depth_stall_sweep();
        case_f_fixed_seed_random_backpressure();
        case_g_trace_record_and_replay();

        if (fail_count != 0) begin
            $display("FAIL: stage4 reference cases (%0d failures)", fail_count);
            $fatal(1);
        end

        $display("PASS: stage4 reference cases");
        $finish;
    end

endmodule
