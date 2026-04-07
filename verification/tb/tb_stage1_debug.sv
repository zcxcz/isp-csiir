`timescale 1ns/1ps

module tb_stage1_debug;

    reg clk, rst_n;
    reg psel, penable, pwrite;
    reg [7:0] paddr;
    reg [31:0] pwdata;
    wire [31:0] prdata;
    wire pready, pslverr;
    reg vsync, hsync;
    reg [9:0] din;
    reg din_valid;
    wire [9:0] dout;
    wire dout_valid, dout_vsync, dout_hsync, din_ready;
    reg dout_ready;

    wire top_sof, frame_started;

    isp_csiir_top dut (
        .clk(clk), .rst_n(rst_n),
        .psel(psel), .penable(penable), .pwrite(pwrite),
        .paddr(paddr), .pwdata(pwdata), .prdata(prdata),
        .pready(pready), .pslverr(pslverr),
        .vsync(vsync), .hsync(hsync),
        .din(din), .din_valid(din_valid), .din_ready(din_ready),
        .dout(dout), .dout_valid(dout_valid), .dout_ready(dout_ready),
        .dout_vsync(dout_vsync), .dout_hsync(dout_hsync)
    );

    assign dout_ready = 1'b1;
    assign top_sof = dut.sof;
    assign frame_started = dut.u_line_buffer.frame_started;

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    initial begin
        rst_n = 0;
        psel = 0; penable = 0; pwrite = 0;
        paddr = 0; pwdata = 0;
        vsync = 0; hsync = 0; din = 0; din_valid = 0;
        
        repeat(3) @(posedge clk);
        rst_n = 1;
        repeat(3) @(posedge clk);
        
        // Configure enable
        @(posedge clk);
        psel = 1; pwrite = 1; paddr = 8'h00; pwdata = 32'b1;
        @(posedge clk);
        penable = 1;
        @(posedge clk);
        penable = 0; psel = 0;
        
        repeat(3) @(posedge clk);
        
        // VSYNC pulse with proper timing
        $display("[%0t] Setting vsync=1 (in middle of clock cycle)", $time);
        #2;  // Wait for middle of cycle (setup time)
        vsync = 1;  // Set in middle of low phase
        #3;  // Wait to near end of cycle
        $display("[%0t] vsync=%b, about to hit clock edge", $time, vsync);
        @(posedge clk);  // Clock edge - SOF detected here
        $display("[%0t] After clock: sof=%b frame_started=%b", $time, top_sof, frame_started);
        #2;
        vsync = 0;  // Deassert in middle of next cycle
        @(posedge clk);
        
        $display("[%0t] Final: frame_started=%b din_ready=%b", $time, frame_started, din_ready);
        
        repeat(5) @(posedge clk);
        $finish;
    end

    initial begin #200000; $display("Timeout"); $finish; end

endmodule
