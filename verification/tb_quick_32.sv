`timescale 1ns/1ps

module tb_quick_32;
    parameter IMG_WIDTH = 32;
    parameter IMG_HEIGHT = 32;
    
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
    
    integer pixel_in = 0, pixel_out = 0;
    
    always #0.835 clk = ~clk;
    
    isp_csiir_top #(
        .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT), .DATA_WIDTH(10),
        .GRAD_WIDTH(14), .LINE_ADDR_WIDTH(14), .ROW_CNT_WIDTH(13)
    ) dut (.*);
    
    always @(posedge clk) if (dout_valid) pixel_out++;
    
    task apb_write(input [7:0] a, input [31:0] d);
        @(posedge clk); psel = 1; pwrite = 1; paddr = a; pwdata = d;
        @(posedge clk); penable = 1;
        @(posedge clk); penable = 0; psel = 0;
    endtask
    
    task send_pix(input [9:0] v);
        din = v; din_valid = 1; pixel_in++;
        @(posedge clk);
        while (!din_ready) @(posedge clk);
        din_valid = 0;
    endtask
    
    initial begin
        repeat(10) @(posedge clk); rst_n = 1;
        repeat(5) @(posedge clk);
        
        apb_write(8'h00, 32'b1);
        apb_write(8'h04, {16'd32, 16'd32});
        apb_write(8'h0C, 32'd16);
        apb_write(8'h10, 32'd24);
        apb_write(8'h14, 32'd32);
        apb_write(8'h18, 32'd40);
        apb_write(8'h1C, 32'd32);
        apb_write(8'h20, 32'd400);
        
        $display("Sending 1024 pixels...");
        repeat(1024) send_pix(10'd512);
        
        repeat(2000) @(posedge clk);
        
        $display("Pixels in: %0d, out: %0d", pixel_in, pixel_out);
        $finish;
    end
endmodule
