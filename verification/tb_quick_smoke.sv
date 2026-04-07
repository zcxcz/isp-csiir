`timescale 1ns/1ps

module tb_quick_smoke;
    parameter IMG_WIDTH = 16;
    parameter IMG_HEIGHT = 16;
    
    reg clk = 0, rst_n = 0;
    reg psel = 0, penable = 0, pwrite = 0;
    reg [7:0] paddr = 0;
    reg [31:0] pwdata = 0;
    wire [31:0] prdata;
    wire pready, pslverr;
    reg vsync = 0, hsync = 0;
    reg [9:0] din = 0;
    reg din_valid = 0;
    wire din_ready;
    wire [9:0] dout;
    wire dout_valid, dout_vsync, dout_hsync;
    wire dout_ready = 1'b1;
    
    integer pix_in = 0, pix_out = 0;
    integer s1_cnt = 0, s2_cnt = 0, s3_cnt = 0, s4_cnt = 0;
    
    always #0.835 clk = ~clk;
    
    isp_csiir_top #(
        .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT), .DATA_WIDTH(10),
        .GRAD_WIDTH(14), .LINE_ADDR_WIDTH(14), .ROW_CNT_WIDTH(13)
    ) dut (.*);
    
    always @(posedge clk) begin
        if (dut.s1_valid) s1_cnt <= s1_cnt + 1;
        if (dut.s2_valid) s2_cnt <= s2_cnt + 1;
        if (dut.s3_valid) s3_cnt <= s3_cnt + 1;
        if (dut.s4_dout_valid) s4_cnt <= s4_cnt + 1;
        if (dout_valid) pix_out <= pix_out + 1;
    end
    
    task apb_write(input [7:0] a, input [31:0] d);
        @(posedge clk); psel = 1; pwrite = 1; paddr = a; pwdata = d;
        @(posedge clk); penable = 1;
        @(posedge clk); penable = 0; psel = 0;
    endtask
    
    task send_pixel(input [9:0] val);
        din = val;
        din_valid = 1;
        pix_in = pix_in + 1;
        @(posedge clk);
        while (!din_ready) @(posedge clk);
        din_valid = 0;
    endtask
    
    initial begin
        repeat(10) @(posedge clk); rst_n = 1;
        repeat(5) @(posedge clk);
        
        apb_write(8'h00, 32'b1);
        apb_write(8'h04, {16'd16, 16'd16});
        apb_write(8'h0C, 32'd16);
        apb_write(8'h10, 32'd24);
        apb_write(8'h14, 32'd32);
        apb_write(8'h18, 32'd40);
        apb_write(8'h1C, 32'd32);
        apb_write(8'h20, 32'd400);
        
        $display("=== Sending frame (16x16) ===");
        
        // VSYNC
        #0.5 vsync = 1;
        @(posedge clk);
        #0.5 vsync = 0;
        @(posedge clk);
        
        for (integer y = 0; y < IMG_HEIGHT; y++) begin
            for (integer x = 0; x < IMG_WIDTH; x++) begin
                send_pixel((x + y * IMG_WIDTH) % 1024);
            end
            din_valid = 0;
            #0.5 hsync = 1;
            @(posedge clk);
            #0.5 hsync = 0;
            repeat(3) @(posedge clk);
        end
        
        $display("[%0t] Frame sent, pix_in=%0d", $time, pix_in);
        
        repeat(1000) @(posedge clk);
        
        $display("\n=== Summary ===");
        $display("Pixels: in=%0d out=%0d", pix_in, pix_out);
        $display("Stages: S1=%0d S2=%0d S3=%0d S4=%0d", s1_cnt, s2_cnt, s3_cnt, s4_cnt);
        $display("frame_started=%b", dut.u_line_buffer.frame_started);
        
        if (pix_out >= 200) $display("PASS");
        else $display("FAIL");
        
        $finish;
    end
endmodule
