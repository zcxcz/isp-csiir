`timescale 1ns/1ps
module tb_lb_debug;
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
    wire [9:0] window_2_2;
    wire [13:0] center_x;
    wire [12:0] center_y;
    
    // Instantiate line buffer
    isp_csiir_line_buffer #(
        .IMG_WIDTH(16),
        .DATA_WIDTH(10)
    ) uut (
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
        .window_2_2(window_2_2),
        .window_valid(window_valid),
        .window_ready(1'b1),
        .center_x(center_x),
        .center_y(center_y)
    );
    
    integer i;
    initial begin
        // Reset
        repeat(10) @(posedge clk);
        rst_n = 1;
        enable = 1;
        repeat(5) @(posedge clk);
        
        // Start frame
        sof = 1;
        @(posedge clk);
        sof = 0;
        
        // Send 16 pixels
        for (i = 0; i < 16; i++) begin
            din = i * 64;
            din_valid = 1;
            @(posedge clk);
            while (!din_ready) @(posedge clk);
        end
        din_valid = 0;
        eol = 1;
        @(posedge clk);
        eol = 0;
        
        // Wait and check outputs
        repeat(20) @(posedge clk);
        
        $display("window_valid count during test: checking...");
        
        #100;
        $finish;
    end
    
    // Count window_valid
    integer win_cnt = 0;
    always @(posedge clk) begin
        if (window_valid) begin
            win_cnt = win_cnt + 1;
            $display("[%0t] window_valid=%b center_x=%0d center_y=%0d window_2_2=%0d",
                $time, window_valid, center_x, center_y, window_2_2);
        end
    end
endmodule
