`timescale 1ns/1ps

module tb_isp_csiir_stage4_align;

    localparam IMG_WIDTH       = 16;
    localparam IMG_HEIGHT      = 16;
    localparam DATA_WIDTH      = 10;
    localparam GRAD_WIDTH      = 14;
    localparam LINE_ADDR_WIDTH = 14;
    localparam ROW_CNT_WIDTH   = 13;
    localparam PATCH_ELEMS     = 25;
    localparam PATCH_WIDTH     = DATA_WIDTH * PATCH_ELEMS;
    localparam MAX_PIXELS         = IMG_WIDTH * IMG_HEIGHT;
    localparam CLK_PERIOD         = 10;
    localparam EDGE_PROTECT       = 8'd37;
    localparam MIN_CHECKED_SAMPLES = 64;

    reg                         clk;
    reg                         rst_n;
    reg                         psel;
    reg                         penable;
    reg                         pwrite;
    reg  [7:0]                  paddr;
    reg  [31:0]                 pwdata;
    wire [31:0]                 prdata;
    wire                        pready;
    wire                        pslverr;
    reg                         vsync;
    reg                         hsync;
    reg  [DATA_WIDTH-1:0]       din;
    reg                         din_valid;
    wire                        din_ready;
    wire [DATA_WIDTH-1:0]       dout;
    wire                        dout_valid;
    reg                         dout_ready;
    wire                        dout_vsync;
    wire                        dout_hsync;

    reg  [PATCH_WIDTH-1:0]      captured_patch [0:MAX_PIXELS-1];
    reg  [GRAD_WIDTH-1:0]       captured_grad_h [0:MAX_PIXELS-1];
    reg  [GRAD_WIDTH-1:0]       captured_grad_v [0:MAX_PIXELS-1];
    reg  [DATA_WIDTH-1:0]       captured_center [0:MAX_PIXELS-1];
    reg                         captured_valid [0:MAX_PIXELS-1];

    integer                     idx;
    integer                     frame_pixel_idx;
    integer                     window_valid_count;
    integer                     s1_valid_count;
    integer                     s2_valid_count;
    integer                     s3_valid_count;
    integer                     s4_valid_count;
    integer                     checked_sample_count;
    integer                     last_checked_idx;
    reg                         check_done;

    function automatic integer pixel_index;
        input [LINE_ADDR_WIDTH-1:0] x;
        input [ROW_CNT_WIDTH-1:0]   y;
        begin
            pixel_index = (y * IMG_WIDTH) + x;
        end
    endfunction

    function automatic [PATCH_WIDTH-1:0] pack_s1_patch;
        reg [PATCH_WIDTH-1:0] patch;
        begin
            patch = {PATCH_WIDTH{1'b0}};
            patch[(0*5+0)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_0_0;
            patch[(0*5+1)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_0_1;
            patch[(0*5+2)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_0_2;
            patch[(0*5+3)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_0_3;
            patch[(0*5+4)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_0_4;
            patch[(1*5+0)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_1_0;
            patch[(1*5+1)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_1_1;
            patch[(1*5+2)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_1_2;
            patch[(1*5+3)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_1_3;
            patch[(1*5+4)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_1_4;
            patch[(2*5+0)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_2_0;
            patch[(2*5+1)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_2_1;
            patch[(2*5+2)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_2_2;
            patch[(2*5+3)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_2_3;
            patch[(2*5+4)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_2_4;
            patch[(3*5+0)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_3_0;
            patch[(3*5+1)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_3_1;
            patch[(3*5+2)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_3_2;
            patch[(3*5+3)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_3_3;
            patch[(3*5+4)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_3_4;
            patch[(4*5+0)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_4_0;
            patch[(4*5+1)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_4_1;
            patch[(4*5+2)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_4_2;
            patch[(4*5+3)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_4_3;
            patch[(4*5+4)*DATA_WIDTH +: DATA_WIDTH] = dut.s1_win_4_4;
            pack_s1_patch = patch;
        end
    endfunction

    function automatic [DATA_WIDTH-1:0] patch_cell;
        input [PATCH_WIDTH-1:0] patch;
        input integer row;
        input integer col;
        integer lsb;
        begin
            lsb = ((row * 5) + col) * DATA_WIDTH;
            patch_cell = patch[lsb +: DATA_WIDTH];
        end
    endfunction

    task automatic clear_scoreboard;
        integer score_idx;
        begin
            for (score_idx = 0; score_idx < MAX_PIXELS; score_idx = score_idx + 1) begin
                captured_patch[score_idx]  = {PATCH_WIDTH{1'b0}};
                captured_grad_h[score_idx] = {GRAD_WIDTH{1'b0}};
                captured_grad_v[score_idx] = {GRAD_WIDTH{1'b0}};
                captured_center[score_idx] = {DATA_WIDTH{1'b0}};
                captured_valid[score_idx]  = 1'b0;
            end
        end
    endtask

    task automatic apb_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(negedge clk);
            psel    = 1'b1;
            pwrite  = 1'b1;
            paddr   = addr;
            pwdata  = data;
            penable = 1'b0;
            @(negedge clk);
            penable = 1'b1;
            @(negedge clk);
            penable = 1'b0;
            psel    = 1'b0;
            pwrite  = 1'b0;
            paddr   = 8'd0;
            pwdata  = 32'd0;
            @(posedge clk);
        end
    endtask

    task automatic configure_dut;
        begin
            apb_write(8'h00, 32'h0000_0001);
            apb_write(8'h04, {16'(IMG_HEIGHT), 16'(IMG_WIDTH)});
            apb_write(8'h0C, 32'd16);
            apb_write(8'h10, 32'd24);
            apb_write(8'h14, 32'd32);
            apb_write(8'h18, 32'd40);
            apb_write(8'h1C, {8'd32, 8'd32, 8'd32, 8'd32});
            apb_write(8'h20, {6'd0, 10'd23, 6'd0, 10'd15});
            apb_write(8'h28, {24'd0, EDGE_PROTECT});
            apb_write(8'h2C, {6'd0, 10'd39, 6'd0, 10'd31});
        end
    endtask

    task automatic reset_dut;
        begin
            rst_n       = 1'b0;
            psel        = 1'b0;
            penable     = 1'b0;
            pwrite      = 1'b0;
            paddr       = 8'd0;
            pwdata      = 32'd0;
            vsync       = 1'b0;
            hsync       = 1'b0;
            din         = {DATA_WIDTH{1'b0}};
            din_valid   = 1'b0;
            dout_ready       = 1'b1;
            check_done          = 1'b0;
            checked_sample_count = 0;
            last_checked_idx     = -1;
            window_valid_count   = 0;
            s1_valid_count       = 0;
            s2_valid_count       = 0;
            s3_valid_count       = 0;
            s4_valid_count       = 0;
            clear_scoreboard();
            repeat (10) @(posedge clk);
            rst_n = 1'b1;
            repeat (5) @(posedge clk);
        end
    endtask

    task automatic start_frame;
        begin
            #1;
            vsync = 1'b1;
            @(posedge clk);
            #1;
            vsync = 1'b0;
            @(posedge clk);
        end
    endtask

    task automatic send_pixel;
        input [DATA_WIDTH-1:0] value;
        integer wait_cycles;
        begin
            @(negedge clk);
            din       = value;
            din_valid = 1'b1;
            @(posedge clk);
            wait_cycles = 0;
            while (din_ready !== 1'b1) begin
                wait_cycles = wait_cycles + 1;
                if (wait_cycles > 64) begin
                    $display("FAIL: din_ready stuck low while sending pixel=%0d din_ready=%b lb_enable=%b cfg_enable=%b cfg_bypass=%b row_cnt=%0d wr_col=%0d frame_started=%b window_ready=%b s1_ready=%b s2_ready=%b s3_ready=%b",
                             value, din_ready, dut.u_line_buffer.enable, dut.cfg_enable, dut.cfg_bypass,
                             dut.u_line_buffer.row_cnt, dut.u_line_buffer.wr_col_ptr,
                             dut.u_line_buffer.frame_started, dut.window_ready, dut.s1_ready, dut.s2_ready, dut.s3_ready);
                    $fatal(1);
                end
                @(posedge clk);
            end
            @(negedge clk);
            din_valid = 1'b0;
            din       = {DATA_WIDTH{1'b0}};
        end
    endtask

    task automatic send_ramp_frame;
        integer x;
        integer y;
        begin
            frame_pixel_idx = 0;
            start_frame();
            for (y = 0; y < IMG_HEIGHT; y = y + 1) begin
                for (x = 0; x < IMG_WIDTH; x = x + 1) begin
                    send_pixel(frame_pixel_idx[DATA_WIDTH-1:0]);
                    frame_pixel_idx = frame_pixel_idx + 1;
                end
                @(negedge clk);
                hsync = 1'b1;
                @(posedge clk);
                @(negedge clk);
                hsync = 1'b0;
                repeat (3) @(posedge clk);
            end
        end
    endtask

    task automatic check_stage4_alignment;
        input integer sample_idx;
        integer local_fail;
        begin
            local_fail = 0;

            if (captured_valid[sample_idx] !== 1'b1) begin
                $display("FAIL: missing Stage1 capture for Stage3 sample x=%0d y=%0d idx=%0d",
                         dut.s3_pixel_x, dut.s3_pixel_y, sample_idx);
                local_fail = local_fail + 1;
            end

            if (dut.u_stage4.center_pixel !== captured_center[sample_idx]) begin
                $display("FAIL: center pixel misaligned for x=%0d y=%0d expected=%0h got=%0h",
                         dut.s3_pixel_x, dut.s3_pixel_y,
                         captured_center[sample_idx], dut.u_stage4.center_pixel);
                local_fail = local_fail + 1;
            end

            if (dut.u_stage4.reg_edge_protect !== EDGE_PROTECT) begin
                $display("FAIL: edge protect not forwarded expected=%0d got=%0h",
                         EDGE_PROTECT, dut.u_stage4.reg_edge_protect);
                local_fail = local_fail + 1;
            end

            if (dut.u_stage4.src_patch_5x5 !== captured_patch[sample_idx]) begin
                $display("FAIL: Stage4 patch not aligned for x=%0d y=%0d expected_center=%0h got_center=%0h",
                         dut.s3_pixel_x, dut.s3_pixel_y,
                         patch_cell(captured_patch[sample_idx], 2, 2),
                         patch_cell(dut.u_stage4.src_patch_5x5, 2, 2));
                local_fail = local_fail + 1;
            end

            if (dut.u_stage4.grad_h !== captured_grad_h[sample_idx]) begin
                $display("FAIL: Stage4 grad_h not aligned for x=%0d y=%0d expected=%0h got=%0h",
                         dut.s3_pixel_x, dut.s3_pixel_y,
                         captured_grad_h[sample_idx], dut.u_stage4.grad_h);
                local_fail = local_fail + 1;
            end

            if (dut.u_stage4.grad_v !== captured_grad_v[sample_idx]) begin
                $display("FAIL: Stage4 grad_v not aligned for x=%0d y=%0d expected=%0h got=%0h",
                         dut.s3_pixel_x, dut.s3_pixel_y,
                         captured_grad_v[sample_idx], dut.u_stage4.grad_v);
                local_fail = local_fail + 1;
            end

            if (local_fail != 0)
                $fatal(1);

            checked_sample_count = checked_sample_count + 1;
            last_checked_idx = sample_idx;
            if (checked_sample_count >= MIN_CHECKED_SAMPLES)
                check_done = 1'b1;
        end
    endtask

    isp_csiir_top #(
        .IMG_WIDTH       (IMG_WIDTH),
        .IMG_HEIGHT      (IMG_HEIGHT),
        .DATA_WIDTH      (DATA_WIDTH),
        .GRAD_WIDTH      (GRAD_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH),
        .ROW_CNT_WIDTH   (ROW_CNT_WIDTH)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .psel       (psel),
        .penable    (penable),
        .pwrite     (pwrite),
        .paddr      (paddr),
        .pwdata     (pwdata),
        .prdata     (prdata),
        .pready     (pready),
        .pslverr    (pslverr),
        .vsync      (vsync),
        .hsync      (hsync),
        .din        (din),
        .din_valid  (din_valid),
        .din_ready  (din_ready),
        .dout       (dout),
        .dout_valid (dout_valid),
        .dout_ready (dout_ready),
        .dout_vsync (dout_vsync),
        .dout_hsync (dout_hsync)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    always @(posedge clk) begin
        if (rst_n && dut.window_valid)
            window_valid_count = window_valid_count + 1;
        if (rst_n && dut.s1_valid)
            s1_valid_count = s1_valid_count + 1;
        if (rst_n && dut.s2_valid)
            s2_valid_count = s2_valid_count + 1;
        if (rst_n && dut.s3_valid)
            s3_valid_count = s3_valid_count + 1;
        if (rst_n && dut.s4_dout_valid)
            s4_valid_count = s4_valid_count + 1;

        if (rst_n && dut.s1_valid && dut.s1_ready) begin
            idx = pixel_index(dut.s1_pixel_x, dut.s1_pixel_y);
            if ((idx >= 0) && (idx < MAX_PIXELS)) begin
                captured_patch[idx]  = pack_s1_patch();
                captured_grad_h[idx] = dut.s1_grad_h;
                captured_grad_v[idx] = dut.s1_grad_v;
                captured_center[idx] = dut.s1_center_pixel;
                captured_valid[idx]  = 1'b1;
            end
        end

        if (rst_n && !check_done && dut.s3_valid && dut.s3_ready) begin
            idx = pixel_index(dut.s3_pixel_x, dut.s3_pixel_y);
            if ((idx >= 0) && (idx < MAX_PIXELS) && (idx != last_checked_idx))
                check_stage4_alignment(idx);
        end
    end

    initial begin
        $display("========================================");
        $display("ISP-CSIIR Stage4 Top Alignment");
        $display("========================================");

        reset_dut();
        configure_dut();
        send_ramp_frame();

        repeat (256) @(posedge clk);

        if (!check_done) begin
            $display("DEBUG: window_valid=%0d s1_valid=%0d s2_valid=%0d s3_valid=%0d s4_valid=%0d checked=%0d last_idx=%0d",
                     window_valid_count, s1_valid_count, s2_valid_count, s3_valid_count, s4_valid_count,
                     checked_sample_count, last_checked_idx);
            $display("FAIL: timeout waiting for Stage3/Stage4 alignment check");
            $fatal(1);
        end

        $display("PASS: Stage4 top alignment checked_samples=%0d", checked_sample_count);
        $finish;
    end

    initial begin
        #50000;
        $display("FAIL: timeout");
        $fatal(1);
    end

endmodule
