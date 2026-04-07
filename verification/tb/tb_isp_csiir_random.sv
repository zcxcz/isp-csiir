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
    integer                     cfg_clip_sft0, cfg_clip_sft1, cfg_clip_sft2, cfg_clip_sft3;
    integer                     cfg_mot_protect;

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
            $fscanf(fd, "%d", cfg_clip_sft0);
            $fscanf(fd, "%d", cfg_clip_sft1);
            $fscanf(fd, "%d", cfg_clip_sft2);
            $fscanf(fd, "%d", cfg_clip_sft3);
            $fscanf(fd, "%d", cfg_mot_protect);
            $fclose(fd);

            $display("Config: %0dx%0d, Thresh=[%0d,%0d,%0d,%0d], Ratio=[%0d,%0d,%0d,%0d], Clip=[%0d,%0d,%0d,%0d], ClipSft=[%0d,%0d,%0d,%0d], MotProtect=%0d",
                     cfg_width, cfg_height,
                     cfg_thresh0, cfg_thresh1, cfg_thresh2, cfg_thresh3,
                     cfg_ratio0, cfg_ratio1, cfg_ratio2, cfg_ratio3,
                     cfg_clip0, cfg_clip1, cfg_clip2, cfg_clip3,
                     cfg_clip_sft0, cfg_clip_sft1, cfg_clip_sft2, cfg_clip_sft3,
                     cfg_mot_protect);
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
        apb_write(8'h24, {cfg_clip_sft3[7:0], cfg_clip_sft2[7:0], cfg_clip_sft1[7:0], cfg_clip_sft0[7:0]});
        apb_write(8'h28, cfg_mot_protect);
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
    // Debug: Stage 3 Row Delay Buffer Tracing
    //=========================================================================
    integer s3_dbg_cnt;
    initial s3_dbg_cnt = 0;

    // Track Stage 3 buffer write operations (first few only)
    always @(posedge clk) begin
        if (dut.s2_valid && dut.u_stage3.col_counter < 3 && s3_dbg_cnt < 5) begin
            s3_dbg_cnt = s3_dbg_cnt + 1;
            $display("[%0t] S3 Buffer Write: col=%0d grad=%0d avg_buf_sel=%0d",
                $time, dut.u_stage3.col_counter, dut.s2_grad, dut.u_stage3.avg_buf_sel);
        end
    end

    // Track Stage 3 output validation (first few only)
    integer s3_out_cnt;
    initial s3_out_cnt = 0;
    always @(posedge clk) begin
        if (dut.u_stage3.valid_s0_comb && s3_out_cnt < 300) begin
            s3_out_cnt = s3_out_cnt + 1;
            $display("[%0t] S3 Valid: col=%0d buf=%0d px=%0d py=%0d flush=%0d",
                $time, dut.u_stage3.rd_col_d, dut.u_stage3.avg_buf_sel_d,
                dut.u_stage3.pixel_x_rd, dut.u_stage3.pixel_y_rd, dut.u_stage3.flush_active);
        end
    end

    // Track flush trigger condition
    always @(posedge clk) begin
        if (dut.u_stage3.stage2_stopped && !dut.u_stage3.flush_active) begin
            $display("[FLUSH TRIGGER] time=%0t row_counter=%0d col_counter=%0d avg_buf_sel=%0d last_row_complete=%0d",
                $time, dut.u_stage3.row_counter, dut.u_stage3.col_counter, dut.u_stage3.avg_buf_sel, dut.u_stage3.last_row_complete);
        end
    end

    // Track EOL toggle
    always @(posedge clk) begin
        if (dut.s2_valid && dut.u_stage3.col_counter == 15) begin
            $display("[EOL] time=%0t row_counter=%0d col_counter=%0d avg_buf_sel=%0d (about to toggle)",
                $time, dut.u_stage3.row_counter, dut.u_stage3.col_counter, dut.u_stage3.avg_buf_sel);
        end
    end

    // Track Stage 3 final output (for comparison with golden)
    integer s3_final_cnt;
    initial s3_final_cnt = 0;
    always @(posedge clk) begin
        if (dut.s3_valid && s3_final_cnt < 30) begin
            s3_final_cnt = s3_final_cnt + 1;
            $display("[S3 FINAL %0d] px=%0d py=%0d blend0=%0d blend1=%0d avg0_u=%0d win_size=%0d center=%0d grad_sum_zero=%0d avg0_avg=%0d avg1_avg=%0d",
                s3_final_cnt, dut.s3_pixel_x, dut.s3_pixel_y,
                $signed(dut.s3_blend0), $signed(dut.s3_blend1),
                $signed(dut.s3_avg0_u), dut.s3_win_size_clip, dut.s3_center_pixel,
                dut.u_stage3.grad_sum_zero_s5,
                $signed(dut.u_stage3.avg0_avg_s5), $signed(dut.u_stage3.avg1_avg_s5));
        end
    end

    // Track Stage 2 output with avg values
    integer s2_out_cnt;
    initial s2_out_cnt = 0;
    always @(posedge clk) begin
        if (dut.s2_valid && s2_out_cnt < 20) begin
            s2_out_cnt = s2_out_cnt + 1;
            $display("[S2 OUT %0d] px=%0d py=%0d avg0_c=%0d avg0_u=%0d grad=%0d win_size=%0d center=%0d",
                s2_out_cnt, dut.s2_pixel_x, dut.s2_pixel_y,
                $signed(dut.u_stage2.avg0_c), $signed(dut.u_stage2.avg0_u),
                dut.s2_grad, dut.s2_win_size_clip, dut.s2_center_pixel);
        end
    end

    // Track Stage 3 pipeline avg_s2 values
    integer s3_s2_cnt;
    initial s3_s2_cnt = 0;
    always @(posedge clk) begin
        if (dut.u_stage3.valid_s2 && s3_s2_cnt < 10) begin
            s3_s2_cnt = s3_s2_cnt + 1;
            $display("[S3 S2 %0d] avg0_s2[0]=%0d avg0_s2[1]=%0d avg0_s2[2]=%0d avg0_s2[3]=%0d avg0_s2[4]=%0d avg0_sum=%0d avg0_avg=%0d",
                s3_s2_cnt,
                $signed(dut.u_stage3.avg0_s2[0]), $signed(dut.u_stage3.avg0_s2[1]),
                $signed(dut.u_stage3.avg0_s2[2]), $signed(dut.u_stage3.avg0_s2[3]),
                $signed(dut.u_stage3.avg0_s2[4]),
                $signed(dut.u_stage3.avg0_sum_s2), $signed(dut.u_stage3.avg0_avg_s2));
        end
    end

    // Track window capture edge - limit debug output
    integer cap_cnt;
    initial cap_cnt = 0;

    // Debug: Show first few captures to verify timing
    always @(posedge clk) begin
        if (dut.u_line_buffer.window_capture && cap_cnt < 5) begin
            cap_cnt = cap_cnt + 1;
            $display("[CAP %0d] wr_col_ptr=%0d capture_addr=%0d window_cap_2_2=%0d",
                cap_cnt, dut.u_line_buffer.wr_col_ptr,
                dut.u_line_buffer.capture_addr,
                dut.u_line_buffer.window_cap_2_2);
        end
    end

    // Track window_valid edge
    integer lb_out_cnt;
    initial lb_out_cnt = 0;
    always @(posedge clk) begin
        if (dut.u_line_buffer.window_valid && lb_out_cnt < 10) begin
            lb_out_cnt = lb_out_cnt + 1;
            $display("[LB OUT %0d] center_x=%0d center_y=%0d window_2_2=%0d wr_col_ptr=%0d rd_col_ptr=%0d",
                lb_out_cnt, dut.u_line_buffer.center_x, dut.u_line_buffer.center_y,
                dut.u_line_buffer.window_2_2, dut.u_line_buffer.wr_col_ptr, dut.u_line_buffer.rd_col_ptr);
        end
    end

    // Track memory writes (first few only)
    integer mem_wr_cnt;
    initial mem_wr_cnt = 0;
    always @(posedge clk) begin
        if (dut.u_line_buffer.din_valid && dut.u_line_buffer.din_ready && mem_wr_cnt < 10) begin
            mem_wr_cnt = mem_wr_cnt + 1;
            $display("[MEM WR %0d] wr_col_ptr=%0d din=%0d wr_row_ptr=%0d",
                mem_wr_cnt, dut.u_line_buffer.wr_col_ptr, dut.u_line_buffer.din, dut.u_line_buffer.wr_row_ptr);
        end
    end

    // Track window_valid_next edge (when window is captured)
    integer wvn_cnt;
    initial wvn_cnt = 0;
    always @(posedge clk) begin
        if (dut.u_line_buffer.window_valid_next && wvn_cnt < 10) begin
            wvn_cnt = wvn_cnt + 1;
            $display("[WVN %0d] wr_col_ptr=%0d output_center=%0d col_0=%0d window_comb_2_2=%0d mem0_0=%0d",
                wvn_cnt, dut.u_line_buffer.wr_col_ptr, dut.u_line_buffer.output_center,
                dut.u_line_buffer.col_0, dut.u_line_buffer.window_comb_2_2,
                dut.u_line_buffer.line_mem_0[0]);
        end
    end

    // Check buffer contents during Stage 3 read
    integer s3_read_cnt;
    initial s3_read_cnt = 0;
    always @(posedge clk) begin
        if (dut.u_stage3.valid_s0_comb && s3_read_cnt < 10) begin
            s3_read_cnt = s3_read_cnt + 1;
            $display("[S3 READ %0d] rd_addr=%0d avg_buf_sel=%0d center_buf_0[0]=%0d center_buf_1[0]=%0d center_rd=%0d",
                s3_read_cnt, dut.u_stage3.rd_addr, dut.u_stage3.avg_buf_sel,
                dut.u_stage3.center_buf_0[0], dut.u_stage3.center_buf_1[0], dut.u_stage3.center_rd);
        end
    end

    // Check pipe_s0 output
    integer s3_pipe_cnt;
    initial s3_pipe_cnt = 0;
    always @(posedge clk) begin
        if (dut.u_stage3.valid_s0 && s3_pipe_cnt < 10) begin
            s3_pipe_cnt = s3_pipe_cnt + 1;
            $display("[S3 PIPE %0d] center_s0=%0d win_size_s0=%0d pixel_x_s0=%0d pixel_y_s0=%0d",
                s3_pipe_cnt, dut.u_stage3.center_s0, dut.u_stage3.win_size_s0,
                dut.u_stage3.pixel_x_s0, dut.u_stage3.pixel_y_s0);
        end
    end

    // Track Stage 4 inputs
    integer s4_in_cnt;
    initial s4_in_cnt = 0;
    always @(posedge clk) begin
        if (dut.s3_valid && s4_in_cnt < 10) begin
            s4_in_cnt = s4_in_cnt + 1;
            $display("[S4 IN %0d] blend0=%0d avg0_u=%0d center=%0d win_size=%0d",
                s4_in_cnt, $signed(dut.s3_blend0), $signed(dut.s3_avg0_u),
                dut.s3_center_pixel, dut.s3_win_size_clip);
        end
    end

    // Track Stage 4 outputs
    integer s4_out_cnt;
    initial s4_out_cnt = 0;
    always @(posedge clk) begin
        if (dut.s4_dout_valid && s4_out_cnt < 20) begin
            s4_out_cnt = s4_out_cnt + 1;
            $display("[S4 OUT %0d] dout=%0d blend0_iir=%0d center=%0d ratio=%0d",
                s4_out_cnt, dut.s4_dout,
                $signed(dut.u_stage4.blend0_iir_sat),
                dut.u_stage4.center_s2, dut.u_stage4.ratio_s1);
        end
    end

    // Track Stage 4 window mixing
    integer s4_win_cnt;
    initial s4_win_cnt = 0;
    always @(posedge clk) begin
        if (dut.u_stage4.valid_s3 && s4_win_cnt < 10) begin
            s4_win_cnt = s4_win_cnt + 1;
            $display("[S4 WIN %0d] blend0_iir=%0d center=%0d factor=%0d bucket=%0d",
                s4_win_cnt, $signed(dut.u_stage4.blend0_iir_s2), dut.u_stage4.center_s2,
                dut.u_stage4.factor_s2, dut.u_stage4.patch_bucket_s2);
        end
    end

    // Track Stage 4 IIR calculation internals
    integer s4_iir_cnt;
    initial s4_iir_cnt = 0;
    always @(posedge clk) begin
        if (dut.u_stage4.valid_s1 && s4_iir_cnt < 10) begin
            s4_iir_cnt = s4_iir_cnt + 1;
            $display("[S4 IIR %0d] blend0_s1=%0d avg0_u_s1=%0d ratio_s1=%0d iir_numer=%0d iir_sat=%0d",
                s4_iir_cnt, $signed(dut.u_stage4.blend0_s1), $signed(dut.u_stage4.avg0_u_s1),
                dut.u_stage4.ratio_s1, $signed(dut.u_stage4.blend0_iir_numer),
                $signed(dut.u_stage4.blend0_iir_sat));
        end
    end

    //=========================================================================
    // Flush Debug
    //=========================================================================
    integer flush_dbg_cnt;
    initial flush_dbg_cnt = 0;

    always @(posedge clk) begin
        if (dut.u_stage3.flush_active && flush_dbg_cnt < 20) begin
            flush_dbg_cnt = flush_dbg_cnt + 1;
            $display("[FLUSH %0d] time=%0t flush_counter=%0d avg_buf_sel=%0d flush_buf_sel=%0d",
                flush_dbg_cnt, $time, dut.u_stage3.flush_counter, dut.u_stage3.avg_buf_sel,
                dut.u_stage3.flush_buf_sel);
            $display("  pixel_y_rd=%0d center_rd=%0d valid_rd=%0d",
                dut.u_stage3.pixel_y_rd, dut.u_stage3.center_rd, dut.u_stage3.valid_rd);
        end
    end

    // Track buffer contents at end of each row
    integer row_end_cnt;
    initial row_end_cnt = 0;
    always @(posedge clk) begin
        if (dut.s2_valid && dut.u_stage3.col_counter == 15 && row_end_cnt < 20) begin
            row_end_cnt = row_end_cnt + 1;
            $display("[ROW END %0d] row_counter=%0d avg_buf_sel=%0d pixel_y_buf_0[0]=%0d pixel_y_buf_1[0]=%0d",
                row_end_cnt, dut.u_stage3.row_counter, dut.u_stage3.avg_buf_sel,
                dut.u_stage3.pixel_y_buf_0[0], dut.u_stage3.pixel_y_buf_1[0]);
        end
    end

endmodule
