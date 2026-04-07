`timescale 1ns/1ps

module tb_sof_debug;
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
    
    always #0.835 clk = ~clk;
    
    isp_csiir_top #(
        .IMG_WIDTH(16), .IMG_HEIGHT(16), .DATA_WIDTH(10),
        .GRAD_WIDTH(14), .LINE_ADDR_WIDTH(14), .ROW_CNT_WIDTH(13)
    ) dut (.*);
    
    // Monitor SOF and frame_started
    always @(posedge clk) begin
        if (dut.sof) $display("[%0t] SOF detected!", $time);
        if (dut.u_line_buffer.frame_started && $time < 200000) 
            $display("[%0t] frame_started = 1", $time);
    end
    
    task apb_write(input [7:0] a, input [31:0] d);
        @(posedge clk); psel = 1; pwrite = 1; paddr = a; pwdata = d;
        @(posedge clk); penable = 1;
        @(posedge clk); penable = 0; psel = 0;
    endtask
    
    initial begin
        repeat(10) @(posedge clk); rst_n = 1;
        repeat(5) @(posedge clk);
        
        apb_write(8'h00, 32'b1);  // Enable
        apb_write(8'h04, {16'd16, 16'd16});
        
        $display("=== Testing VSYNC styles ===");
        $display("cfg_enable=%b", dut.cfg_enable);
        
        // Test VSYNC like full testbench
        $display("\n--- Full TB style: vsync<=1, @(clk), vsync<=0 ---");
        vsync <= 1;
        @(posedge clk);
        vsync <= 0;
        repeat(5) @(posedge clk);
        
        $display("din_ready after full TB style: %b", din_ready);
        
        // Test VSYNC like simple testbench  
        $display("\n--- Simple TB style: #0.5 vsync=1, @(clk), #0.5 vsync=0 ---");
        #0.5 vsync = 1;
        @(posedge clk);
        #0.5 vsync = 0;
        @(posedge clk);
        
        $display("din_ready after simple TB style: %b", din_ready);
        
        repeat(100) @(posedge clk);
        $finish;
    end
endmodule
