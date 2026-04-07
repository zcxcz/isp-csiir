`timescale 1ns/1ps

module tb_isp_csiir_ready_chain_ref;

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

    `define CHECK_EQ_U(TAG, ACT, EXP) \
        if ((ACT) != (EXP)) begin \
            $display("FAIL: %s expected %0d got %0d", TAG, EXP, ACT); \
            fail_count = fail_count + 1; \
        end

    `define CHECK_EQ_BIT(TAG, ACT, EXP) \
        if ((ACT) !== (EXP)) begin \
            $display("FAIL: %s expected %b got %b", TAG, EXP, ACT); \
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
    end

    task automatic reset_dut;
        begin
            rst_n          = 1'b0;
            psel           = 1'b0;
            penable        = 1'b0;
            pwrite         = 1'b0;
            paddr          = 8'd0;
            pwdata         = 32'd0;
            vsync          = 1'b0;
            hsync          = 1'b0;
            din            = {DATA_WIDTH{1'b0}};
            din_valid      = 1'b0;
            dout_ready     = 1'b1;
            accepted_count = 0;
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

    task automatic case_a_ready_chain_accepts_first_pixel;
        begin
            $display("CASE A: SOF must open ready chain and accept first pixel");

            reset_dut();
            configure_dut();
            start_frame();

            `CHECK_EQ_BIT("caseA frame_started", dut.u_line_buffer.frame_started, 1'b1)
            `CHECK_EQ_BIT("caseA s3_ready", dut.s3_ready, 1'b1)
            `CHECK_EQ_BIT("caseA s2_ready", dut.s2_ready, 1'b1)
            `CHECK_EQ_BIT("caseA s1_ready", dut.s1_ready, 1'b1)
            `CHECK_EQ_BIT("caseA window_ready", dut.window_ready, 1'b1)
            `CHECK_EQ_BIT("caseA din_ready", din_ready, 1'b1)

            @(negedge clk);
            din       = 10'd123;
            din_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            din_valid = 1'b0;
            din       = 10'd0;
            @(posedge clk);

            `CHECK_EQ_U("caseA accepted_count", accepted_count, 1)
        end
    endtask

    initial begin
        fail_count = 0;

        $display("========================================");
        $display("ISP-CSIIR Top Ready Chain Reference");
        $display("========================================");

        case_a_ready_chain_accepts_first_pixel();

        if (fail_count != 0) begin
            $display("FAIL: top ready chain reference (%0d failures)", fail_count);
            $finish_and_return(1);
        end

        $display("PASS: top ready chain reference");
        $finish_and_return(0);
    end

    initial begin
        #20000;
        $display("FAIL: timeout");
        $finish_and_return(1);
    end

endmodule
