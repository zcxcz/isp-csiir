`timescale 1ns/1ps
module tb_s1_debug;
    reg clk = 0;
    always #(1.67/2) clk = ~clk;
    
    reg rst_n = 0;
    reg enable = 0;
    reg din_valid = 0;
    reg [9:0] din = 0;
    reg sof = 0;
    reg eol = 0;
    
    wire din_ready;
    wire window_valid;
    wire s1_valid;
    wire [9:0] s1_center;
    wire [13:0] s1_pixel_x;
    wire [12:0] s1_pixel_y;
    
    // Line buffer signals
    wire [9:0] window_0_0, window_0_1, window_0_2, window_0_3, window_0_4;
    wire [9:0] window_1_0, window_1_1, window_1_2, window_1_3, window_1_4;
    wire [9:0] window_2_0, window_2_1, window_2_2, window_2_3, window_2_4;
    wire [9:0] window_3_0, window_3_1, window_3_2, window_3_3, window_3_4;
    wire [9:0] window_4_0, window_4_1, window_4_2, window_4_3, window_4_4;
    wire [13:0] center_x;
    wire [12:0] center_y;
    
    // Instantiate line buffer
    isp_csiir_line_buffer #(
        .IMG_WIDTH(16),
        .DATA_WIDTH(10)
    ) u_lb (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .img_width(16),
        .img_height(16),
        .din(din),
        .din_valid(din_valid),
        .din_ready(din_ready),
        .sof(sof),
        .eol(eol),
        .lb_wb_en(0),
        .lb_wb_data(0),
        .lb_wb_addr(0),
        .lb_wb_row_offset(0),
        .window_0_0(window_0_0), .window_0_1(window_0_1), .window_0_2(window_0_2), .window_0_3(window_0_3), .window_0_4(window_0_4),
        .window_1_0(window_1_0), .window_1_1(window_1_1), .window_1_2(window_1_2), .window_1_3(window_1_3), .window_1_4(window_1_4),
        .window_2_0(window_2_0), .window_2_1(window_2_1), .window_2_2(window_2_2), .window_2_3(window_2_3), .window_2_4(window_2_4),
        .window_3_0(window_3_0), .window_3_1(window_3_1), .window_3_2(window_3_2), .window_3_3(window_3_3), .window_3_4(window_3_4),
        .window_4_0(window_4_0), .window_4_1(window_4_1), .window_4_2(window_4_2), .window_4_3(window_4_3), .window_4_4(window_4_4),
        .window_valid(window_valid),
        .window_ready(1'b1),
        .center_x(center_x),
        .center_y(center_y)
    );
    
    // Instantiate Stage 1
    wire [13:0] s1_grad_h, s1_grad_v, s1_grad;
    wire [5:0] s1_win_size;
    wire s1_ready;
    wire [9:0] s1_win_0_0, s1_win_0_1, s1_win_0_2, s1_win_0_3, s1_win_0_4;
    wire [9:0] s1_win_1_0, s1_win_1_1, s1_win_1_2, s1_win_1_3, s1_win_1_4;
    wire [9:0] s1_win_2_0, s1_win_2_1, s1_win_2_2, s1_win_2_3, s1_win_2_4;
    wire [9:0] s1_win_3_0, s1_win_3_1, s1_win_3_2, s1_win_3_3, s1_win_3_4;
    wire [9:0] s1_win_4_0, s1_win_4_1, s1_win_4_2, s1_win_4_3, s1_win_4_4;
    
    stage1_gradient #(
        .DATA_WIDTH(10),
        .GRAD_WIDTH(14)
    ) u_s1 (
        .clk(clk),
        .rst_n(rst_n),
        .enable(enable),
        .window_0_0(window_0_0), .window_0_1(window_0_1), .window_0_2(window_0_2), .window_0_3(window_0_3), .window_0_4(window_0_4),
        .window_1_0(window_1_0), .window_1_1(window_1_1), .window_1_2(window_1_2), .window_1_3(window_1_3), .window_1_4(window_1_4),
        .window_2_0(window_2_0), .window_2_1(window_2_1), .window_2_2(window_2_2), .window_2_3(window_2_3), .window_2_4(window_2_4),
        .window_3_0(window_3_0), .window_3_1(window_3_1), .window_3_2(window_3_2), .window_3_3(window_3_3), .window_3_4(window_3_4),
        .window_4_0(window_4_0), .window_4_1(window_4_1), .window_4_2(window_4_2), .window_4_3(window_4_3), .window_4_4(window_4_4),
        .window_valid(window_valid),
        .window_ready(s1_ready),
        .win_size_clip_y_0(16), .win_size_clip_y_1(24), .win_size_clip_y_2(32), .win_size_clip_y_3(40),
        .win_size_clip_sft_0(8'd2), .win_size_clip_sft_1(8'd2), .win_size_clip_sft_2(8'd2), .win_size_clip_sft_3(8'd2),
        .grad_h(s1_grad_h),
        .grad_v(s1_grad_v),
        .grad(s1_grad),
        .win_size_clip(s1_win_size),
        .stage1_valid(s1_valid),
        .stage1_ready(1'b1),
        .pixel_x(center_x),
        .pixel_y(center_y),
        .pixel_x_out(s1_pixel_x),
        .pixel_y_out(s1_pixel_y),
        .center_pixel(s1_center),
        .win_out_0_0(s1_win_0_0), .win_out_0_1(s1_win_0_1), .win_out_0_2(s1_win_0_2), .win_out_0_3(s1_win_0_3), .win_out_0_4(s1_win_0_4),
        .win_out_1_0(s1_win_1_0), .win_out_1_1(s1_win_1_1), .win_out_1_2(s1_win_1_2), .win_out_1_3(s1_win_1_3), .win_out_1_4(s1_win_1_4),
        .win_out_2_0(s1_win_2_0), .win_out_2_1(s1_win_2_1), .win_out_2_2(s1_win_2_2), .win_out_2_3(s1_win_2_3), .win_out_2_4(s1_win_2_4),
        .win_out_3_0(s1_win_3_0), .win_out_3_1(s1_win_3_1), .win_out_3_2(s1_win_3_2), .win_out_3_3(s1_win_3_3), .win_out_3_4(s1_win_3_4),
        .win_out_4_0(s1_win_4_0), .win_out_4_1(s1_win_4_1), .win_out_4_2(s1_win_4_2), .win_out_4_3(s1_win_4_3), .win_out_4_4(s1_win_4_4)
    );
    
    integer i;
    initial begin
        repeat(10) @(posedge clk);
        rst_n = 1;
        enable = 1;
        repeat(5) @(posedge clk);
        
        sof = 1;
        @(posedge clk);
        sof = 0;
        
        // Send 20 pixels
        for (i = 0; i < 20; i++) begin
            din = i * 64;
            din_valid = 1;
            @(posedge clk);
            while (!din_ready) @(posedge clk);
        end
        din_valid = 0;
        eol = 1;
        @(posedge clk);
        eol = 0;
        
        repeat(30) @(posedge clk);
        #100;
        $finish;
    end
    
    integer win_cnt = 0, s1_cnt = 0;
    always @(posedge clk) begin
        if (window_valid) win_cnt = win_cnt + 1;
        if (s1_valid) begin
            s1_cnt = s1_cnt + 1;
            $display("[%0t] s1_valid=%b px=%0d py=%0d center=%0d", $time, s1_valid, s1_pixel_x, s1_pixel_y, s1_center);
        end
    end
    
    initial begin
        #200000;
        $display("window_valid count: %0d", win_cnt);
        $display("s1_valid count: %0d", s1_cnt);
    end
endmodule
