`timescale 1ns/1ps
module tb_full_pipe2;
    reg clk = 0;
    always #(1.67/2) clk = ~clk;
    
    reg rst_n = 0;
    reg psel = 0, penable = 0, pwrite = 0;
    reg [7:0] paddr = 0;
    reg [31:0] pwdata = 0;
    wire [31:0] prdata;
    wire pready, pslverr;
    
    reg vsync = 0, hsync = 0;
    reg din_valid = 0;
    reg [9:0] din = 0;
    wire din_ready;
    wire [9:0] dout;
    wire dout_valid;
    
    // Instantiate top
    isp_csiir_top #(
        .IMG_WIDTH(16),
        .IMG_HEIGHT(16)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr), .pwdata(pwdata),
        .prdata(prdata), .pready(pready), .pslverr(pslverr),
        .vsync(vsync), .hsync(hsync),
        .din(din),
        .din_valid(din_valid),
        .din_ready(din_ready),
        .dout(dout),
        .dout_valid(dout_valid)
    );
    
    task apb_write;
        input [7:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            psel = 1; pwrite = 1; paddr = addr; pwdata = data;
            @(posedge clk);
            penable = 1;
            @(posedge clk);
            penable = 0; psel = 0;
        end
    endtask
    
    // Monitor signals
    wire lb_wv = dut.window_valid;
    wire s1v = dut.s1_valid;
    wire s2v = dut.s2_valid;
    wire s3v = dut.s3_valid;
    
    integer i;
    initial begin
        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);
        
        // Configure
        apb_write(8'h00, 32'b1);  // Enable
        apb_write(8'h04, {16'd16, 16'd16});  // Size
        apb_write(8'h0C, 32'd16);
        apb_write(8'h10, 32'd24);
        apb_write(8'h14, 32'd32);
        apb_write(8'h18, 32'd40);
        apb_write(8'h1C, 32'd32);
        apb_write(8'h20, 32'd400);
        
        repeat(5) @(posedge clk);
        
        vsync = 1;
        @(posedge clk);
        vsync = 0;
        
        // Send 16 pixels
        for (i = 0; i < 16; i++) begin
            din = i * 64;
            din_valid = 1;
            @(posedge clk);
            while (!din_ready) @(posedge clk);
        end
        din_valid = 0;
        hsync = 1;
        @(posedge clk);
        hsync = 0;
        
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
        if (dout_valid) s4_cnt = s4_cnt + 1;
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
