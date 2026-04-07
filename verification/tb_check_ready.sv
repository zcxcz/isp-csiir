`timescale 1ns/1ps

module tb_check_ready;
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
    
    integer ready_low_cnt = 0;
    integer pix_in = 0, pix_out = 0;
    
    always #0.835 clk = ~clk;
    
    isp_csiir_top #(
        .IMG_WIDTH(IMG_WIDTH), .IMG_HEIGHT(IMG_HEIGHT), .DATA_WIDTH(10),
        .GRAD_WIDTH(14), .LINE_ADDR_WIDTH(14), .ROW_CNT_WIDTH(13)
    ) dut (.*);
    
    // Count how often din_ready is low
    always @(posedge clk) begin
        if (rst_n && din_valid && !din_ready) ready_low_cnt <= ready_low_cnt + 1;
        if (dout_valid) pix_out <= pix_out + 1;
    end
    
    task apb_write(input [7:0] a, input [31:0] d);
        @(posedge clk); psel = 1; pwrite = 1; paddr = a; pwdata = d;
        @(posedge clk); penable = 1;
        @(posedge clk); penable = 0; psel = 0;
    endtask
    
    // Full testbench style - no ready check
    task send_pixel_no_check(input [9:0] val);
        din = val;
        din_valid = 1;
        pix_in = pix_in + 1;
        @(posedge clk);
        din_valid = 0;
    endtask
    
    task send_frame_full_style;
        integer x, y;
        begin
            vsync = 1;
            hsync = 1;
            @(posedge clk);
            vsync = 0;
            
            for (y = 0; y < IMG_HEIGHT; y++) begin
                hsync = 1;
                @(posedge clk);
                hsync = 0;
                
                for (x = 0; x < IMG_WIDTH; x++) begin
                    send_pixel_no_check((x + y * IMG_WIDTH) % 1024);
                end
                
                din_valid = 0;
                hsync = 1;
                repeat(3) @(posedge clk);
            end
            
            vsync = 1;
            repeat(10) @(posedge clk);
            vsync = 0;
        end
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
        
        $display("=== Testing full testbench style (32x32) ===");
        send_frame_full_style();
        $display("[%0t] Frame sent, pix_in=%0d", $time, pix_in);
        
        repeat(2000) @(posedge clk);
        
        $display("\n=== Summary ===");
        $display("Pixels: in=%0d out=%0d", pix_in, pix_out);
        $display("din_ready was LOW during din_valid: %0d times", ready_low_cnt);
        
        if (pix_out >= 1000) $display("PASS");
        else $display("FAIL - check din_ready handling");
        
        $finish;
    end
endmodule
