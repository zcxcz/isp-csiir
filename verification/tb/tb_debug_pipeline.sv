//-----------------------------------------------------------------------------
// Module: tb_debug_pipeline
// Purpose: Debug pipeline valid signal propagation
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_debug_pipeline;

    parameter IMG_WIDTH       = 16;
    parameter IMG_HEIGHT      = 16;
    parameter DATA_WIDTH      = 10;
    parameter GRAD_WIDTH      = 14;
    parameter LINE_ADDR_WIDTH = 14;
    parameter ROW_CNT_WIDTH   = 13;
    parameter CLK_PERIOD      = 1.67;

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

    // DUT Instance
    isp_csiir_top #(
        .IMG_WIDTH       (IMG_WIDTH),
        .IMG_HEIGHT      (IMG_HEIGHT),
        .DATA_WIDTH      (DATA_WIDTH),
        .GRAD_WIDTH      (GRAD_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH),
        .ROW_CNT_WIDTH   (ROW_CNT_WIDTH)
    ) dut (.*);

    // Clock
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    // Tasks
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
                // Send pixels first
                for (x = 0; x < IMG_WIDTH; x++) begin
                    send_pixel((x + y * IMG_WIDTH) % 1024);
                end

                // HSYNC pulse at END of row (indicates eol)
                hsync <= 1;
                @(posedge clk);
                hsync <= 0;
                repeat(3) @(posedge clk);
            end
        end
    endtask

    // Pipeline signal probes
    wire s1_valid = dut.s1_valid;
    wire s2_valid = dut.s2_valid;
    wire s3_valid = dut.s3_valid;
    wire s4_dout_valid = dut.s4_dout_valid;
    wire window_valid = dut.window_valid;

    // Stage 3 internal signals
    wire s3_row_valid = dut.u_stage3.row_valid;
    wire s3_col_counter = dut.u_stage3.col_counter;
    wire s3_flush_active = dut.u_stage3.flush_active;
    wire s3_valid_s0 = dut.u_stage3.valid_s0;
    wire s3_valid_s1 = dut.u_stage3.valid_s1;
    wire s3_valid_s2 = dut.u_stage3.valid_s2;
    wire s3_valid_s3 = dut.u_stage3.valid_s3;
    wire s3_valid_s4 = dut.u_stage3.valid_s4;

    // Valid signal counters
    integer window_valid_count = 0;
    integer s1_valid_count = 0;
    integer s2_valid_count = 0;
    integer s3_valid_count = 0;
    integer s4_valid_count = 0;

    always @(posedge clk) begin
        if (window_valid) window_valid_count++;
        if (s1_valid) s1_valid_count++;
        if (s2_valid) s2_valid_count++;
        if (s3_valid) s3_valid_count++;
        if (s4_dout_valid) s4_valid_count++;
        if (dout_valid) pixel_out_count++;
    end

    // Main Test
    initial begin
        pixel_out_count = 0;

        $display("\n========================================");
        $display("Pipeline Debug Test");
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

        // Wait for pipeline to drain
        repeat(IMG_WIDTH * 3 + 50) @(posedge clk);

        $display("\n========================================");
        $display("Valid Signal Counts:");
        $display("  window_valid: %0d", window_valid_count);
        $display("  s1_valid:     %0d", s1_valid_count);
        $display("  s2_valid:     %0d", s2_valid_count);
        $display("  s3_valid:     %0d", s3_valid_count);
        $display("  s4_valid:     %0d", s4_valid_count);
        $display("  dout_valid:   %0d", pixel_out_count);
        $display("========================================\n");

        if (pixel_out_count >= pixel_in_count - 20)
            $display("TEST PASSED");
        else
            $display("TEST FAILED - Expected ~%0d outputs, got %0d", pixel_in_count, pixel_out_count);

        #1000;
        $finish;
    end

    // Timeout
    initial begin
        #500000;
        $display("[%0t] Timeout!", $time);
        $finish;
    end

endmodule