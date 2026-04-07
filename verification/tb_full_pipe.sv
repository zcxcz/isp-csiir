`timescale 1ns/1ps
module tb_full_pipe;
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
    wire s1_valid, s2_valid, s3_valid, s4_valid;
    wire [9:0] s4_dout;
    
    // Instantiate top
    isp_csiir_top #(
        .IMG_WIDTH(16),
        .IMG_HEIGHT(16),
        .DATA_WIDTH(10),
        .GRAD_WIDTH(14)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .psel(0), .penable(0), .pwrite(0), .paddr(0), .pwdata(0),
        .prdata(), .pready(), .pslverr(),
        .vsync(sof), .hsync(eol),
        .din(din),
        .din_valid(din_valid),
        .din_ready(din_ready),
        .dout(s4_dout),
        .dout_valid(s4_valid),
        .dout_vsync(), .dout_hsync()
    );
    
    // Monitor signals
    wire lb_wv = dut.window_valid;
    wire s1v = dut.s1_valid;
    wire s2v = dut.s2_valid;
    wire s3v = dut.s3_valid;
    
    integer i;
    initial begin
        repeat(10) @(posedge clk);
        rst_n = 1;
        enable = 1;
        
        // Enable via APB
        @(posedge clk);
        dut.cfg_enable = 1;
        dut.cfg_bypass = 0;
        dut.cfg_img_width = 16;
        dut.cfg_img_height = 16;
        
        repeat(5) @(posedge clk);
        
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
        
        repeat(30) @(posedge clk);
        #100;
        $finish;
    end
    
    integer lb_cnt = 0, s1_cnt = 0, s2_cnt = 0, s3_cnt = 0, s4_cnt = 0;
    always @(posedge clk) begin
        if (lb_wv) lb_cnt = lb_cnt + 1;
        if (s1v) s1_cnt = s1_cnt + 1;
        if (s2v) s2_cnt = s2_cnt + 1;
        if (s3v) s3_cnt = s3_cnt + 1;
        if (s4_valid) s4_cnt = s4_cnt + 1;
    end
    
    initial begin
        #200000;
        $display("LB valid:  %0d", lb_cnt);
        $display("S1 valid:  %0d", s1_cnt);
        $display("S2 valid:  %0d", s2_cnt);
        $display("S3 valid:  %0d", s3_cnt);
        $display("S4 valid:  %0d", s4_cnt);
    end
endmodule
