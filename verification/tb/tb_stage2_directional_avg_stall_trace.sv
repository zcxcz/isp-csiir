`timescale 1ns/1ps

module tb_stage2_directional_avg_stall_trace;

    localparam DATA_WIDTH      = 10;
    localparam SIGNED_WIDTH    = 11;
    localparam GRAD_WIDTH      = 14;
    localparam WIN_SIZE_WIDTH  = 6;
    localparam ACC_WIDTH       = 20;
    localparam LINE_ADDR_WIDTH = 14;
    localparam ROW_CNT_WIDTH   = 13;
    localparam CLK_PERIOD      = 10;

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
    wire signed [SIGNED_WIDTH-1:0] avg1_c;
    wire                        stage2_valid;
    reg                         stage2_ready;
    reg  [LINE_ADDR_WIDTH-1:0]  pixel_x;
    reg  [ROW_CNT_WIDTH-1:0]    pixel_y;
    wire [LINE_ADDR_WIDTH-1:0]  pixel_x_out;
    wire [ROW_CNT_WIDTH-1:0]    pixel_y_out;
    wire [GRAD_WIDTH-1:0]       grad_out;
    wire [WIN_SIZE_WIDTH-1:0]   win_size_clip_out;
    wire [DATA_WIDTH-1:0]       center_pixel_out;

    integer cycle_count;
    integer trace_fd;

    stage2_directional_avg #(
        .DATA_WIDTH      (DATA_WIDTH),
        .SIGNED_WIDTH    (SIGNED_WIDTH),
        .GRAD_WIDTH      (GRAD_WIDTH),
        .WIN_SIZE_WIDTH  (WIN_SIZE_WIDTH),
        .ACC_WIDTH       (ACC_WIDTH),
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
        .avg0_u           (),
        .avg0_d           (),
        .avg0_l           (),
        .avg0_r           (),
        .avg1_c           (avg1_c),
        .avg1_u           (),
        .avg1_d           (),
        .avg1_l           (),
        .avg1_r           (),
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

    always @(posedge clk)
        cycle_count <= cycle_count + 1;

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
            win_size_clip    = 6'd24;
            stage1_valid     = 1'b0;
            stage2_ready     = 1'b1;
            pixel_x          = {LINE_ADDR_WIDTH{1'b0}};
            pixel_y          = {ROW_CNT_WIDTH{1'b0}};
            center_pixel     = {DATA_WIDTH{1'b0}};
            win_size_thresh0 = 16'd16;
            win_size_thresh1 = 16'd24;
            win_size_thresh2 = 16'd32;
            win_size_thresh3 = 16'd40;
            for (r = 0; r < 5; r = r + 1)
                for (c = 0; c < 5; c = c + 1)
                    win[r][c] = {DATA_WIDTH{1'b0}};
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
        begin
            @(negedge clk);
            stage1_valid = 1'b1;
            while (stage1_ready !== 1'b1)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            stage1_valid = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (trace_fd != 0) begin
            $fdisplay(trace_fd,
                "%0d ready=%0b s1v=%0b s1r=%0b v4=%0b v5=%0b v6=%0b outv=%0b avg0c=%0d avg1c=%0d x=%0d y=%0d grad=%0d win=%0d center=%0d",
                cycle_count, stage2_ready, stage1_valid, stage1_ready,
                dut.valid_s4, dut.valid_s5, dut.valid_s6, stage2_valid,
                $signed(avg0_c), $signed(avg1_c), pixel_x_out, pixel_y_out, grad_out, win_size_clip_out, center_pixel_out);
        end
    end

    initial begin
        cycle_count = 0;
        trace_fd = 0;
        set_defaults();
        apply_base_window();
        reset_dut();

        trace_fd = $fopen("verification/stage2_casec_stall_trace.txt", "w");
        if (trace_fd == 0) begin
            $display("FAIL: unable to open stage2 stall trace file");
            $fatal(1);
        end

        drive_sample();

        repeat (2) @(posedge clk);
        @(negedge clk);
        stage2_ready = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        stage2_ready = 1'b1;
        repeat (3) @(posedge clk);

        $fclose(trace_fd);
        trace_fd = 0;

        $display("TRACE_WRITTEN: verification/stage2_casec_stall_trace.txt");
        $display("FINAL: v4=%0b v5=%0b v6=%0b outv=%0b avg0c=%0d avg1c=%0d x=%0d y=%0d",
                 dut.valid_s4, dut.valid_s5, dut.valid_s6, stage2_valid,
                 $signed(avg0_c), $signed(avg1_c), pixel_x_out, pixel_y_out);
        $finish;
    end

endmodule
