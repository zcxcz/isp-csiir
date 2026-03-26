//-----------------------------------------------------------------------------
// Module: tb_isp_csiir_top
// Purpose: Testbench for ISP-CSIIR module verification
// Author: rtl-verf
// Date: 2026-03-22
// Version: v1.1
//-----------------------------------------------------------------------------
// Description:
//   SystemVerilog testbench for isp_csiir_top module.
//   Compatible with Icarus Verilog.
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_isp_csiir_top;

    //=========================================================================
    // Parameters
    //=========================================================================
    parameter IMG_WIDTH       = 32;
    parameter IMG_HEIGHT      = 32;
    parameter DATA_WIDTH      = 10;
    parameter GRAD_WIDTH      = 14;
    parameter LINE_ADDR_WIDTH = 14;
    parameter ROW_CNT_WIDTH   = 13;
    parameter CLK_PERIOD      = 1.67;  // 600MHz

    //=========================================================================
    // DUT Signals
    //=========================================================================
    reg                         clk;
    reg                         rst_n;

    // APB Interface
    reg                         psel;
    reg                         penable;
    reg                         pwrite;
    reg  [7:0]                  paddr;
    reg  [31:0]                 pwdata;
    wire [31:0]                 prdata;
    wire                        pready;
    wire                        pslverr;

    // Video Input
    reg                         vsync;
    reg                         hsync;
    reg  [DATA_WIDTH-1:0]       din;
    reg                         din_valid;
    wire                        din_ready;

    // Video Output
    wire [DATA_WIDTH-1:0]       dout;
    wire                        dout_valid;
    wire                        dout_vsync;
    wire                        dout_hsync;
    wire                        dout_ready;

    //=========================================================================
    // Test Variables
    //=========================================================================
    integer                     test_pass_count;
    integer                     test_fail_count;
    integer                     pixel_in_count;
    integer                     pixel_out_count;
    integer                     error_count;
    integer                     min_output;
    integer                     max_output;

    // Test control
    reg                         test_done;
    string                      test_name;

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
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .psel           (psel),
        .penable        (penable),
        .pwrite         (pwrite),
        .paddr          (paddr),
        .pwdata         (pwdata),
        .prdata         (prdata),
        .pready         (pready),
        .pslverr        (pslverr),
        .vsync          (vsync),
        .hsync          (hsync),
        .din            (din),
        .din_valid      (din_valid),
        .din_ready      (din_ready),
        .dout           (dout),
        .dout_valid     (dout_valid),
        .dout_ready     (dout_ready),
        .dout_vsync     (dout_vsync),
        .dout_hsync     (dout_hsync)
    );

    //=========================================================================
    // Ready Signal Drive
    //=========================================================================
    // Always ready for output (no back-pressure)
    assign dout_ready = 1'b1;

    //=========================================================================
    // Clock Generation
    //=========================================================================
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    //=========================================================================
    // Output Monitor
    //=========================================================================
    always @(posedge clk) begin
        if (dout_valid) begin
            pixel_out_count++;
            // Track min/max
            if (pixel_out_count == 1) begin
                min_output = dout;
                max_output = dout;
            end else begin
                if (dout < min_output) min_output = dout;
                if (dout > max_output) max_output = dout;
            end
            // Check output range
            if (dout > 1023) begin
                $display("[%0t] ERROR: Output %0d exceeds 10-bit range!", $time, dout);
                error_count++;
            end
        end
    end

    // Debug: monitor pipeline stages
    integer s1_cnt, s2_cnt, s3_cnt, s4_cnt;
    integer lb_window_cnt;
    integer din_accepted_cnt;
    integer flush_complete_cnt;
    integer eol_cnt;
    integer normal_window_cnt;
    integer flush_window_cnt;
    always @(posedge clk) begin
        if (dut.s1_valid) s1_cnt++;
        if (dut.s2_valid) s2_cnt++;
        if (dut.s3_valid) s3_cnt++;
        if (dut.s4_dout_valid) s4_cnt++;
        if (dut.u_line_buffer.window_valid) lb_window_cnt++;
        if (dut.din_valid && dut.din_ready) din_accepted_cnt++;
        // Count normal vs flush windows
        if (dut.u_line_buffer.window_valid_next) begin
            if (dut.u_line_buffer.flush_active)
                flush_window_cnt++;
            else
                normal_window_cnt++;
        end
        // Track flush complete
        if (dut.u_line_buffer.flush_active && dut.u_line_buffer.flush_cnt == 1)
            flush_complete_cnt++;
        if (dut.eol) eol_cnt++;
    end

    // Task to reset debug counters
    task reset_debug_counters;
        begin
            s1_cnt = 0;
            s2_cnt = 0;
            s3_cnt = 0;
            s4_cnt = 0;
            lb_window_cnt = 0;
            din_accepted_cnt = 0;
            flush_complete_cnt = 0;
            eol_cnt = 0;
            normal_window_cnt = 0;
            flush_window_cnt = 0;
        end
    endtask

    //=========================================================================
    // Tasks
    //=========================================================================

    // Reset task
    task reset_dut;
        begin
            rst_n    = 1'b0;
            psel     = 1'b0;
            penable  = 1'b0;
            pwrite   = 1'b0;
            paddr    = 8'b0;
            pwdata   = 32'b0;
            vsync    = 1'b0;
            hsync    = 1'b0;
            din      = {DATA_WIDTH{1'b0}};
            din_valid = 1'b0;
            repeat(10) @(posedge clk);
            rst_n    = 1'b1;
            repeat(5) @(posedge clk);
            $display("[%0t] Reset complete", $time);
        end
    endtask

    // APB write task
    task apb_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(posedge clk);
            psel    = 1'b1;
            pwrite  = 1'b1;
            paddr   = addr;
            pwdata  = data;
            @(posedge clk);
            penable = 1'b1;
            @(posedge clk);
            penable = 1'b0;
            psel    = 1'b0;
            @(posedge clk);
        end
    endtask

    // Configure DUT
    task configure_dut;
        input enable;
        input bypass;
        begin
            // CTRL register: enable and bypass
            apb_write(8'h00, {30'b0, bypass, enable});
            // PIC_SIZE register - must use 16-bit values for proper concatenation
            apb_write(8'h04, {16'(IMG_HEIGHT), 16'(IMG_WIDTH)});
            // Thresholds
            apb_write(8'h0C, 32'd16);  // THRESH0
            apb_write(8'h10, 32'd24);  // THRESH1
            apb_write(8'h14, 32'd32);  // THRESH2
            apb_write(8'h18, 32'd40);  // THRESH3
            // Blending ratios
            apb_write(8'h1C, 32'd32);  // BLEND_RATIO
            // Clip thresholds
            apb_write(8'h20, 32'd400); // CLIP_Y
            apb_write(8'h24, 32'd2);   // CLIP_SFT
            $display("[%0t] Configuration complete", $time);
        end
    endtask

    // Send one frame
    task send_frame;
        input integer pattern_type;  // 0: zero, 1: max, 2: ramp, 3: random
        integer y, x;
        integer pixel_val;
        begin
            pixel_in_count = 0;

            // Start of frame - use blocking assignments with setup time for proper edge detection
            #0.5 vsync = 1'b1;
            @(posedge clk);
            #0.5 vsync = 1'b0;
            @(posedge clk);  // Extra cycle for frame_started to be set

            // Send pixels
            for (y = 0; y < IMG_HEIGHT; y++) begin
                // Send pixels first
                for (x = 0; x < IMG_WIDTH; x++) begin
                    // Generate pattern
                    case (pattern_type)
                        0: pixel_val = 0;
                        1: pixel_val = 1023;
                        2: pixel_val = (x + y * IMG_WIDTH) % 1024;
                        3: pixel_val = {$random} % 1024;
                        default: pixel_val = 512;
                    endcase

                    din      = pixel_val[DATA_WIDTH-1:0];
                    din_valid = 1'b1;
                    pixel_in_count++;
                    @(posedge clk);
                    // Only wait for din_ready in processing mode (not bypass)
                    // In bypass mode, din_ready is 0 but data still flows through bypass path
                    if (!dut.cfg_bypass) begin
                        while (!din_ready) @(posedge clk);
                    end
                    din_valid = 1'b0;  // Clear after handshake
                end

                // HSYNC pulse at END of row (indicates EOL)
                din_valid = 1'b0;
                #0.5 hsync = 1'b1;
                @(posedge clk);
                #0.5 hsync = 1'b0;
                repeat(3) @(posedge clk);
            end

            $display("[%0t] Frame sent, pixels in = %0d", $time, pixel_in_count);
        end
    endtask

    // Check output validity
    task check_output;
        integer timeout;
        begin
            timeout = 0;

            // Wait for outputs - need extra time for:
            // 1. Line buffer startup (2 rows)
            // 2. Stage 3 row delay buffer (1 row)
            // 3. Pipeline stages (~10 cycles)
            // 4. Stage 3 flush at end of frame (1 row)
            // Total: IMG_WIDTH * IMG_HEIGHT + extra rows + margin
            repeat(IMG_WIDTH * IMG_HEIGHT * 2 + 1000) begin
                @(posedge clk);
                if (dout_valid) begin
                    // Output captured by monitor
                end
            end

            $display("[%0t] Output statistics:", $time);
            $display("  Pixels in:    %0d", pixel_in_count);
            $display("  Pixels out:   %0d", pixel_out_count);
            $display("  Pipeline:     S1=%0d S2=%0d S3=%0d S4=%0d", s1_cnt, s2_cnt, s3_cnt, s4_cnt);
            $display("  Output range: %0d - %0d", min_output, max_output);
            $display("  Errors:       %0d", error_count);

            if (pixel_out_count >= pixel_in_count - 10 && error_count == 0) begin
                $display("  Result: PASS");
                test_pass_count++;
            end else begin
                $display("  Result: FAIL");
                test_fail_count++;
            end
        end
    endtask

    //=========================================================================
    // Test Cases
    //=========================================================================

    // Smoke Test
    task smoke_test;
        begin
            test_name = "SMOKE_TEST";
            pixel_out_count = 0;
            error_count = 0;
            min_output = 1024;
            max_output = 0;
            reset_debug_counters();

            $display("\n========================================");
            $display("[%0t] Starting Smoke Test", $time);
            $display("========================================\n");

            reset_dut();
            configure_dut(1'b1, 1'b0);  // Enable, no bypass

            // Generate ramp pattern
            send_frame(2);

            // Check output
            check_output();

            $display("[%0t] Smoke Test Complete\n", $time);
        end
    endtask

    // Random Test
    task random_test;
        begin
            test_name = "RANDOM_TEST";
            pixel_out_count = 0;
            error_count = 0;
            min_output = 1024;
            max_output = 0;
            reset_debug_counters();

            $display("\n========================================");
            $display("[%0t] Starting Random Test", $time);
            $display("========================================\n");

            reset_dut();
            configure_dut(1'b1, 1'b0);

            send_frame(3);  // Random pattern

            check_output();

            $display("[%0t] Random Test Complete\n", $time);
        end
    endtask

    // Bypass Test
    task bypass_test;
        begin
            test_name = "BYPASS_TEST";
            pixel_out_count = 0;
            error_count = 0;
            min_output = 1024;
            max_output = 0;
            reset_debug_counters();

            $display("\n========================================");
            $display("[%0t] Starting Bypass Test", $time);
            $display("========================================\n");

            reset_dut();
            configure_dut(1'b1, 1'b1);  // Enable with bypass

            send_frame(2);

            check_output();

            $display("[%0t] Bypass Test Complete\n", $time);
        end
    endtask

    // Zero Input Test
    task zero_input_test;
        begin
            test_name = "ZERO_INPUT_TEST";
            pixel_out_count = 0;
            error_count = 0;
            min_output = 1024;
            max_output = 0;
            reset_debug_counters();

            $display("\n========================================");
            $display("[%0t] Starting Zero Input Test", $time);
            $display("========================================\n");

            reset_dut();
            configure_dut(1'b1, 1'b0);

            send_frame(0);  // All zeros

            check_output();

            $display("[%0t] Zero Input Test Complete\n", $time);
        end
    endtask

    // Max Input Test
    task max_input_test;
        begin
            test_name = "MAX_INPUT_TEST";
            pixel_out_count = 0;
            error_count = 0;
            min_output = 1024;
            max_output = 0;
            reset_debug_counters();

            $display("\n========================================");
            $display("[%0t] Starting Max Input Test", $time);
            $display("========================================\n");

            reset_dut();
            configure_dut(1'b1, 1'b0);

            send_frame(1);  // All max

            check_output();

            $display("[%0t] Max Input Test Complete\n", $time);
        end
    endtask

    //=========================================================================
    // Main Test Flow
    //=========================================================================
    initial begin
        test_pass_count = 0;
        test_fail_count = 0;
        test_done = 0;

        $display("\n========================================");
        $display("ISP-CSIIR Verification Environment v1.1");
        $display("Image Size: %0d x %0d", IMG_WIDTH, IMG_HEIGHT);
        $display("Clock Period: %.2f ns (%.0f MHz)", CLK_PERIOD, 1000/CLK_PERIOD);
        $display("========================================\n");

        // Run tests
        smoke_test();
        bypass_test();
        zero_input_test();
        max_input_test();
        random_test();

        // Print results
        $display("\n========================================");
        $display("Test Results Summary");
        $display("========================================");
        $display("Tests Passed: %0d", test_pass_count);
        $display("Tests Failed: %0d", test_fail_count);

        if (test_fail_count == 0)
            $display("\nALL TESTS PASSED");
        else
            $display("\nSOME TESTS FAILED");

        $display("========================================\n");

        test_done = 1;
        #1000;
        $finish;
    end

    // Timeout watchdog
    initial begin
        #50000000;  // 50ms timeout for multiple tests
        if (!test_done) begin
            $display("[%0t] ERROR: Simulation timeout!", $time);
            $finish;
        end
    end

    // VCD dump for waveform analysis
    initial begin
        $dumpfile("tb_isp_csiir_top.vcd");
        $dumpvars(0, tb_isp_csiir_top);
    end

endmodule