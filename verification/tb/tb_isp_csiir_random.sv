//-----------------------------------------------------------------------------
// Module: tb_isp_csiir_random
// Purpose: Configuration-driven random testbench for ISP-CSIIR
// Author: rtl-verf
// Date: 2026-03-23
// Version: v2.2 - Added valid/ready handshake protocol support
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_isp_csiir_random;

    //=========================================================================
    // Parameters - Support larger images
    //=========================================================================
    parameter MAX_WIDTH       = 256;
    parameter MAX_HEIGHT      = 256;
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
    wire                        din_ready;
    wire [DATA_WIDTH-1:0]       dout;
    wire                        dout_valid;
    reg                         dout_ready;
    wire                        dout_vsync, dout_hsync;

    //=========================================================================
    // Test Variables
    //=========================================================================
    integer                     pixel_in_count;
    integer                     pixel_out_count;
    integer                     error_count;
    integer                     output_file;

    // Configuration from file
    integer                     cfg_width, cfg_height;
    integer                     cfg_thresh0, cfg_thresh1, cfg_thresh2, cfg_thresh3;
    integer                     cfg_ratio0, cfg_ratio1, cfg_ratio2, cfg_ratio3;
    integer                     cfg_clip0, cfg_clip1, cfg_clip2, cfg_clip3;

    // Stimulus memory
    reg [DATA_WIDTH-1:0]        stimulus_mem [0:MAX_WIDTH*MAX_HEIGHT-1];
    integer                     stimulus_count;

    //=========================================================================
    // DUT Instance
    //=========================================================================
    isp_csiir_top #(
        .IMG_WIDTH       (MAX_WIDTH),
        .IMG_HEIGHT      (MAX_HEIGHT),
        .DATA_WIDTH      (DATA_WIDTH),
        .GRAD_WIDTH      (GRAD_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH),
        .ROW_CNT_WIDTH   (ROW_CNT_WIDTH)
    ) dut (.*);

    //=========================================================================
    // Ready Signal Drive
    //=========================================================================
    // Always ready for output (no back-pressure)
    assign dout_ready = 1'b1;

    //=========================================================================
    // Clock
    //=========================================================================
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    //=========================================================================
    // Tasks - Match simple testbench exactly
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
            // Wait for handshake (din_ready should always be high in this test)
            @(posedge clk);
            while (!din_ready) @(posedge clk);
            din_valid <= 0;
        end
    endtask

    // Send frame with stimulus data
    task send_frame;
        integer x, y, idx;
        begin
            pixel_in_count = 0;
            idx = 0;

            // Set vsync with proper timing for sof detection
            // Set vsync in middle of clock cycle (setup time)
            #2;
            vsync = 1;  // Blocking assignment for immediate effect
            @(posedge clk);  // SOF detected at this clock edge
            #2;
            vsync = 0;  // Deassert in middle of next cycle
            @(posedge clk);  // Extra cycle for frame_started to be set

            for (y = 0; y < cfg_height; y++) begin
                // Send pixels first (same as simple testbench)
                for (x = 0; x < cfg_width; x++) begin
                    if (idx < stimulus_count) begin
                        send_pixel(stimulus_mem[idx]);
                        idx++;
                    end else begin
                        send_pixel(0);
                    end
                end

                // HSYNC pulse at END of row (indicates eol)
                @(negedge clk);
                hsync <= 1;
                @(posedge clk);
                hsync <= 0;
                repeat(3) @(posedge clk);
            end
        end
    endtask

    task read_config;
        integer fd;
        begin
            fd = $fopen("config.txt", "r");
            if (fd == 0) begin
                $display("ERROR: Cannot open config.txt");
                $finish;
            end

            $fscanf(fd, "%d", cfg_width);
            $fscanf(fd, "%d", cfg_height);
            $fscanf(fd, "%d", cfg_thresh0);
            $fscanf(fd, "%d", cfg_thresh1);
            $fscanf(fd, "%d", cfg_thresh2);
            $fscanf(fd, "%d", cfg_thresh3);
            $fscanf(fd, "%d", cfg_ratio0);
            $fscanf(fd, "%d", cfg_ratio1);
            $fscanf(fd, "%d", cfg_ratio2);
            $fscanf(fd, "%d", cfg_ratio3);
            $fscanf(fd, "%d", cfg_clip0);
            $fscanf(fd, "%d", cfg_clip1);
            $fscanf(fd, "%d", cfg_clip2);
            $fscanf(fd, "%d", cfg_clip3);
            $fclose(fd);

            $display("Config: %0dx%0d, Thresh=[%0d,%0d,%0d,%0d], Ratio=[%0d,%0d,%0d,%0d], Clip=[%0d,%0d,%0d,%0d]",
                     cfg_width, cfg_height,
                     cfg_thresh0, cfg_thresh1, cfg_thresh2, cfg_thresh3,
                     cfg_ratio0, cfg_ratio1, cfg_ratio2, cfg_ratio3,
                     cfg_clip0, cfg_clip1, cfg_clip2, cfg_clip3);
        end
    endtask

    task read_stimulus;
        integer fd, w, h, i;
        reg [31:0] pixel;
        begin
            fd = $fopen("stimulus.hex", "r");
            if (fd == 0) begin
                $display("ERROR: Cannot open stimulus.hex");
                $finish;
            end

            // Skip header
            $fscanf(fd, "# Image size: %d x %d\n", w, h);
            $fscanf(fd, "%x\n", w);
            $fscanf(fd, "%x\n", h);

            $display("Stimulus file: %0d x %0d", w, h);

            stimulus_count = 0;
            for (i = 0; i < w * h; i++) begin
                $fscanf(fd, "%x\n", pixel);
                stimulus_mem[i] = pixel[DATA_WIDTH-1:0];
                stimulus_count++;
                if (i < 5) begin
                    $display("  stimulus_mem[%0d] = %h", i, stimulus_mem[i]);
                end
            end
            $fclose(fd);

            $display("Loaded %0d stimulus pixels", stimulus_count);
        end
    endtask

    //=========================================================================
    // Output Monitor - Match simple testbench
    //=========================================================================
    // Debug counters for each stage valid
    integer s1_valid_count, s2_valid_count, s3_valid_count, s4_valid_count;
    integer lb_window_valid_count;

    always @(posedge clk) begin
        if (dut.window_valid) lb_window_valid_count++;
        if (dut.s1_valid) s1_valid_count++;
        if (dut.s2_valid) s2_valid_count++;
        if (dut.s3_valid) s3_valid_count++;
        if (dut.s4_dout_valid) s4_valid_count++;

        if (dout_valid) begin
            pixel_out_count++;
            // Write to file if open (just pixel value, hex format)
            if (output_file != 0) begin
                $fdisplay(output_file, "%03x", dout);
            end
            // Check output range
            if (dout > 1023) begin
                $display("[%0t] ERROR: Output %0d exceeds 10-bit range!", $time, dout);
                error_count++;
            end
            // Debug: show first few outputs
            if (pixel_out_count <= 20) begin
                $display("[%0t] Output #%0d: x=%0d y=%0d val=%0d s2_y=%0d s3_y=%0d lb_y=%0d",
                         $time, pixel_out_count,
                         dut.s4_pixel_x, dut.s4_pixel_y, dout,
                         dut.s2_pixel_y, dut.s3_pixel_y, dut.u_line_buffer.center_y);
            end
        end
    end

    //=========================================================================
    // Main Test - Match simple testbench flow
    //=========================================================================
    initial begin
        pixel_out_count = 0;
        error_count = 0;
        output_file = 0;
        lb_window_valid_count = 0;
        s1_valid_count = 0;
        s2_valid_count = 0;
        s3_valid_count = 0;
        s4_valid_count = 0;

        $display("\n========================================");
        $display("ISP-CSIIR Random Testbench v2.2");
        $display("  With valid/ready handshake support");
        $display("========================================\n");

        // Read configuration and stimulus
        read_config();
        read_stimulus();

        // Reset
        reset();
        $display("[%0t] Reset complete", $time);

        // Configure - use values from file
        apb_write(8'h00, 32'b1);    // Enable
        apb_write(8'h04, {cfg_height[15:0], cfg_width[15:0]});
        apb_write(8'h0C, cfg_thresh0);
        apb_write(8'h10, cfg_thresh1);
        apb_write(8'h14, cfg_thresh2);
        apb_write(8'h18, cfg_thresh3);
        apb_write(8'h1C, {cfg_ratio3[7:0], cfg_ratio2[7:0], cfg_ratio1[7:0], cfg_ratio0[7:0]});
        apb_write(8'h20, {6'd0, cfg_clip1[9:0], 6'd0, cfg_clip0[9:0]});
        apb_write(8'h2C, {6'd0, cfg_clip3[9:0], 6'd0, cfg_clip2[9:0]});
        $display("[%0t] Configuration complete", $time);

        // Open output file after configuration
        output_file = $fopen("actual.hex", "w");
        $fdisplay(output_file, "# Actual output: %0d x %0d", cfg_width, cfg_height);
        $fdisplay(output_file, "%04x", cfg_width);
        $fdisplay(output_file, "%04x", cfg_height);

        // Send frame
        send_frame();
        $display("[%0t] Frame sent, pixels in = %0d", $time, pixel_in_count);

        // Wait for outputs
        repeat(cfg_width * cfg_height + 100) @(posedge clk);

        // Close output file
        if (output_file != 0) begin
            $fclose(output_file);
            output_file = 0;  // Reset to prevent writes to closed descriptor
        end

        $display("\n========================================");
        $display("Test Results:");
        $display("  Pixels In:    %0d", pixel_in_count);
        $display("  Pixels Out:   %0d", pixel_out_count);
        $display("  Errors:       %0d", error_count);
        $display("\nDebug Counter (valid cycles):");
        $display("  LB window_valid: %0d", lb_window_valid_count);
        $display("  S1 valid:        %0d", s1_valid_count);
        $display("  S2 valid:        %0d", s2_valid_count);
        $display("  S3 valid:        %0d", s3_valid_count);
        $display("  S4 valid:        %0d", s4_valid_count);
        $display("========================================\n");

        if (pixel_out_count >= pixel_in_count - 20 && error_count == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED");

        #1000;
        $finish;
    end

    // Timeout
    initial begin
        #10000000;  // 10ms timeout
        $display("[%0t] Timeout!", $time);
        $finish;
    end

    // Waveform
    initial begin
        $dumpfile("tb_isp_csiir_random.vcd");
        $dumpvars(0, tb_isp_csiir_random);
    end

    //=========================================================================
    // Debug: Stage 3 Gradient Line Buffer Tracing (simplified)
    //=========================================================================
    integer s3_dbg_cnt;
    initial s3_dbg_cnt = 0;

    // Track Stage 3 buffer write operations (first few only)
    always @(posedge clk) begin
        if (dut.s2_valid && dut.u_stage3.col_counter < 3 && s3_dbg_cnt < 5) begin
            s3_dbg_cnt = s3_dbg_cnt + 1;
            $display("[%0t] S3 Buffer Write: col=%0d grad=%0d",
                $time, dut.u_stage3.col_counter, dut.s2_grad);
        end
    end

    // Track Stage 3 output validation (first few only)
    integer s3_out_cnt;
    initial s3_out_cnt = 0;
    always @(posedge clk) begin
        if (dut.u_stage3.div_valid && s3_out_cnt < 5) begin
            s3_out_cnt = s3_out_cnt + 1;
            $display("[%0t] S3 Divider: pixel (%0d,%0d) grad_sum=%0d",
                $time, dut.u_stage3.pixel_x_s5, dut.u_stage3.pixel_y_s5,
                dut.u_stage3.grad_sum_s4);
        end
    end

    // Track Stage 4 output validation (first few only)
    integer s4_out_cnt;
    initial s4_out_cnt = 0;
    always @(posedge clk) begin
        if (dut.s4_dout_valid && s4_out_cnt < 5) begin
            s4_out_cnt = s4_out_cnt + 1;
            $display("[%0t] S4 Output: pixel (%0d,%0d) dout=%0d",
                $time, dut.s4_pixel_x, dut.s4_pixel_y, dut.s4_dout);
        end
    end

endmodule
