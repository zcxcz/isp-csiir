`timescale 1ns/1ps

module tb_stage3_gradient_fusion_casea_ref;

    localparam DATA_WIDTH      = 10;
    localparam SIGNED_WIDTH    = 11;
    localparam GRAD_WIDTH      = 14;
    localparam WIN_SIZE_WIDTH  = 6;
    localparam LINE_ADDR_WIDTH = 14;
    localparam ROW_CNT_WIDTH   = 13;
    localparam BUF_DEPTH       = 8;
    localparam CLK_PERIOD      = 10;

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
        .DATA_WIDTH       (DATA_WIDTH),
        .SIGNED_WIDTH     (SIGNED_WIDTH),
        .GRAD_WIDTH       (GRAD_WIDTH),
        .WIN_SIZE_WIDTH   (WIN_SIZE_WIDTH),
        .LINE_ADDR_WIDTH  (LINE_ADDR_WIDTH),
        .ROW_CNT_WIDTH    (ROW_CNT_WIDTH),
        .IMG_WIDTH        (BUF_DEPTH)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .enable           (enable),
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
        .grad             (grad),
        .win_size_clip    (win_size_clip),
        .center_pixel     (center_pixel),
        .stage2_ready     (stage2_ready),
        .img_height       (img_height),
        .img_width        (img_width),
        .blend0_dir_avg   (blend0_dir_avg),
        .blend1_dir_avg   (blend1_dir_avg),
        .stage3_valid     (stage3_valid),
        .stage3_ready     (stage3_ready),
        .pixel_x          (pixel_x),
        .pixel_y          (pixel_y),
        .pixel_x_out      (pixel_x_out),
        .pixel_y_out      (pixel_y_out),
        .avg0_u_out       (avg0_u_out),
        .avg1_u_out       (avg1_u_out),
        .win_size_clip_out(win_size_clip_out),
        .center_pixel_out (center_pixel_out)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
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
            img_width     = 14'd2;
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

            dut.row_counter    = {ROW_CNT_WIDTH{1'b0}};
            dut.row_valid      = 1'b0;
            dut.col_counter    = {LINE_ADDR_WIDTH{1'b0}};
            dut.flush_active   = 1'b0;
            dut.flush_counter  = {LINE_ADDR_WIDTH{1'b0}};
            dut.flush_done     = 1'b0;
            dut.stage2_valid_d = 1'b0;
            dut.rd_col_d       = {LINE_ADDR_WIDTH{1'b0}};
            dut.row_valid_d    = 1'b0;
            dut.stage2_valid_d2 = 1'b0;
            dut.grad_buf_sel   = 1'b0;
            dut.avg_buf_sel    = 1'b0;
            dut.avg_buf_sel_d  = 1'b0;
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
        integer cycles;
        begin
            cycles = 0;
            while ((stage3_valid !== 1'b1) && (cycles < 24)) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (stage3_valid !== 1'b1) begin
                $display("FAIL: timeout waiting for stage3_valid");
                $fatal(1);
            end
        end
    endtask

    task automatic case_direction_binding_survives_gradient_sort;
        begin
            $display("CASE: direction binding must survive gradient sorting");
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

            wait_for_stage3_valid();

            `CHECK_EQ_U("caseA pixel_x", pixel_x_out, 14'd1)
            `CHECK_EQ_U("caseA pixel_y", pixel_y_out, 13'd1)
            `CHECK_EQ_S("caseA avg0_u passthrough", avg0_u_out, 11'sd200)
            `CHECK_EQ_S("caseA avg1_u passthrough", avg1_u_out, 11'sd60)
            `CHECK_EQ_S("caseA blend0", blend0_dir_avg, 11'sd39)
            `CHECK_EQ_S("caseA blend1", blend1_dir_avg, -11'sd6)

            @(posedge clk);
        end
    endtask

    initial begin
        fail_count = 0;
        set_defaults();
        case_direction_binding_survives_gradient_sort();

        if (fail_count != 0) begin
            $display("FAIL: stage3 caseA reference case (%0d failures)", fail_count);
            $fatal(1);
        end

        $display("PASS: stage3 caseA reference case");
        $finish;
    end

endmodule
