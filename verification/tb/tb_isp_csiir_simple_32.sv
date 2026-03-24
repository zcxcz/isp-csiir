//-----------------------------------------------------------------------------
// Module: tb_isp_csiir_simple
// Purpose: Simple testbench for ISP-CSIIR quick verification
// Author: rtl-verf
// Date: 2026-03-22
// Version: v1.0
//-----------------------------------------------------------------------------
// Description:
//   Simple testbench for quick verification of ISP-CSIIR module.
//   Focus on basic functionality check with minimal test cases.
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_isp_csiir_simple;

    //=========================================================================
    // Parameters
    //=========================================================================
    parameter IMG_WIDTH       = 32;
    parameter IMG_HEIGHT      = 32;
    parameter DATA_WIDTH      = 10;
    parameter GRAD_WIDTH      = 14;
    parameter LINE_ADDR_WIDTH = 14;
    parameter ROW_CNT_WIDTH   = 13;
    parameter CLK_PERIOD      = 1.67;

    //=========================================================================
    // Signals
    //=========================================================================
    reg                         clk;
    reg                         rst_n;
    reg                         psel, penable, pwrite;
    reg  [7:0]                  paddr;
    reg  [31:0]                 pwdata;
    wire [31:0]                 prdata;
    wire                        pready, pslverr;
    reg                         vsync, hsync;
    reg  [DATA_WIDTH-1:0]       din;
    reg                         din_valid;
    wire [DATA_WIDTH-1:0]       dout;
    wire                        dout_valid, dout_vsync, dout_hsync;

    integer                     pixel_in_count;
    integer                     pixel_out_count;
    integer                     error_count;

    //=========================================================================
    // DUT Instance
    //=========================================================================
    isp_csiir_top #(
        .IMG_WIDTH       (IMG_WIDTH),
        .IMG_HEIGHT      (IMG_HEIGHT),
        .DATA_WIDTH      (DATA_WIDTH),
        .GRAD_WIDTH      (GRAD_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH),
        .ROW_CNT_WIDTH   (ROW_CNT_WIDTH)
    ) dut (.*);

    //=========================================================================
    // Clock
    //=========================================================================
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    //=========================================================================
    // Tasks
    //=========================================================================
    task reset;
        begin
            rst_n <= 0;
            psel <= 0; penable <= 0; pwrite <= 0;
            paddr <= 0; pwdata <= 0;
            vsync <= 0; hsync <= 0;
            din <= 0; din_valid <= 0;
            repeat(10) @(posedge clk);
            rst_n <= 1;
            repeat(5) @(posedge clk);
        end
    endtask

    task apb_write;
        input [7:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            psel <= 1; pwrite <= 1; paddr <= addr; pwdata <= data;
            @(posedge clk);
            penable <= 1;
            @(posedge clk);
            penable <= 0; psel <= 0;
        end
    endtask

    task send_pixel;
        input [DATA_WIDTH-1:0] value;
        begin
            din <= value;
            din_valid <= 1;
            pixel_in_count++;
            @(posedge clk);
            din_valid <= 0;
        end
    endtask

    task send_frame;
        integer x, y;
        begin
            pixel_in_count = 0;

            // VSYNC pulse
            vsync <= 1;
            @(posedge clk);
            vsync <= 0;

            // Send all pixels
            for (y = 0; y < IMG_HEIGHT; y++) begin
                hsync <= 1;
                @(posedge clk);
                hsync <= 0;

                for (x = 0; x < IMG_WIDTH; x++) begin
                    send_pixel((x + y * IMG_WIDTH) % 1024);
                end

                hsync <= 1;
                repeat(3) @(posedge clk);
            end
        end
    endtask

    //=========================================================================
    // Output Monitor
    //=========================================================================
    always @(posedge clk) begin
        if (dout_valid) begin
            pixel_out_count++;
            // Check output range
            if (dout > 1023) begin
                $display("[%0t] ERROR: Output %0d exceeds 10-bit range!", $time, dout);
                error_count++;
            end
        end
    end

    //=========================================================================
    // Main Test
    //=========================================================================
    initial begin
        pixel_out_count = 0;
        error_count = 0;

        $display("\n========================================");
        $display("ISP-CSIIR Simple Testbench");
        $display("Image: %0d x %0d", IMG_WIDTH, IMG_HEIGHT);
        $display("========================================\n");

        // Reset
        reset();
        $display("[%0t] Reset complete", $time);

        // Configure
        apb_write(8'h00, 32'b1);    // Enable
        apb_write(8'h04, {IMG_HEIGHT, IMG_WIDTH});
        apb_write(8'h0C, 32'd16);
        apb_write(8'h10, 32'd24);
        apb_write(8'h14, 32'd32);
        apb_write(8'h18, 32'd40);
        apb_write(8'h1C, 32'd32);
        apb_write(8'h20, 32'd400);
        $display("[%0t] Configuration complete", $time);

        // Send frame
        send_frame();
        $display("[%0t] Frame sent, pixels in = %0d", $time, pixel_in_count);

        // Wait for output
        repeat(IMG_WIDTH * IMG_HEIGHT + 100) @(posedge clk);

        $display("\n========================================");
        $display("Test Results:");
        $display("  Pixels In:    %0d", pixel_in_count);
        $display("  Pixels Out:   %0d", pixel_out_count);
        $display("  Errors:       %0d", error_count);
        $display("========================================\n");

        if (pixel_out_count >= pixel_in_count - 10 && error_count == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED");

        #1000;
        $finish;
    end

    // Timeout
    initial begin
        #100000;
        $display("[%0t] Timeout!", $time);
        $finish;
    end

    // Waveform
    initial begin
        $dumpfile("tb_isp_csiir_simple.vcd");
        $dumpvars(0, tb_isp_csiir_simple);
    end

endmodule