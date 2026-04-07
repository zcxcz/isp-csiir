`timescale 1ns/1ps

module tb_stage_trace;
    reg clk = 0;
    reg rst_n = 0;
    reg [31:0] cycle = 0;

    // APB interface
    reg psel = 0, penable = 0, pwrite = 0;
    reg [7:0] paddr = 0;
    reg [31:0] pwdata = 0;
    wire [31:0] prdata;
    wire pready, pslverr;

    // Video interface
    reg vsync = 0, hsync = 0;
    reg [9:0] din = 0;
    reg din_valid = 0;
    wire din_ready;

    // Output
    wire [9:0] dout;
    wire dout_valid;
    wire dout_vsync, dout_hsync;
    wire dout_ready = 1'b1;

    always #5 clk = ~clk;
    always @(posedge clk) cycle <= cycle + 1;

    // Instantiate DUT
    isp_csiir_top #(
        .IMG_WIDTH(16), .IMG_HEIGHT(16), .DATA_WIDTH(10),
        .GRAD_WIDTH(14), .LINE_ADDR_WIDTH(14), .ROW_CNT_WIDTH(13)
    ) dut (.*);

    // Monitor valid signals
    integer s2_cnt, s3_cnt, s4_cnt;
    initial begin
        s2_cnt = 0;
        s3_cnt = 0;
        s4_cnt = 0;
    end

    always @(posedge clk) begin
        if (dut.s2_valid && s2_cnt < 5) begin
            s2_cnt = s2_cnt + 1;
            $display("[%0d] S2_VALID: px=%0d py=%0d avg0_c=%0d",
                cycle, dut.s2_pixel_x, dut.s2_pixel_y, $signed(dut.s2_avg0_c));
        end
        if (dut.s3_valid && s3_cnt < 5) begin
            s3_cnt = s3_cnt + 1;
            $display("[%0d] S3_VALID: px=%0d py=%0d blend0=%0d",
                cycle, dut.s3_pixel_x, dut.s3_pixel_y, $signed(dut.s3_blend0));
        end
        if (dut.s4_dout_valid && s4_cnt < 5) begin
            s4_cnt = s4_cnt + 1;
            $display("[%0d] S4_VALID: px=%0d py=%0d dout=%0d",
                cycle, dut.s4_pixel_x, dut.s4_pixel_y, dout);
        end
    end

    // APB write task
    task apb_write(input [7:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            psel = 1; pwrite = 1; paddr = addr; pwdata = data;
            @(posedge clk);
            penable = 1;
            @(posedge clk);
            penable = 0; psel = 0;
        end
    endtask

    // Send pixel task
    task send_pixel(input [9:0] val);
        begin
            din = val;
            din_valid = 1;
            @(posedge clk);
            while (!din_ready) @(posedge clk);
            din_valid = 0;
        end
    endtask

    initial begin
        #20 rst_n = 1;
        #50;

        $display("\n=== Configuring DUT ===");
        apb_write(8'h00, 32'b1);           // Enable
        apb_write(8'h04, {16'd16, 16'd16}); // Width=16, Height=16

        $display("\n=== Sending 256 pixels ===");
        repeat(256) begin
            send_pixel(10'd512);  // Mid-value pixels
        end

        $display("\n=== Waiting for outputs ===");
        repeat(1000) @(posedge clk);

        $display("\n=== Summary ===");
        $display("S2 outputs: %0d", s2_cnt);
        $display("S3 outputs: %0d", s3_cnt);
        $display("S4 outputs: %0d", s4_cnt);

        $finish;
    end

endmodule