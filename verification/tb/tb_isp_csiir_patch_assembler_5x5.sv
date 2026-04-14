`timescale 1ns/1ps

module tb_isp_csiir_patch_assembler_5x5;

    localparam MAX_WIDTH       = 256;
    localparam DATA_WIDTH      = 10;
    localparam LINE_ADDR_WIDTH = 14;
    localparam CLK_PERIOD      = 1.67;

    reg                         clk;
    reg                         rst_n;
    reg                         enable;
    reg  [LINE_ADDR_WIDTH-1:0]  img_width;
    reg  [DATA_WIDTH-1:0]       col_0;
    reg  [DATA_WIDTH-1:0]       col_1;
    reg  [DATA_WIDTH-1:0]       col_2;
    reg  [DATA_WIDTH-1:0]       col_3;
    reg  [DATA_WIDTH-1:0]       col_4;
    reg                         column_valid;
    wire                        column_ready;
    reg  [LINE_ADDR_WIDTH-1:0]  center_x;
    reg  [12:0]                 center_y;
    wire [DATA_WIDTH-1:0]       window_0_0, window_0_1, window_0_2, window_0_3, window_0_4;
    wire [DATA_WIDTH-1:0]       window_1_0, window_1_1, window_1_2, window_1_3, window_1_4;
    wire [DATA_WIDTH-1:0]       window_2_0, window_2_1, window_2_2, window_2_3, window_2_4;
    wire [DATA_WIDTH-1:0]       window_3_0, window_3_1, window_3_2, window_3_3, window_3_4;
    wire [DATA_WIDTH-1:0]       window_4_0, window_4_1, window_4_2, window_4_3, window_4_4;
    wire                        window_valid;
    reg                         window_ready;
    wire [LINE_ADDR_WIDTH-1:0]  patch_center_x;
    wire [12:0]                 patch_center_y;
    wire [DATA_WIDTH*25-1:0]    patch_5x5;

    integer                     cfg_width;
    integer                     input_file;
    integer                     output_file;
    integer                     input_idx;
    integer                     sent_columns;
    integer                     recv_patches;

    reg  [LINE_ADDR_WIDTH-1:0]  input_center_x_mem [0:MAX_WIDTH*MAX_WIDTH-1];
    reg  [12:0]                 input_center_y_mem [0:MAX_WIDTH*MAX_WIDTH-1];
    reg  [DATA_WIDTH-1:0]       input_col_mem [0:MAX_WIDTH*MAX_WIDTH-1][0:4];
    integer                     input_count;

    isp_csiir_patch_assembler_5x5 #(
        .DATA_WIDTH      (DATA_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .enable          (enable),
        .img_width       (img_width),
        .col_0           (col_0),
        .col_1           (col_1),
        .col_2           (col_2),
        .col_3           (col_3),
        .col_4           (col_4),
        .column_valid    (column_valid),
        .column_ready    (column_ready),
        .center_x        (center_x),
        .center_y        (center_y),
        .window_0_0      (window_0_0),
        .window_0_1      (window_0_1),
        .window_0_2      (window_0_2),
        .window_0_3      (window_0_3),
        .window_0_4      (window_0_4),
        .window_1_0      (window_1_0),
        .window_1_1      (window_1_1),
        .window_1_2      (window_1_2),
        .window_1_3      (window_1_3),
        .window_1_4      (window_1_4),
        .window_2_0      (window_2_0),
        .window_2_1      (window_2_1),
        .window_2_2      (window_2_2),
        .window_2_3      (window_2_3),
        .window_2_4      (window_2_4),
        .window_3_0      (window_3_0),
        .window_3_1      (window_3_1),
        .window_3_2      (window_3_2),
        .window_3_3      (window_3_3),
        .window_3_4      (window_3_4),
        .window_4_0      (window_4_0),
        .window_4_1      (window_4_1),
        .window_4_2      (window_4_2),
        .window_4_3      (window_4_3),
        .window_4_4      (window_4_4),
        .window_valid    (window_valid),
        .window_ready    (window_ready),
        .patch_center_x  (patch_center_x),
        .patch_center_y  (patch_center_y),
        .patch_5x5       (patch_5x5)
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
            col_0 <= 0;
            col_1 <= 0;
            col_2 <= 0;
            col_3 <= 0;
            col_4 <= 0;
            column_valid <= 1'b0;
            center_x <= 0;
            center_y <= 0;
            window_ready <= 1'b1;
            repeat (5) @(posedge clk);
            rst_n <= 1'b1;
            enable <= 1'b1;
            img_width <= cfg_width[LINE_ADDR_WIDTH-1:0];
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
            $fscanf(fd, "%d", junk);
            $fclose(fd);
            img_width = cfg_width[LINE_ADDR_WIDTH-1:0];
        end
    endtask

    task automatic read_input_columns;
        integer fd;
        integer scan_status;
        integer idx_value;
        integer x_value;
        integer y_value;
        reg [31:0] c0, c1, c2, c3, c4;
        begin
            fd = $fopen("input_column_stream.txt", "r");
            if (fd == 0) begin
                $display("ERROR: Cannot open input_column_stream.txt");
                $finish;
            end

            input_count = 0;
            while (!$feof(fd)) begin
                scan_status = $fscanf(fd, "# idx=%d center_x=%d center_y=%d\n", idx_value, x_value, y_value);
                if (scan_status == 3) begin
                    scan_status = $fscanf(fd, "col: %x %x %x %x %x\n", c0, c1, c2, c3, c4);
                    if (scan_status != 5) begin
                        $display("ERROR: malformed column payload");
                        $finish;
                    end
                    input_center_x_mem[input_count] = x_value[LINE_ADDR_WIDTH-1:0];
                    input_center_y_mem[input_count] = y_value[12:0];
                    input_col_mem[input_count][0] = c0[DATA_WIDTH-1:0];
                    input_col_mem[input_count][1] = c1[DATA_WIDTH-1:0];
                    input_col_mem[input_count][2] = c2[DATA_WIDTH-1:0];
                    input_col_mem[input_count][3] = c3[DATA_WIDTH-1:0];
                    input_col_mem[input_count][4] = c4[DATA_WIDTH-1:0];
                    input_count = input_count + 1;
                end
            end
            $fclose(fd);
        end
    endtask

    task automatic drive_one_column;
        input integer idx;
        begin
            center_x <= input_center_x_mem[idx];
            center_y <= input_center_y_mem[idx];
            col_0 <= input_col_mem[idx][0];
            col_1 <= input_col_mem[idx][1];
            col_2 <= input_col_mem[idx][2];
            col_3 <= input_col_mem[idx][3];
            col_4 <= input_col_mem[idx][4];
            column_valid <= 1'b1;
            do @(posedge clk); while (!column_ready);
            column_valid <= 1'b0;
            sent_columns = sent_columns + 1;
        end
    endtask

    always @(posedge clk) begin
        integer py;
        integer px;
        if (output_file != 0 && window_valid && window_ready) begin
            $fdisplay(output_file, "# idx=%0d center_x=%0d center_y=%0d", recv_patches, patch_center_x, patch_center_y);
            for (py = 0; py < 5; py = py + 1) begin
                $fwrite(output_file, "row%0d:", py);
                for (px = 0; px < 5; px = px + 1)
                    $fwrite(output_file, " %03x", patch_5x5[((py * 5) + px) * DATA_WIDTH +: DATA_WIDTH]);
                $fwrite(output_file, "\n");
            end
            recv_patches = recv_patches + 1;
        end
    end

    initial begin
        sent_columns = 0;
        recv_patches = 0;
        output_file = 0;

        read_config();
        read_input_columns();
        reset_dut();

        output_file = $fopen("actual_patch_stream.txt", "w");
        if (output_file == 0) begin
            $display("ERROR: Cannot open actual_patch_stream.txt");
            $finish;
        end

        for (input_idx = 0; input_idx < input_count; input_idx = input_idx + 1)
            drive_one_column(input_idx);

        repeat (cfg_width + 20) @(posedge clk);

        if (output_file != 0) begin
            $fclose(output_file);
            output_file = 0;
        end

        $display("PASS: assembler drove %0d columns and observed %0d patches", sent_columns, recv_patches);
        $finish;
    end

endmodule
