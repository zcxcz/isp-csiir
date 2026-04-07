`timescale 1ns/1ps

module tb_minimal_32;
    reg clk = 0, rst_n = 0;
    reg [7:0] paddr = 0;
    reg [31:0] pwdata = 0;
    reg psel = 0, penable = 0, pwrite = 0;
    wire [31:0] prdata;
    wire pready, pslverr;
    reg vsync = 0, hsync = 0;
    reg [9:0] din = 0;
    reg din_valid = 0;
    wire din_ready;
    wire [9:0] dout;
    wire dout_valid, dout_vsync, dout_hsync;
    wire dout_ready = 1'b1;
    
    integer pix_out = 0;
    
    always #0.835 clk = ~clk;
    
    isp_csiir_top #(
        .IMG_WIDTH(32), .IMG_HEIGHT(32), .DATA_WIDTH(10),
        .GRAD_WIDTH(14), .LINE_ADDR_WIDTH(14), .ROW_CNT_WIDTH(13)
    ) dut (.*);
    
    always @(posedge clk) if (dout_valid) pix_out++;
    
    task apb_w(input [7:0] a, input [31:0] d);
        @(posedge clk); psel = 1; pwrite = 1; paddr = a; pwdata = d;
        @(posedge clk); penable = 1;
        @(posedge clk); penable = 0; psel = 0;
    endtask
    
    initial begin
        repeat(10) @(posedge clk); rst_n = 1;
        repeat(5) @(posedge clk);
        
        apb_w(8'h00, 32'b1);           // Enable
        apb_w(8'h04, {16'd32, 16'd32}); // Size
        apb_w(8'h0C, 32'd16);
        apb_w(8'h10, 32'd24);
        apb_w(8'h14, 32'd32);
        apb_w(8'h18, 32'd40);
        apb_w(8'h1C, 32'd32);
        apb_w(8'h20, 32'd400);
        
        // VSYNC
        #0.5 vsync = 1;
        @(posedge clk);
        #0.5 vsync = 0;
        @(posedge clk);
        
        $display("Sending 1024 pixels (32x32)...");
        for (integer y = 0; y < 32; y++) begin
            for (integer x = 0; x < 32; x++) begin
                din = (x + y * 32) % 1024;
                din_valid = 1;
                @(posedge clk);
                while (!din_ready) @(posedge clk);
                din_valid = 0;
            end
            // EOL
            #0.5 hsync = 1;
            @(posedge clk);
            #0.5 hsync = 0;
            repeat(3) @(posedge clk);
        end
        
        $display("[%0t] Frame sent", $time);
        
        // Wait for all outputs
        repeat(3000) @(posedge clk);
        
        $display("[%0t] Outputs: %0d", $time, pix_out);
        $display(pix_out >= 1000 ? "PASS" : "FAIL");
        $finish;
    end
endmodule
