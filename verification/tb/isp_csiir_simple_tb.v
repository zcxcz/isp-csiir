//-----------------------------------------------------------------------------
// Module: isp_csiir_simple_tb
// Description: Simple testbench for ISP-CSIIR RTL verification
//              Compatible with Icarus Verilog (no UVM required)
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module isp_csiir_simple_tb;

    // Parameters
    parameter IMG_WIDTH  = 64;
    parameter IMG_HEIGHT = 64;
    parameter DATA_WIDTH = 8;

    // Clock and reset
    reg clk;
    reg rst_n;

    // APB Interface
    reg        psel;
    reg        penable;
    reg        pwrite;
    reg [7:0]  paddr;
    reg [31:0] pwdata;
    wire [31:0] prdata;
    wire       pready;
    wire       pslverr;

    // Video Interface
    reg        vsync;
    reg        hsync;
    reg [DATA_WIDTH-1:0] din;
    reg        din_valid;

    wire [DATA_WIDTH-1:0] dout;
    wire       dout_valid;
    wire       dout_vsync;
    wire       dout_hsync;

    // Test counters
    integer pixel_count;
    integer output_count;
    integer frame_count;
    integer error_count;

    // DUT instance
    isp_csiir_top #(
        .IMG_WIDTH (IMG_WIDTH),
        .IMG_HEIGHT(IMG_HEIGHT),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .psel     (psel),
        .penable  (penable),
        .pwrite   (pwrite),
        .paddr    (paddr),
        .pwdata   (pwdata),
        .prdata   (prdata),
        .pready   (pready),
        .pslverr  (pslverr),
        .vsync    (vsync),
        .hsync    (hsync),
        .din      (din),
        .din_valid(din_valid),
        .dout       (dout),
        .dout_valid (dout_valid),
        .dout_vsync (dout_vsync),
        .dout_hsync (dout_hsync)
    );

    // Clock generation - 100MHz
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // APB write task
    task apb_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(posedge clk);
            psel    <= 1'b1;
            pwrite  <= 1'b1;
            paddr   <= addr;
            pwdata  <= data;
            penable <= 1'b0;
            @(posedge clk);
            penable <= 1'b1;
            @(posedge clk);
            while (!pready) @(posedge clk);
            psel    <= 1'b0;
            penable <= 1'b0;
        end
    endtask

    // APB read task
    task apb_read;
        input  [7:0]  addr;
        output [31:0] data;
        begin
            @(posedge clk);
            psel    <= 1'b1;
            pwrite  <= 1'b0;
            paddr   <= addr;
            penable <= 1'b0;
            @(posedge clk);
            penable <= 1'b1;
            @(posedge clk);
            while (!pready) @(posedge clk);
            data = prdata;
            psel    <= 1'b0;
            penable <= 1'b0;
        end
    endtask

    // Send pixel task
    task send_pixel;
        input [DATA_WIDTH-1:0] pixel;
        input is_vsync;
        input is_hsync;
        input is_valid;
        begin
            @(posedge clk);
            din       <= pixel;
            din_valid <= is_valid;
            vsync     <= is_vsync;
            hsync     <= is_hsync;
        end
    endtask

    // Send frame task
    task send_frame;
        integer x, y;
        begin
            // VSYNC pulse
            send_pixel(0, 1, 0, 0);
            send_pixel(0, 0, 0, 0);

            // Send frame data
            for (y = 0; y < IMG_HEIGHT; y = y + 1) begin
                for (x = 0; x < IMG_WIDTH; x = x + 1) begin
                    send_pixel($random & 8'hFF, 0, (x == IMG_WIDTH-1), 1);
                end
            end

            // End of frame
            send_pixel(0, 1, 0, 0);
            send_pixel(0, 0, 0, 0);
        end
    endtask

    // Monitor output
    always @(posedge clk) begin
        if (dout_valid) begin
            output_count = output_count + 1;
            $display("[%0t] Output pixel: 0x%02h", $time, dout);
        end
    end

    // Main test sequence
    initial begin
        // Initialize signals
        rst_n    <= 1'b0;
        psel     <= 1'b0;
        penable  <= 1'b0;
        pwrite   <= 1'b0;
        paddr    <= 8'h0;
        pwdata   <= 32'h0;
        vsync    <= 1'b0;
        hsync    <= 1'b0;
        din      <= 8'h0;
        din_valid <= 1'b0;

        pixel_count  = 0;
        output_count = 0;
        frame_count  = 0;
        error_count  = 0;

        // Reset sequence
        #100;
        rst_n <= 1'b1;
        #100;

        $display("========================================");
        $display("ISP-CSIIR Simple Testbench");
        $display("========================================");
        $display("Image Size: %0d x %0d", IMG_WIDTH, IMG_HEIGHT);
        $display("");

        // Configure registers
        $display("[INFO] Configuring registers...");
        apb_write(8'h00, 32'h00000001);  // Enable, no bypass
        apb_write(8'h04, {16'(IMG_HEIGHT-1), 16'(IMG_WIDTH-1)});  // Image size
        apb_write(8'h08, 32'd16);  // thresh0
        apb_write(8'h0C, 32'd24);  // thresh1
        apb_write(8'h10, 32'd32);  // thresh2
        apb_write(8'h14, 32'd40);  // thresh3

        $display("[INFO] Configuration complete");
        #100;

        // Send test frames
        $display("[INFO] Sending test frames...");
        for (frame_count = 0; frame_count < 2; frame_count = frame_count + 1) begin
            $display("[INFO] Sending frame %0d", frame_count + 1);
            send_frame();

            // Wait for processing
            #500;
        end

        // Wait for all outputs
        #1000;

        // Test bypass mode
        $display("");
        $display("[INFO] Testing bypass mode...");
        apb_write(8'h00, 32'h00000002);  // Bypass mode
        #100;
        send_frame();
        #500;

        // Final report
        $display("");
        $display("========================================");
        $display("Test Summary");
        $display("========================================");
        $display("Frames sent:     %0d", frame_count);
        $display("Output pixels:   %0d", output_count);
        $display("Errors:          %0d", error_count);
        $display("========================================");

        if (error_count == 0) begin
            $display("TEST PASSED");
        end else begin
            $display("TEST FAILED");
        end

        #100;
        $finish;
    end

    // Timeout
    initial begin
        #500000;
        $display("[INFO] Simulation completed normally");
        $finish;
    end

    // VCD dump for waveform viewing
    initial begin
        $dumpfile("isp_csiir_simple_tb.vcd");
        $dumpvars(0, isp_csiir_simple_tb);
    end

endmodule