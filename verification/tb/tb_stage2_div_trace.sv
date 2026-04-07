`timescale 1ns/1ps

module tb_stage2_div_trace;
    reg clk = 0;
    reg rst_n = 0;

    // Test values
    wire signed [19:0] sum_c = -20'sd12680;
    wire [7:0] w_c = 8'd25;

    // Instantiate the actual Stage 2 module with minimal inputs
    // We'll trace internal signals

    wire signed [10:0] avg0_c, avg0_u, avg0_d, avg0_l, avg0_r;
    wire signed [10:0] avg1_c, avg1_u, avg1_d, avg1_l, avg1_r;
    wire stage2_valid;

    // DUT - Stage 2 directional avg
    stage2_directional_avg #(
        .DATA_WIDTH(10),
        .SIGNED_WIDTH(11),
        .GRAD_WIDTH(14),
        .WIN_SIZE_WIDTH(6),
        .ACC_WIDTH(20),
        .LINE_ADDR_WIDTH(14),
        .ROW_CNT_WIDTH(13)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .enable(1'b1),
        // Window inputs (all zeros)
        .window_0_0(0), .window_0_1(0), .window_0_2(0), .window_0_3(0), .window_0_4(0),
        .window_1_0(0), .window_1_1(0), .window_1_2(0), .window_1_3(0), .window_1_4(0),
        .window_2_0(0), .window_2_1(0), .window_2_2(0), .window_2_3(0), .window_2_4(0),
        .window_3_0(0), .window_3_1(0), .window_3_2(0), .window_3_3(0), .window_3_4(0),
        .window_4_0(0), .window_4_1(0), .window_4_2(0), .window_4_3(0), .window_4_4(0),
        // Stage 1 outputs
        .grad_h(0), .grad_v(0), .grad(0), .win_size_clip(6'd25),
        .stage1_valid(1'b1), .center_pixel(0),
        .stage1_ready(),
        // Config
        .win_size_thresh0(16'd100), .win_size_thresh1(16'd200),
        .win_size_thresh2(16'd400), .win_size_thresh3(16'd800),
        // Outputs
        .avg0_c(avg0_c), .avg0_u(avg0_u), .avg0_d(avg0_d), .avg0_l(avg0_l), .avg0_r(avg0_r),
        .avg1_c(avg1_c), .avg1_u(avg1_u), .avg1_d(avg1_d), .avg1_l(avg1_l), .avg1_r(avg1_r),
        .stage2_valid(stage2_valid),
        .stage2_ready(1'b1),
        // Pass through
        .pixel_x(0), .pixel_y(0),
        .pixel_x_out(), .pixel_y_out(),
        .grad_out(), .win_size_clip_out(), .center_pixel_out()
    );

    always #5 clk = ~clk;

    initial begin
        #20 rst_n = 1;
        #100;

        // Wait for pipeline to flush
        repeat(10) @(posedge clk);

        $display("\n=== Stage 2 Internal Signals ===");
        $display("sum_c_s6 = %0d", $signed(dut.sum_c_s6));
        $display("w_c_s6 = %0d", dut.w_c_s6);
        $display("avg0_c_div_full = %0d", $signed(dut.avg0_c_div_full));
        $display("avg0_c_comb = %0d", $signed(dut.avg0_c_comb));
        $display("avg0_c output = %0d", $signed(avg0_c));
        $display("stage2_valid = %0d", stage2_valid);

        $finish;
    end

endmodule