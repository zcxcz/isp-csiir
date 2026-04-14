`timescale 1ns/1ps

module tb_isp_csiir_linebuffer_core;

    /*
    TB_CONTRACT
    - module_name: isp_csiir_linebuffer_core
    - boundary_id: forward_input_to_column_stream
    - compare_object: accepted input raster -> accepted 5x1 column stream
    - expected_source: fixed-model export_forward_column_stream()
    - observed_source: col_0..col_4 / center_x / center_y on column_valid && column_ready
    - sample_edge: posedge
    - input_valid_ready_contract: input pixel accepted on din_valid && din_ready
    - output_valid_ready_contract: column accepted on column_valid && column_ready
    - feedback_contract: disabled in this TB, pure forward semantics only
    - padding_contract: top/bottom duplicate padding from linebuffer_core runtime behavior
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
    integer                     output_file;
    integer                     output_idx;
    reg                         row_filter_enable;
    reg                         row_filter [0:MAX_HEIGHT-1];

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

    task automatic reset_dut;
        begin
            rst_n <= 1'b0;
            enable <= 1'b0;
            img_width <= 0;
            img_height <= 0;
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

    task automatic read_row_filter;
        integer fd;
        integer row_value;
        integer idx;
        integer scan_status;
        begin
            row_filter_enable = 1'b0;
            for (idx = 0; idx < MAX_HEIGHT; idx = idx + 1)
                row_filter[idx] = 1'b0;

            fd = $fopen("column_center_rows.txt", "r");
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

    always @(posedge clk) begin
        if ((output_file != 0) && column_valid && column_ready &&
            (!row_filter_enable || row_filter[center_y])) begin
            $fdisplay(output_file, "# idx=%0d center_x=%0d center_y=%0d", output_idx, center_x, center_y);
            $fdisplay(output_file, "col: %03x %03x %03x %03x %03x", col_0, col_1, col_2, col_3, col_4);
            output_idx = output_idx + 1;
        end
    end

    initial begin
        output_file = 0;
        output_idx = 0;

        read_config();
        read_stimulus();
        read_row_filter();
        reset_dut();

        output_file = $fopen("actual_column_stream.txt", "w");
        if (output_file == 0) begin
            $display("ERROR: Cannot open actual_column_stream.txt");
            $finish;
        end

        send_frame();
        repeat (cfg_width * 4 + 50) @(posedge clk);

        if (output_file != 0) begin
            $fclose(output_file);
            output_file = 0;
        end

        $display("PASS: linebuffer_core drove %0d pixels and observed %0d columns", pixel_in_count, output_idx);
        $finish;
    end

endmodule
