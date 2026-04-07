`timescale 1ns/1ps

module tb_stage1_gradient_stall_trace;

    localparam DATA_WIDTH      = 10;
    localparam GRAD_WIDTH      = 14;
    localparam WIN_SIZE_WIDTH  = 6;
    localparam LINE_ADDR_WIDTH = 14;
    localparam ROW_CNT_WIDTH   = 13;
    localparam CLK_PERIOD      = 10;

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
    integer                     cycle_count;
    integer                     trace_fd;

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
        .win_out_0_0      (), .win_out_0_1(), .win_out_0_2(), .win_out_0_3(), .win_out_0_4(),
        .win_out_1_0      (), .win_out_1_1(), .win_out_1_2(), .win_out_1_3(), .win_out_1_4(),
        .win_out_2_0      (), .win_out_2_1(), .win_out_2_2(), .win_out_2_3(), .win_out_2_4(),
        .win_out_3_0      (), .win_out_3_1(), .win_out_3_2(), .win_out_3_3(), .win_out_3_4(),
        .win_out_4_0      (), .win_out_4_1(), .win_out_4_2(), .win_out_4_3(), .win_out_4_4()
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    always @(posedge clk)
        cycle_count <= cycle_count + 1;

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
                for (c = 0; c < 5; c = c + 1)
                    win[r][c] = {DATA_WIDTH{1'b0}};
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

    task automatic drive_sample;
        begin
            pixel_x = 14'd15;
            pixel_y = 13'd2;
            @(negedge clk);
            window_valid = 1'b1;
            while (window_ready !== 1'b1)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            window_valid = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        #1;
        if (trace_fd != 0) begin
            $fdisplay(trace_fd,
                "%0d ready=%0b wv=%0b wr=%0b s0=%0b s1=%0b s2=%0b s3=%0b outv=%0b gh=%0d gv=%0d g=%0d clip=%0d x=%0d y=%0d c=%0d",
                cycle_count, stage1_ready, window_valid, window_ready,
                dut.valid_s0, dut.valid_s1, dut.valid_s2, dut.valid_s3, stage1_valid,
                grad_h, grad_v, grad, win_size_clip, pixel_x_out, pixel_y_out, center_pixel);
        end
    end

    initial begin
        cycle_count = 0;
        trace_fd = 0;
        set_defaults();
        fill_col_window(10'd60, 10'd30, 10'd20, 10'd10, 10'd0);
        reset_dut();

        trace_fd = $fopen("verification/stage1_casec_stall_trace.txt", "w");
        if (trace_fd == 0) begin
            $display("FAIL: unable to open stage1 stall trace file");
            $fatal(1);
        end

        drive_sample();

        repeat (3) @(posedge clk);
        @(negedge clk);
        stage1_ready = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        stage1_ready = 1'b1;
        repeat (3) @(posedge clk);

        $fclose(trace_fd);
        trace_fd = 0;

        $display("TRACE_WRITTEN: verification/stage1_casec_stall_trace.txt");
        $display("FINAL: s3=%0b outv=%0b gh=%0d gv=%0d g=%0d clip=%0d x=%0d y=%0d",
                 dut.valid_s3, stage1_valid, grad_h, grad_v, grad, win_size_clip, pixel_x_out, pixel_y_out);
        $finish;
    end

endmodule
