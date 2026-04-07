`timescale 1ns/1ps

module tb_isp_csiir_backpressure;

    localparam IMG_WIDTH       = 16;
    localparam IMG_HEIGHT      = 16;
    localparam DATA_WIDTH      = 10;
    localparam GRAD_WIDTH      = 14;
    localparam LINE_ADDR_WIDTH = 14;
    localparam ROW_CNT_WIDTH   = 13;
    localparam CLK_PERIOD      = 10;

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

    integer fail_count;
    integer accepted_count;
    integer output_fire_count;

    reg [DATA_WIDTH-1:0]        held_dout;
    integer                     held_output_fire_count;

    `define CHECK_EQ_U(TAG, ACT, EXP) \
        if ((ACT) != (EXP)) begin \
            $display("FAIL: %s expected %0d got %0d", TAG, EXP, ACT); \
            fail_count = fail_count + 1; \
        end

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

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    always @(posedge clk) begin
        if (din_valid && din_ready)
            accepted_count = accepted_count + 1;
        if (dout_valid && dout_ready)
            output_fire_count = output_fire_count + 1;
    end

    task automatic reset_counters;
        begin
            accepted_count    = 0;
            output_fire_count = 0;
        end
    endtask

    task automatic reset_dut;
        begin
            rst_n      = 1'b0;
            psel       = 1'b0;
            penable    = 1'b0;
            pwrite     = 1'b0;
            paddr      = 8'd0;
            pwdata     = 32'd0;
            vsync      = 1'b0;
            hsync      = 1'b0;
            din        = {DATA_WIDTH{1'b0}};
            din_valid  = 1'b0;
            dout_ready = 1'b1;
            repeat (10) @(posedge clk);
            rst_n = 1'b1;
            repeat (5) @(posedge clk);
        end
    endtask

    task automatic apb_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(posedge clk);
            psel   = 1'b1;
            pwrite = 1'b1;
            paddr  = addr;
            pwdata = data;
            @(posedge clk);
            penable = 1'b1;
            @(posedge clk);
            penable = 1'b0;
            psel    = 1'b0;
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
            apb_write(8'h1C, 32'd32);
            apb_write(8'h20, 32'd400);
            apb_write(8'h24, 32'd2);
        end
    endtask

    task automatic send_frame_ramp;
        integer x;
        integer y;
        integer pixel_val;
        begin
            #1;
            vsync = 1'b1;
            @(posedge clk);
            #1;
            vsync = 1'b0;
            @(posedge clk);

            for (y = 0; y < IMG_HEIGHT; y = y + 1) begin
                for (x = 0; x < IMG_WIDTH; x = x + 1) begin
                    pixel_val = (x + (y * IMG_WIDTH)) % 1024;
                    din       = pixel_val[DATA_WIDTH-1:0];
                    din_valid = 1'b1;
                    @(posedge clk);
                    while (!din_ready)
                        @(posedge clk);
                    din_valid = 1'b0;
                end

                din_valid = 1'b0;
                #1;
                hsync = 1'b1;
                @(posedge clk);
                #1;
                hsync = 1'b0;
                repeat (3) @(posedge clk);
            end
        end
    endtask

    task automatic wait_for_first_output;
        integer cycles;
        begin
            cycles = 0;
            while ((dout_valid !== 1'b1) && (cycles < 4000)) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (dout_valid !== 1'b1) begin
                $display("FAIL: timeout waiting for first dout_valid");
                $fatal(1);
            end
        end
    endtask

    task automatic case_a_backpressure_must_propagate;
        integer cycles;
        begin
            $display("CASE A: dout_ready stall must propagate to stage ready chain and din_ready");
            reset_counters();
            reset_dut();
            configure_dut();

            fork
                send_frame_ramp();
                begin
                    wait_for_first_output();

                    held_dout              = dout;
                    held_output_fire_count = output_fire_count;

                    @(negedge clk);
                    dout_ready = 1'b0;

                    for (cycles = 0; cycles < 4; cycles = cycles + 1) begin
                        @(posedge clk);
                        if (dout_valid !== 1'b1) begin
                            $display("FAIL: dout_valid dropped during output stall");
                            fail_count = fail_count + 1;
                        end
                        `CHECK_EQ_U("caseA stalled dout", dout, held_dout)
                        `CHECK_EQ_U("caseA no output fire during stall", output_fire_count, held_output_fire_count)
                    end

                    cycles = 0;
                    while ((cycles < 8) &&
                           ((dut.s3_ready !== 1'b0) ||
                            (dut.s2_ready !== 1'b0) ||
                            (dut.window_ready !== 1'b0) ||
                            (din_ready !== 1'b0))) begin
                        @(posedge clk);
                        cycles = cycles + 1;
                        if (dout_valid !== 1'b1) begin
                            $display("FAIL: dout_valid dropped while waiting for backpressure propagation");
                            fail_count = fail_count + 1;
                        end
                        `CHECK_EQ_U("caseA stalled dout while waiting", dout, held_dout)
                    end

                    if (dut.s3_ready !== 1'b0) begin
                        $display("FAIL: stage3_ready stayed high under dout stall");
                        fail_count = fail_count + 1;
                    end
                    if (dut.s2_ready !== 1'b0) begin
                        $display("FAIL: stage2_ready stayed high under dout stall");
                        fail_count = fail_count + 1;
                    end
                    if (dut.window_ready !== 1'b0) begin
                        $display("FAIL: window_ready stayed high under dout stall");
                        fail_count = fail_count + 1;
                    end
                    if (din_ready !== 1'b0) begin
                        $display("FAIL: din_ready stayed high under dout stall");
                        fail_count = fail_count + 1;
                    end

                    @(negedge clk);
                    dout_ready = 1'b1;
                    repeat (8) @(posedge clk);
                end
            join
        end
    endtask

    initial begin
        fail_count = 0;
        case_a_backpressure_must_propagate();

        if (fail_count != 0) begin
            $display("FAIL: top-level backpressure reference cases (%0d failures)", fail_count);
            $fatal(1);
        end

        $display("PASS: top-level backpressure reference cases");
        $finish;
    end

endmodule
