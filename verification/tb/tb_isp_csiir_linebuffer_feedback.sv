`timescale 1ns/1ps

module tb_isp_csiir_linebuffer_feedback;

    /*
    TB_CONTRACT
    - module_name: isp_csiir_linebuffer_core
    - boundary_id: fixed_patch_feedback_to_linebuffer_state
    - compare_object: initial raster preload + fixed-model patch feedback stream -> linebuffer row snapshots after each processed row
    - expected_source: fixed-model export_linebuffer_row_snapshots() and export_patch_stream()
    - observed_source: line_mem_0..4 sampled by logical src_y after each accepted feedback row
    - sample_edge: posedge
    - input_valid_ready_contract: patch accepted on patch_valid && patch_ready
    - output_valid_ready_contract: none; column stream drained but not compared in this TB
    - feedback_contract: patch_valid path must implement safe-column commit semantics, including right-edge flush without padding overwrite
    - metadata_scope: patch_center_x / patch_center_y / logical row snapshot after row completion
    - pass_fail_predicate: dumped snapshots exactly match fixed-model row snapshots
    */

    localparam MAX_WIDTH       = 256;
    localparam MAX_HEIGHT      = 256;
    localparam DATA_WIDTH      = 10;
    localparam LINE_ADDR_WIDTH = 14;
    localparam CLK_PERIOD      = 1.67;

    reg                         clk;
    reg                         rst_n;
    reg                         enable;
    reg  [LINE_ADDR_WIDTH-1:0]  img_width;
    reg  [12:0]                 img_height;
    reg  [12:0]                 max_center_y_allow;
    reg  [DATA_WIDTH-1:0]       din;
    reg                         din_valid;
    wire                        din_ready;
    reg                         sof;
    reg                         eol;
    reg                         lb_wb_en;
    reg  [DATA_WIDTH-1:0]       lb_wb_data;
    reg  [LINE_ADDR_WIDTH-1:0]  lb_wb_addr;
    reg  [2:0]                  lb_wb_row_offset;
    reg                         patch_valid;
    wire                        patch_ready;
    reg  [LINE_ADDR_WIDTH-1:0]  patch_center_x;
    reg  [12:0]                 patch_center_y;
    reg  [DATA_WIDTH*25-1:0]    patch_5x5;
    wire [DATA_WIDTH-1:0]       col_0;
    wire [DATA_WIDTH-1:0]       col_1;
    wire [DATA_WIDTH-1:0]       col_2;
    wire [DATA_WIDTH-1:0]       col_3;
    wire [DATA_WIDTH-1:0]       col_4;
    wire                        column_valid;
    reg                         column_ready;
    wire [LINE_ADDR_WIDTH-1:0]  center_x;
    wire [12:0]                 center_y;

    integer                     cfg_width;
    integer                     cfg_height;
    reg [DATA_WIDTH-1:0]        stimulus_mem [0:MAX_WIDTH*MAX_HEIGHT-1];
    integer                     stimulus_count;
    integer                     pixel_in_count;
    integer                     snapshot_file;
    reg                         row_filter_enable;
    reg                         row_filter [0:MAX_HEIGHT-1];

    reg  [LINE_ADDR_WIDTH-1:0]  patch_center_x_mem [0:MAX_WIDTH*MAX_HEIGHT-1];
    reg  [12:0]                 patch_center_y_mem [0:MAX_WIDTH*MAX_HEIGHT-1];
    reg  [DATA_WIDTH-1:0]       patch_mem [0:MAX_WIDTH*MAX_HEIGHT-1][0:24];
    integer                     patch_count;

    isp_csiir_linebuffer_core #(
        .IMG_WIDTH       (MAX_WIDTH),
        .DATA_WIDTH      (DATA_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .enable          (enable),
        .img_width       (img_width),
        .img_height      (img_height),
        .max_center_y_allow(max_center_y_allow),
        .din             (din),
        .din_valid       (din_valid),
        .din_ready       (din_ready),
        .sof             (sof),
        .eol             (eol),
        .lb_wb_en        (lb_wb_en),
        .lb_wb_data      (lb_wb_data),
        .lb_wb_addr      (lb_wb_addr),
        .lb_wb_row_offset(lb_wb_row_offset),
        .patch_valid     (patch_valid),
        .patch_ready     (patch_ready),
        .patch_center_x  (patch_center_x),
        .patch_center_y  (patch_center_y),
        .patch_5x5       (patch_5x5),
        .col_0           (col_0),
        .col_1           (col_1),
        .col_2           (col_2),
        .col_3           (col_3),
        .col_4           (col_4),
        .column_valid    (column_valid),
        .column_ready    (column_ready),
        .center_x        (center_x),
        .center_y        (center_y)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    function automatic [DATA_WIDTH-1:0] read_linebuffer_value;
        input integer src_y;
        input integer col_idx;
        integer phys_row;
        begin
            phys_row = src_y % 5;
            case (phys_row)
                0: read_linebuffer_value = dut.line_mem_0[col_idx];
                1: read_linebuffer_value = dut.line_mem_1[col_idx];
                2: read_linebuffer_value = dut.line_mem_2[col_idx];
                3: read_linebuffer_value = dut.line_mem_3[col_idx];
                default: read_linebuffer_value = dut.line_mem_4[col_idx];
            endcase
        end
    endfunction

    task automatic dump_snapshot_after_row;
        input integer after_row;
        integer slot_idx;
        integer src_y;
        integer col_idx;
        begin
            if (!row_filter_enable || row_filter[after_row]) begin
                $fdisplay(snapshot_file, "# after_row=%0d", after_row);
                $fwrite(snapshot_file, "# slot_to_src_y=");
                for (slot_idx = 0; slot_idx < 5; slot_idx = slot_idx + 1) begin
                    src_y = after_row + slot_idx - 2;
                    if (src_y < 0)
                        src_y = 0;
                    else if (src_y >= cfg_height)
                        src_y = cfg_height - 1;
                    $fwrite(snapshot_file, "%0d", src_y);
                    if (slot_idx != 4)
                        $fwrite(snapshot_file, " ");
                end
                $fwrite(snapshot_file, "\n");

                for (slot_idx = 0; slot_idx < 5; slot_idx = slot_idx + 1) begin
                    src_y = after_row + slot_idx - 2;
                    if (src_y < 0)
                        src_y = 0;
                    else if (src_y >= cfg_height)
                        src_y = cfg_height - 1;
                    $fwrite(snapshot_file, "slot%0d_srcy%0d:", slot_idx, src_y);
                    for (col_idx = 0; col_idx < cfg_width; col_idx = col_idx + 1)
                        $fwrite(snapshot_file, " %03x", read_linebuffer_value(src_y, col_idx));
                    $fwrite(snapshot_file, "\n");
                end
            end
        end
    endtask

    task automatic reset_dut;
        begin
            rst_n <= 1'b0;
            enable <= 1'b0;
            img_width <= 0;
            img_height <= 0;
            max_center_y_allow <= 13'h1fff;
            din <= 0;
            din_valid <= 1'b0;
            sof <= 1'b0;
            eol <= 1'b0;
            lb_wb_en <= 1'b0;
            lb_wb_data <= 0;
            lb_wb_addr <= 0;
            lb_wb_row_offset <= 3'd0;
            patch_valid <= 1'b0;
            patch_center_x <= 0;
            patch_center_y <= 0;
            patch_5x5 <= 0;
            column_ready <= 1'b1;
            repeat (5) @(posedge clk);
            rst_n <= 1'b1;
            enable <= 1'b1;
            img_width <= cfg_width[LINE_ADDR_WIDTH-1:0];
            img_height <= cfg_height[12:0];
            max_center_y_allow <= 13'h1fff;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic read_config;
        integer fd;
        integer junk;
        begin
            fd = $fopen("config.txt", "r");
            if (fd == 0) begin
                $display("ERROR: Cannot open config.txt");
                $finish;
            end
            $fscanf(fd, "%d", cfg_width);
            $fscanf(fd, "%d", cfg_height);
            repeat (17) $fscanf(fd, "%d", junk);
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

    task automatic read_patch_stream;
        integer fd;
        integer scan_status;
        integer idx_value;
        integer x_value;
        integer y_value;
        integer row_idx;
        integer parsed_row_idx;
        reg [31:0] c0;
        reg [31:0] c1;
        reg [31:0] c2;
        reg [31:0] c3;
        reg [31:0] c4;
        begin
            fd = $fopen("input_patch_stream.txt", "r");
            if (fd == 0) begin
                $display("ERROR: Cannot open input_patch_stream.txt");
                $finish;
            end

            patch_count = 0;
            while (!$feof(fd)) begin
                scan_status = $fscanf(fd, "# idx=%d center_x=%d center_y=%d\n", idx_value, x_value, y_value);
                if (scan_status == 3) begin
                    patch_center_x_mem[patch_count] = x_value[LINE_ADDR_WIDTH-1:0];
                    patch_center_y_mem[patch_count] = y_value[12:0];
                    for (row_idx = 0; row_idx < 5; row_idx = row_idx + 1) begin
                        scan_status = $fscanf(fd, "row%d: %x %x %x %x %x\n", parsed_row_idx, c0, c1, c2, c3, c4);
                        if ((scan_status != 6) || (parsed_row_idx != row_idx)) begin
                            $display("ERROR: malformed patch payload row");
                            $finish;
                        end
                        patch_mem[patch_count][row_idx * 5 + 0] = c0[DATA_WIDTH-1:0];
                        patch_mem[patch_count][row_idx * 5 + 1] = c1[DATA_WIDTH-1:0];
                        patch_mem[patch_count][row_idx * 5 + 2] = c2[DATA_WIDTH-1:0];
                        patch_mem[patch_count][row_idx * 5 + 3] = c3[DATA_WIDTH-1:0];
                        patch_mem[patch_count][row_idx * 5 + 4] = c4[DATA_WIDTH-1:0];
                    end
                    patch_count = patch_count + 1;
                end
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

            fd = $fopen("linebuffer_after_rows.txt", "r");
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

    task automatic pulse_sof;
        begin
            sof <= 1'b1;
            @(posedge clk);
            sof <= 1'b0;
        end
    endtask

    task automatic drive_one_pixel;
        input [DATA_WIDTH-1:0] value;
        begin
            din <= value;
            din_valid <= 1'b1;
            @(posedge clk);
            while (!din_ready) @(posedge clk);
            din_valid <= 1'b0;
            pixel_in_count = pixel_in_count + 1;
        end
    endtask

    task automatic pulse_eol;
        begin
            eol <= 1'b1;
            @(posedge clk);
            eol <= 1'b0;
        end
    endtask

    task automatic send_frame;
        integer x;
        integer y;
        integer idx;
        begin
            idx = 0;
            pixel_in_count = 0;
            pulse_sof();
            for (y = 0; y < cfg_height; y = y + 1) begin
                for (x = 0; x < cfg_width; x = x + 1) begin
                    drive_one_pixel(stimulus_mem[idx]);
                    idx = idx + 1;
                end
                pulse_eol();
                repeat (3) @(posedge clk);
            end
        end
    endtask

    task automatic wait_for_forward_drain;
        integer guard;
        begin
            guard = 0;
            while ((dut.tail_pending || dut.tail_active || dut.capture_pending || dut.column_valid) && (guard < (MAX_WIDTH * 8))) begin
                @(posedge clk);
                guard = guard + 1;
            end
        end
    endtask

    task automatic drive_one_patch;
        input integer idx;
        integer patch_idx;
        begin
            patch_center_x <= patch_center_x_mem[idx];
            patch_center_y <= patch_center_y_mem[idx];
            for (patch_idx = 0; patch_idx < 25; patch_idx = patch_idx + 1)
                patch_5x5[patch_idx * DATA_WIDTH +: DATA_WIDTH] <= patch_mem[idx][patch_idx];
            patch_valid <= 1'b1;
            @(posedge clk);
            while (!patch_ready) @(posedge clk);
            patch_valid <= 1'b0;
        end
    endtask

    integer patch_idx;
    integer current_row;
    initial begin
        snapshot_file = 0;

        read_config();
        read_stimulus();
        read_patch_stream();
        read_row_filter();
        reset_dut();

        snapshot_file = $fopen("actual_linebuffer_feedback_rows.txt", "w");
        if (snapshot_file == 0) begin
            $display("ERROR: Cannot open actual_linebuffer_feedback_rows.txt");
            $finish;
        end

        send_frame();
        wait_for_forward_drain();

        current_row = -1;
        for (patch_idx = 0; patch_idx < patch_count; patch_idx = patch_idx + 1) begin
            drive_one_patch(patch_idx);
            if ((patch_idx == patch_count - 1) ||
                (patch_center_y_mem[patch_idx + 1] != patch_center_y_mem[patch_idx])) begin
                current_row = patch_center_y_mem[patch_idx];
                @(posedge clk);
                dump_snapshot_after_row(current_row);
            end
        end

        if (snapshot_file != 0) begin
            $fclose(snapshot_file);
            snapshot_file = 0;
        end

        $display("PASS: linebuffer feedback TB applied %0d patches", patch_count);
        $finish;
    end

endmodule
