`timescale 1ns/1ps

module tb_isp_csiir_patch_stream_watch;

    localparam MAX_WIDTH       = 256;
    localparam MAX_HEIGHT      = 256;
    localparam DATA_WIDTH      = 10;
    localparam GRAD_WIDTH      = 14;
    localparam LINE_ADDR_WIDTH = 14;
    localparam ROW_CNT_WIDTH   = 13;
    localparam CLK_PERIOD      = 1.67;

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

    integer                     cfg_width, cfg_height;
    integer                     cfg_thresh0, cfg_thresh1, cfg_thresh2, cfg_thresh3;
    integer                     cfg_ratio0, cfg_ratio1, cfg_ratio2, cfg_ratio3;
    integer                     cfg_clip0, cfg_clip1, cfg_clip2, cfg_clip3;
    integer                     cfg_clip_sft0, cfg_clip_sft1, cfg_clip_sft2, cfg_clip_sft3;
    integer                     cfg_mot_protect;
    reg [DATA_WIDTH-1:0]        stimulus_mem [0:MAX_WIDTH*MAX_HEIGHT-1];
    integer                     stimulus_count;
    integer                     pixel_in_count;
    integer                     window_fire_count;
    integer                     patch_fire_count;

    isp_csiir_top #(
        .IMG_WIDTH       (MAX_WIDTH),
        .IMG_HEIGHT      (MAX_HEIGHT),
        .DATA_WIDTH      (DATA_WIDTH),
        .GRAD_WIDTH      (GRAD_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH),
        .ROW_CNT_WIDTH   (ROW_CNT_WIDTH)
    ) dut (.*);

    assign dout_ready = 1'b1;

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    task automatic reset;
        begin
            rst_n <= 0;
            psel <= 0;
            penable <= 0;
            pwrite <= 0;
            paddr <= 0;
            pwdata <= 0;
            vsync <= 0;
            hsync <= 0;
            din <= 0;
            din_valid <= 0;
            repeat (10) @(posedge clk);
            rst_n <= 1;
            repeat (5) @(posedge clk);
        end
    endtask

    task automatic apb_write;
        input [7:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            psel <= 1;
            pwrite <= 1;
            paddr <= addr;
            pwdata <= data;
            @(posedge clk);
            penable <= 1;
            @(posedge clk);
            penable <= 0;
            psel <= 0;
        end
    endtask

    task automatic send_pixel;
        input [DATA_WIDTH-1:0] value;
        begin
            din <= value;
            din_valid <= 1;
            pixel_in_count = pixel_in_count + 1;
            @(posedge clk);
            while (!din_ready) @(posedge clk);
            din_valid <= 0;
        end
    endtask

    task automatic send_frame;
        integer x;
        integer y;
        integer idx;
        begin
            pixel_in_count = 0;
            idx = 0;

            #2;
            vsync = 1;
            @(posedge clk);
            #2;
            vsync = 0;
            @(posedge clk);

            for (y = 0; y < cfg_height; y = y + 1) begin
                for (x = 0; x < cfg_width; x = x + 1) begin
                    if (idx < stimulus_count) begin
                        send_pixel(stimulus_mem[idx]);
                        idx = idx + 1;
                    end else begin
                        send_pixel(0);
                    end
                end

                @(negedge clk);
                hsync <= 1;
                @(posedge clk);
                hsync <= 0;
                repeat (3) @(posedge clk);
            end
        end
    endtask

    task automatic read_config;
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
        end
    endtask

    task automatic read_stimulus;
        integer fd;
        integer w;
        integer h;
        integer i;
        reg [31:0] pixel;
        begin
            fd = $fopen("stimulus.hex", "r");
            if (fd == 0) begin
                $display("ERROR: Cannot open stimulus.hex");
                $finish;
            end

            $fscanf(fd, "# Image size: %d x %d\n", w, h);
            $fscanf(fd, "%x\n", w);
            $fscanf(fd, "%x\n", h);

            stimulus_count = 0;
            for (i = 0; i < w * h; i = i + 1) begin
                $fscanf(fd, "%x\n", pixel);
                stimulus_mem[i] = pixel[DATA_WIDTH-1:0];
                stimulus_count = stimulus_count + 1;
            end
            $fclose(fd);
        end
    endtask

    always @(posedge clk) begin
        if (dut.window_valid && dut.window_ready)
            window_fire_count <= window_fire_count + 1;
        if (dut.s4_patch_valid && dut.s4_patch_ready)
            patch_fire_count <= patch_fire_count + 1;
    end

    initial begin
        window_fire_count = 0;
        patch_fire_count = 0;

        read_config();
        read_stimulus();
        reset();

        apb_write(8'h00, 32'b1);
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

        fork
            begin
                send_frame();
                repeat (200) @(posedge clk);
                $display("FRAME_DONE window_fire=%0d patch_fire=%0d", window_fire_count, patch_fire_count);
                $finish;
            end
            begin
                repeat (5000) @(posedge clk);
                $display("WATCHDOG");
                $display("pixel_in=%0d din_valid=%0b din_ready=%0b", pixel_in_count, din_valid, din_ready);
                $display("window_valid=%0b window_ready=%0b fire=%0d", dut.window_valid, dut.window_ready, window_fire_count);
                $display("patch_valid=%0b patch_ready=%0b fire=%0d", dut.s4_patch_valid, dut.s4_patch_ready, patch_fire_count);
                $display("feedback_pending=%0b row_cnt=%0d wr_col=%0d center=(%0d,%0d)",
                         dut.u_line_buffer.feedback_pending,
                         dut.u_line_buffer.row_cnt,
                         dut.u_line_buffer.wr_col_ptr,
                         dut.center_x,
                         dut.center_y);
                $finish;
            end
        join
    end

endmodule
