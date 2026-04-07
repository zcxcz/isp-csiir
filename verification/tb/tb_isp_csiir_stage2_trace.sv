//-----------------------------------------------------------------------------

// Module: tb_isp_csiir_stage2_trace
// Purpose: Trace Stage 2 intermediate values for comparison with Python model
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module tb_isp_csiir_stage2_trace;

    //=========================================================================
    // Parameters
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
    integer                     s2_trace_file;
    integer                     s4_in_cnt;
    integer                     s4_out_cnt;

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
    assign dout_ready = 1'b1;

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
            while (!din_ready) @(posedge clk);
            din_valid <= 0;
        end
    endtask

    task send_frame;
        integer x, y, idx;
        begin
            pixel_in_count = 0;
            idx = 0;

            #2;
            vsync = 1;
            @(posedge clk);
            #2;
            vsync = 0;
            @(posedge clk);

            for (y = 0; y < cfg_height; y++) begin
                for (x = 0; x < cfg_width; x++) begin
                    if (idx < stimulus_count) begin
                        send_pixel(stimulus_mem[idx]);
                        idx++;
                    end else begin
                        send_pixel(0);
                    end
                end

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

            $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d",
                    cfg_width, cfg_height,
                    cfg_thresh0, cfg_thresh1, cfg_thresh2, cfg_thresh3,
                    cfg_ratio0, cfg_ratio1, cfg_ratio2, cfg_ratio3,
                    cfg_clip0, cfg_clip1, cfg_clip2, cfg_clip3);
            $fclose(fd);

            $display("Config: %0dx%0d", cfg_width, cfg_height);
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

            stimulus_count = 0;
            for (i = 0; i < w * h; i++) begin
                $fscanf(fd, "%x\n", pixel);
                stimulus_mem[i] = pixel[DATA_WIDTH-1:0];
                stimulus_count++;
            end
            $fclose(fd);

            $display("Loaded %0d stimulus pixels", stimulus_count);
        end
    endtask

    //=========================================================================
    // Line Buffer Write Trace
    //=========================================================================
    integer lb_wr_cnt;
    initial lb_wr_cnt = 0;

    always @(posedge clk) begin
        if (dut.u_line_buffer.din_valid && dut.u_line_buffer.din_ready && lb_wr_cnt < 10) begin
            lb_wr_cnt = lb_wr_cnt + 1;
            $display("LB_WR[%0d] wr_col=%0d din=%0d wr_row=%0d line_mem_0[2]=%0d",
                lb_wr_cnt, dut.u_line_buffer.wr_col_ptr, dut.u_line_buffer.din, dut.u_line_buffer.wr_row_ptr,
                dut.u_line_buffer.line_mem_0[2]);
        end
    end

    //=========================================================================
    // Line Buffer Read/Output Trace
    //=========================================================================
    integer lb_rd_cnt;
    initial lb_rd_cnt = 0;

    always @(posedge clk) begin
        if (dut.u_line_buffer.window_valid && lb_rd_cnt < 5) begin
            lb_rd_cnt = lb_rd_cnt + 1;
            $display("LB_RD[%0d] wr_col=%0d line_mem_0[0]=%0d line_mem_0[1]=%0d line_mem_0[2]=%0d",
                lb_rd_cnt, dut.u_line_buffer.wr_col_ptr,
                dut.u_line_buffer.line_mem_0[0], dut.u_line_buffer.line_mem_0[1], dut.u_line_buffer.line_mem_0[2]);
            $display("  win_row_2_phys=%0d center_col=%0d col_p2=%0d win_2_4=%0d",
                dut.u_line_buffer.win_row_2_phys, dut.u_line_buffer.center_col,
                dut.u_line_buffer.col_p2, dut.u_line_buffer.window_2_4);
        end
    end

    //=========================================================================
    // Window Input Trace (before Stage 2 pipeline)
    //=========================================================================
    integer win_cnt;
    initial win_cnt = 0;

    always @(posedge clk) begin
        if (dut.s1_valid && win_cnt < 10) begin
            win_cnt = win_cnt + 1;
            $display("WIN[%0d] px=%0d py=%0d center=%0d",
                win_cnt, dut.s1_pixel_x, dut.s1_pixel_y, dut.s1_win_2_2);
            $display("  row0: %0d %0d %0d %0d %0d",
                dut.s1_win_0_0, dut.s1_win_0_1, dut.s1_win_0_2, dut.s1_win_0_3, dut.s1_win_0_4);
            $display("  row2: %0d %0d %0d %0d %0d",
                dut.s1_win_2_0, dut.s1_win_2_1, dut.s1_win_2_2, dut.s1_win_2_3, dut.s1_win_2_4);
        end
    end

    //=========================================================================
    // Stage 2 Trace - Aligned Pipeline
    //=========================================================================
    integer s2_cnt;
    initial s2_cnt = 0;

    always @(posedge clk) begin
        if (dut.s2_valid && s2_cnt < 260) begin
            s2_cnt = s2_cnt + 1;

            // Write to file - use only final outputs
            if (s2_trace_file != 0) begin
                $fdisplay(s2_trace_file, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                    dut.s2_pixel_x, dut.s2_pixel_y, dut.s2_center_pixel,
                    dut.u_stage2.avg0_sum_c_s6, dut.u_stage2.avg0_sum_u_s6,
                    dut.u_stage2.avg0_sum_d_s6, dut.u_stage2.avg0_sum_l_s6,
                    dut.u_stage2.avg0_sum_r_s6,
                    $signed(dut.s2_avg0_c), $signed(dut.s2_avg0_u),
                    $signed(dut.s2_avg0_d), $signed(dut.s2_avg0_l), $signed(dut.s2_avg0_r));
            end

            // Print first 10 with window details
            if (s2_cnt <= 10) begin
                $display("S2[%0d] px=%0d py=%0d ctr=%0d sum_c=%0d avg0_c=%0d",
                    s2_cnt, dut.s2_pixel_x, dut.s2_pixel_y, dut.s2_center_pixel,
                    dut.u_stage2.avg0_sum_c_s6, $signed(dut.s2_avg0_c));
            end
        end
    end

    //=========================================================================
    // Stage 4 Boundary Trace
    //=========================================================================
    always @(posedge clk) begin
        if (dut.s3_valid && s4_in_cnt < 5) begin
            s4_in_cnt = s4_in_cnt + 1;
            $display("S4_IN[%0d] px=%0d py=%0d blend0=%0d blend1=%0d avg0_u=%0d avg1_u=%0d gh=%0d gv=%0d center=%0d win=%0d",
                s4_in_cnt, dut.s3_pixel_x, dut.s3_pixel_y,
                $signed(dut.s3_blend0), $signed(dut.s3_blend1),
                $signed(dut.s3_avg0_u), $signed(dut.s3_avg1_u),
                $signed(dut.s4_grad_h_aligned), $signed(dut.s4_grad_v_aligned),
                dut.s3_center_pixel, dut.s3_win_size_clip);
            $display("  s4_row0: %0d %0d %0d %0d %0d",
                dut.s4_src_patch_aligned[0*DATA_WIDTH +: DATA_WIDTH],
                dut.s4_src_patch_aligned[1*DATA_WIDTH +: DATA_WIDTH],
                dut.s4_src_patch_aligned[2*DATA_WIDTH +: DATA_WIDTH],
                dut.s4_src_patch_aligned[3*DATA_WIDTH +: DATA_WIDTH],
                dut.s4_src_patch_aligned[4*DATA_WIDTH +: DATA_WIDTH]);
            $display("  s4_row2: %0d %0d %0d %0d %0d",
                dut.s4_src_patch_aligned[10*DATA_WIDTH +: DATA_WIDTH],
                dut.s4_src_patch_aligned[11*DATA_WIDTH +: DATA_WIDTH],
                dut.s4_src_patch_aligned[12*DATA_WIDTH +: DATA_WIDTH],
                dut.s4_src_patch_aligned[13*DATA_WIDTH +: DATA_WIDTH],
                dut.s4_src_patch_aligned[14*DATA_WIDTH +: DATA_WIDTH]);
        end
    end

    always @(posedge clk) begin
        if (dut.s4_dout_valid && s4_out_cnt < 10) begin
            s4_out_cnt = s4_out_cnt + 1;
            $display("S4_OUT[%0d] px=%0d py=%0d dout=%0d patch_center=%0d",
                s4_out_cnt, dut.s4_pixel_x, dut.s4_pixel_y,
                dut.s4_dout, dut.u_stage4.patch_5x5[12*DATA_WIDTH +: DATA_WIDTH]);
        end
    end

    //=========================================================================
    // Main Test
    //=========================================================================
    initial begin
        pixel_in_count = 0;
        pixel_out_count = 0;
        s2_cnt = 0;
        s2_trace_file = 0;
        s4_in_cnt = 0;
        s4_out_cnt = 0;

        $display("\n========================================");
        $display("Stage 2 Trace Testbench");
        $display("========================================\n");

        // Read configuration and stimulus
        read_config();
        read_stimulus();

        // Reset
        reset();
        $display("[%0t] Reset complete", $time);

        // Configure
        apb_write(8'h00, 32'b1);    // Enable
        apb_write(8'h04, {cfg_height[15:0], cfg_width[15:0]});
        apb_write(8'h0C, cfg_thresh0);
        apb_write(8'h10, cfg_thresh1);
        apb_write(8'h14, cfg_thresh2);
        apb_write(8'h18, cfg_thresh3);
        apb_write(8'h1C, {cfg_ratio3[7:0], cfg_ratio2[7:0], cfg_ratio1[7:0], cfg_ratio0[7:0]});
        apb_write(8'h20, {6'd0, cfg_clip1[9:0], 6'd0, cfg_clip0[9:0]});
        apb_write(8'h2C, {6'd0, cfg_clip3[9:0], 6'd0, cfg_clip2[9:0]});

        // Open trace file
        s2_trace_file = $fopen("stage2_rtl.txt", "w");
        $fdisplay(s2_trace_file, "# Pixel_X Pixel_Y Center Sum_C Sum_U Sum_D Sum_L Sum_R Avg0_C Avg0_U Avg0_D Avg0_L Avg0_R");

        // Send frame
        send_frame();
        $display("[%0t] Frame sent, pixels in = %0d", $time, pixel_in_count);

        // Wait for outputs
        repeat(cfg_width * cfg_height + 100) @(posedge clk);

        // Close trace file
        if (s2_trace_file != 0) begin
            $fclose(s2_trace_file);
            s2_trace_file = 0;
        end

        $display("\n========================================");
        $display("Stage 2 traces written to stage2_rtl.txt");
        $display("Total S2 outputs: %0d", s2_cnt);
        $display("========================================\n");

        #1000;
        $finish;
    end

    // Timeout
    initial begin
        #10000000;
        $display("[%0t] Timeout!", $time);
        $finish;
    end

endmodule
