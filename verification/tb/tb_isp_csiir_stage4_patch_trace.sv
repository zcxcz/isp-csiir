`timescale 1ns/1ps

module tb_isp_csiir_stage4_patch_trace;

    localparam MAX_WIDTH       = 256;
    localparam MAX_HEIGHT      = 256;
    localparam DATA_WIDTH      = 10;
    localparam SIGNED_WIDTH    = 11;
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
    integer                     in_file;
    integer                     out_file;
    integer                     input_idx;
    integer                     output_idx;
    reg                         row_filter_enable;
    reg                         row_filter [0:MAX_HEIGHT-1];

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

    task automatic read_row_filter;
        integer fd;
        integer row_value;
        integer idx;
        integer scan_status;
        begin
            row_filter_enable = 1'b0;
            for (idx = 0; idx < MAX_HEIGHT; idx = idx + 1)
                row_filter[idx] = 1'b0;

            fd = $fopen("patch_center_rows.txt", "r");
            if (fd != 0) begin
                row_filter_enable = 1'b1;
                while (!$feof(fd)) begin
                    scan_status = $fscanf(fd, "%d\n", row_value);
                    if ((scan_status == 1) && (row_value >= 0) && (row_value < MAX_HEIGHT))
                        row_filter[row_value] = 1'b1;
                end
                $fclose(fd);
            end
        end
    endtask

    always @(posedge clk) begin
        integer py;
        integer px;
        if ((in_file != 0) && dut.s3_valid && dut.s3_ready &&
            (!row_filter_enable || row_filter[dut.s3_pixel_y])) begin
            $fdisplay(
                in_file,
                "# idx=%0d center_x=%0d center_y=%0d win_size=%0d grad_h=%0d grad_v=%0d blend0=%0d blend1=%0d avg0_u=%0d avg1_u=%0d",
                input_idx,
                dut.s3_pixel_x,
                dut.s3_pixel_y,
                dut.s3_win_size_clip,
                dut.s4_grad_h_aligned,
                dut.s4_grad_v_aligned,
                $signed(dut.s3_blend0),
                $signed(dut.s3_blend1),
                $signed(dut.s3_avg0_u),
                $signed(dut.s3_avg1_u)
            );
            for (py = 0; py < 5; py = py + 1) begin
                $fwrite(in_file, "src_row%0d:", py);
                for (px = 0; px < 5; px = px + 1)
                    $fwrite(in_file, " %03x", dut.s4_src_patch_aligned[((py * 5) + px) * DATA_WIDTH +: DATA_WIDTH]);
                $fwrite(in_file, "\n");
            end
            input_idx = input_idx + 1;
        end

        if ((out_file != 0) && dut.s4_patch_valid && dut.s4_patch_ready &&
            (!row_filter_enable || row_filter[dut.s4_patch_center_y])) begin
            $fdisplay(
                out_file,
                "# idx=%0d center_x=%0d center_y=%0d",
                output_idx,
                dut.s4_patch_center_x,
                dut.s4_patch_center_y
            );
            for (py = 0; py < 5; py = py + 1) begin
                $fwrite(out_file, "row%0d:", py);
                for (px = 0; px < 5; px = px + 1)
                    $fwrite(out_file, " %03x", dut.s4_patch_5x5[((py * 5) + px) * DATA_WIDTH +: DATA_WIDTH]);
                $fwrite(out_file, "\n");
            end
            output_idx = output_idx + 1;
        end
    end

    initial begin
        in_file = 0;
        out_file = 0;
        input_idx = 0;
        output_idx = 0;

        read_config();
        read_stimulus();
        read_row_filter();
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

        in_file = $fopen("stage4_input_trace.txt", "w");
        if (in_file == 0) begin
            $display("ERROR: Cannot open stage4_input_trace.txt");
            $finish;
        end
        out_file = $fopen("stage4_output_patch.txt", "w");
        if (out_file == 0) begin
            $display("ERROR: Cannot open stage4_output_patch.txt");
            $finish;
        end

        send_frame();
        repeat (cfg_width * cfg_height + 200) @(posedge clk);

        if (in_file != 0) begin
            $fclose(in_file);
            in_file = 0;
        end
        if (out_file != 0) begin
            $fclose(out_file);
            out_file = 0;
        end

        $display("PASS: dumped stage4 input/output traces");
        $finish;
    end

endmodule
