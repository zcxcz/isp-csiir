`timescale 1ns/1ps

module tb_isp_csiir_line_buffer_eol_backpressure;

    /*
    TB_CONTRACT
    - module_name: isp_csiir_line_buffer
    - boundary_id: input_stream_and_writeback_to_window_state
    - compare_object: local line-buffer state transition, write pointer / flush state, and writeback commit into selected row memory
    - expected_source: explicit directed expectations derived from current line-buffer contract
    - observed_source: din_ready / wr_col_ptr / wr_row_ptr / row_cnt / flush_active / flush_cnt / flush_center / line_mem_x[address]
    - sample_edge: negedge drive, posedge state transition check
    - input_valid_ready_contract: input pixel accepted only on din_valid && din_ready
    - output_valid_ready_contract: local state affecting window output may advance only when window_ready allows progress
    - writeback_contract: lb_wb_en commits exactly one targeted memory write when enable is high
    - metadata_scope: wr_row_ptr, wr_col_ptr, row_cnt, flush state, lb_wb_addr, lb_wb_row_offset
    - boundary_conditions: stalled eol, fixed-seed random backpressure on input acceptance, writeback to current row
    - pipeline_depth: 1-cycle registered state update for local counters / window-valid path
    - max_stall_cycles_policy: directed stalled-eol plus fixed-seed random ready toggling
    - trace_schema_version: none in this TB yet; trace/replay pending
    - pass_fail_predicate: all directed contract checks pass with zero mismatches
    */

    localparam IMG_WIDTH        = 16;
    localparam IMG_HEIGHT       = 16;
    localparam DATA_WIDTH       = 10;
    localparam LINE_ADDR_WIDTH  = 14;
    localparam CLK_PERIOD       = 10;
    localparam RANDOM_SEED_RUNS = 3;
    localparam RANDOM_CYCLES    = 10;

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
    wire [DATA_WIDTH-1:0]       window_2_0;
    wire [DATA_WIDTH-1:0]       window_2_1;
    wire [DATA_WIDTH-1:0]       window_2_2;
    wire [DATA_WIDTH-1:0]       window_2_3;
    wire [DATA_WIDTH-1:0]       window_2_4;
    wire                        window_valid;
    reg                         window_ready;
    wire [LINE_ADDR_WIDTH-1:0]  center_x;
    wire [12:0]                 center_y;

    integer fail_count;
    integer random_seed_table [0:RANDOM_SEED_RUNS-1];
    integer accept_count;
    integer stall_count;

    reg [LINE_ADDR_WIDTH-1:0]   held_wr_col_ptr;
    reg [2:0]                   held_wr_row_ptr;
    reg [12:0]                  held_row_cnt;
    reg                         held_flush_active;
    reg [2:0]                   held_flush_cnt;
    reg [LINE_ADDR_WIDTH-1:0]   held_flush_center;

    `define CHECK_EQ_U(TAG, ACT, EXP) \
        if ((ACT) != (EXP)) begin \
            $display("FAIL: %s expected %0d got %0d", TAG, EXP, ACT); \
            fail_count = fail_count + 1; \
        end

    `define CHECK_EQ_BIT(TAG, ACT, EXP) \
        if ((ACT) !== (EXP)) begin \
            $display("FAIL: %s expected %0b got %0b", TAG, EXP, ACT); \
            fail_count = fail_count + 1; \
        end

    isp_csiir_line_buffer #(
        .IMG_WIDTH       (IMG_WIDTH),
        .DATA_WIDTH      (DATA_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .enable           (enable),
        .img_width        (LINE_ADDR_WIDTH'(IMG_WIDTH)),
        .img_height       (13'(IMG_HEIGHT)),
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
        .window_2_0       (window_2_0),
        .window_2_1       (window_2_1),
        .window_2_2       (window_2_2),
        .window_2_3       (window_2_3),
        .window_2_4       (window_2_4),
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

    initial begin
        random_seed_table[0] = 32'h0000_31a5;
        random_seed_table[1] = 32'h0000_42b6;
        random_seed_table[2] = 32'h0000_53c7;
    end

    task automatic reset_dut;
        begin
            rst_n            = 1'b0;
            enable           = 1'b0;
            din              = {DATA_WIDTH{1'b0}};
            din_valid        = 1'b0;
            sof              = 1'b0;
            eol              = 1'b0;
            lb_wb_en         = 1'b0;
            lb_wb_data       = {DATA_WIDTH{1'b0}};
            lb_wb_addr       = {LINE_ADDR_WIDTH{1'b0}};
            lb_wb_row_offset = 3'd0;
            window_ready     = 1'b1;
            repeat (5) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic pulse_sof;
        begin
            enable = 1'b1;
            @(negedge clk);
            sof = 1'b1;
            @(posedge clk);
            @(negedge clk);
            sof = 1'b0;
        end
    endtask

    task automatic seed_stalled_eol_state;
        begin
            enable                = 1'b1;
            window_ready          = 1'b0;
            dut.frame_started     = 1'b1;
            dut.wr_row_ptr        = 3'd2;
            dut.wr_col_ptr        = 14'd15;
            dut.row_cnt           = 13'd3;
            dut.window_valid      = 1'b1;
            dut.window_valid_next = 1'b0;
            dut.flush_active      = 1'b0;
            dut.flush_cnt         = 3'd0;
            dut.flush_center      = {LINE_ADDR_WIDTH{1'b0}};
            @(posedge clk);
        end
    endtask

    task automatic case_a_stalled_eol_without_accept_must_not_advance_state;
        begin
            $display("CASE A: stalled eol pulse must not advance local state before ready returns");
            reset_dut();
            seed_stalled_eol_state();

            held_wr_col_ptr   = dut.wr_col_ptr;
            held_wr_row_ptr   = dut.wr_row_ptr;
            held_row_cnt      = dut.row_cnt;
            held_flush_active = dut.flush_active;
            held_flush_cnt    = dut.flush_cnt;
            held_flush_center = dut.flush_center;

            @(negedge clk);
            din       = 10'd123;
            din_valid = 1'b0;
            eol       = 1'b1;

            `CHECK_EQ_BIT("caseA din_ready low during stall", din_ready, 1'b0)

            @(posedge clk);
            @(negedge clk);

            `CHECK_EQ_U("caseA wr_col_ptr hold", dut.wr_col_ptr, held_wr_col_ptr)
            `CHECK_EQ_U("caseA wr_row_ptr hold", dut.wr_row_ptr, held_wr_row_ptr)
            `CHECK_EQ_U("caseA row_cnt hold", dut.row_cnt, held_row_cnt)
            `CHECK_EQ_BIT("caseA flush_active hold", dut.flush_active, held_flush_active)
            `CHECK_EQ_U("caseA flush_cnt hold", dut.flush_cnt, held_flush_cnt)
            `CHECK_EQ_U("caseA flush_center hold", dut.flush_center, held_flush_center)

            window_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);

            `CHECK_EQ_U("caseA wr_col_ptr advance after release", dut.wr_col_ptr, {LINE_ADDR_WIDTH{1'b0}})
            `CHECK_EQ_U("caseA wr_row_ptr advance after release", dut.wr_row_ptr, 3'd3)
            `CHECK_EQ_U("caseA row_cnt advance after release", dut.row_cnt, 13'd4)
            `CHECK_EQ_BIT("caseA flush_active start after release", dut.flush_active, 1'b1)
            `CHECK_EQ_U("caseA flush_cnt start after release", dut.flush_cnt, 3'd5)
            `CHECK_EQ_U("caseA flush_center start after release", dut.flush_center, 14'd11)

            eol = 1'b0;
            @(posedge clk);
        end
    endtask

    task automatic case_b_fixed_seed_random_backpressure_accept_counter;
        integer seed_idx;
        integer cycle_idx;
        integer seed_value;
        integer rand_value;
        reg expected_ready;
        reg [LINE_ADDR_WIDTH-1:0] expected_wr_col_ptr;
        begin
            $display("CASE B: fixed-seed random ready toggling only advances write pointer on accepted beats");
            accept_count = 0;
            stall_count  = 0;

            for (seed_idx = 0; seed_idx < RANDOM_SEED_RUNS; seed_idx = seed_idx + 1) begin
                reset_dut();
                enable = 1'b1;
                dut.frame_started = 1'b1;
                dut.wr_col_ptr    = {LINE_ADDR_WIDTH{1'b0}};
                expected_wr_col_ptr = {LINE_ADDR_WIDTH{1'b0}};
                seed_value = random_seed_table[seed_idx];

                for (cycle_idx = 0; cycle_idx < RANDOM_CYCLES; cycle_idx = cycle_idx + 1) begin
                    rand_value = $random(seed_value);
                    if (rand_value < 0)
                        rand_value = -rand_value;
                    expected_ready = rand_value[0];

                    @(negedge clk);
                    window_ready = expected_ready;
                    din_valid    = 1'b1;
                    din          = DATA_WIDTH'(seed_idx * RANDOM_CYCLES + cycle_idx);
                    eol          = 1'b0;
                    #1;
                    `CHECK_EQ_BIT("caseB din_ready mirrors ready", din_ready, expected_ready)

                    @(posedge clk);
                    #1;

                    if (expected_ready) begin
                        expected_wr_col_ptr = expected_wr_col_ptr + 1'b1;
                        accept_count = accept_count + 1;
                    end else begin
                        stall_count = stall_count + 1;
                    end

                    `CHECK_EQ_U("caseB wr_col_ptr tracks accepts", dut.wr_col_ptr, expected_wr_col_ptr)
                end

                @(negedge clk);
                din_valid    = 1'b0;
                window_ready = 1'b1;
            end

            if (accept_count == 0) begin
                $display("FAIL: caseB did not observe any accepted beat");
                fail_count = fail_count + 1;
            end
            if (stall_count == 0) begin
                $display("FAIL: caseB did not observe any stalled beat");
                fail_count = fail_count + 1;
            end
        end
    endtask

    task automatic case_c_writeback_commit_updates_target_row;
        reg [DATA_WIDTH-1:0] expected_data;
        begin
            $display("CASE C: writeback enable must commit targeted row-memory update");
            reset_dut();
            enable = 1'b1;

            dut.wr_row_ptr       = 3'd2;
            dut.line_mem_2[5]    = 10'd33;
            dut.line_mem_1[5]    = 10'd11;
            dut.line_mem_3[5]    = 10'd55;
            lb_wb_addr           = 14'd5;
            lb_wb_row_offset     = 3'd0;
            expected_data        = 10'd777;

            @(negedge clk);
            lb_wb_data = expected_data;
            lb_wb_en   = 1'b1;
            @(posedge clk);
            @(negedge clk);
            lb_wb_en   = 1'b0;

            `CHECK_EQ_U("caseC target row updated", dut.line_mem_2[5], expected_data)
            `CHECK_EQ_U("caseC previous row untouched", dut.line_mem_1[5], 10'd11)
            `CHECK_EQ_U("caseC next row untouched", dut.line_mem_3[5], 10'd55)
        end
    endtask

    task automatic case_d_even_lane_horizontal_window_sampling;
        begin
            $display("CASE D: horizontal 5-tap window must stay on same UV lane");
            reset_dut();
            enable = 1'b1;

            dut.wr_row_ptr    = 3'd4;
            dut.row_cnt       = 13'd4;
            dut.rd_col_ptr    = 14'd4;
            dut.line_mem_2[0] = 10'd100;
            dut.line_mem_2[1] = 10'd101;
            dut.line_mem_2[2] = 10'd200;
            dut.line_mem_2[3] = 10'd201;
            dut.line_mem_2[4] = 10'd300;
            dut.line_mem_2[5] = 10'd301;
            dut.line_mem_2[6] = 10'd400;
            dut.line_mem_2[7] = 10'd401;
            dut.line_mem_2[8] = 10'd500;

            #1;
            `CHECK_EQ_U("caseD tap0 uses x-4", dut.window_comb_2_0, 10'd100)
            `CHECK_EQ_U("caseD tap1 uses x-2", dut.window_comb_2_1, 10'd200)
            `CHECK_EQ_U("caseD tap2 uses x",   dut.window_comb_2_2, 10'd300)
            `CHECK_EQ_U("caseD tap3 uses x+2", dut.window_comb_2_3, 10'd400)
            `CHECK_EQ_U("caseD tap4 uses x+4", dut.window_comb_2_4, 10'd500)
        end
    endtask

    task automatic case_e_top_padding_contract;
        begin
            $display("CASE E: top padding must duplicate the nearest available rows");
            reset_dut();
            enable = 1'b1;

            // Writing row 2 means the emitted center row is row 0 under the
            // delayed symmetric-window contract.
            dut.wr_row_ptr    = 3'd2;
            dut.row_cnt       = 13'd2;
            dut.rd_col_ptr    = 14'd4;

            dut.line_mem_0[4] = 10'd110;
            dut.line_mem_1[4] = 10'd210;
            dut.line_mem_2[4] = 10'd310;

            #1;
            `CHECK_EQ_U("caseE row0 duplicates top row",    dut.window_comb_0_2, 10'd110)
            `CHECK_EQ_U("caseE row1 duplicates top row",    dut.window_comb_1_2, 10'd110)
            `CHECK_EQ_U("caseE center uses row0",           dut.window_comb_2_2, 10'd110)
            `CHECK_EQ_U("caseE row3 uses row1",             dut.window_comb_3_2, 10'd210)
            `CHECK_EQ_U("caseE row4 uses row2",             dut.window_comb_4_2, 10'd310)
        end
    endtask

    initial begin
        fail_count = 0;

        case_a_stalled_eol_without_accept_must_not_advance_state();
        case_b_fixed_seed_random_backpressure_accept_counter();
        case_c_writeback_commit_updates_target_row();
        case_d_even_lane_horizontal_window_sampling();
        case_e_top_padding_contract();

        if (fail_count != 0) begin
            $display("FAIL: line buffer contract cases (%0d failures)", fail_count);
            $fatal(1);
        end

        $display("PASS: line buffer contract cases");
        $finish;
    end

endmodule
