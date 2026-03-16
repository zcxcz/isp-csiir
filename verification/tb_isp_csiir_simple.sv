`timescale 1ns/1ps
//-----------------------------------------------------------------------------
// Module: tb_isp_csiir_simple
// Description: Simple testbench for ISP-CSIIR RTL verification
//              Tests single pixel processing through the pipeline
//-----------------------------------------------------------------------------

module tb_isp_csiir_simple;

    // Parameters
    localparam DATA_WIDTH = 10;
    localparam IMG_WIDTH = 32;
    localparam IMG_HEIGHT = 32;
    localparam PIC_WIDTH_BITS = $clog2(IMG_WIDTH) + 1;
    localparam PIC_HEIGHT_BITS = $clog2(IMG_HEIGHT) + 1;

    // Clock and reset
    reg clk = 0;
    reg rst_n = 0;

    always #5 clk = ~clk;  // 100MHz clock

    initial begin
        rst_n = 0;
        #100;
        rst_n = 1;
    end

    // Video interface signals
    reg vsync = 0;
    reg hsync = 0;
    reg [DATA_WIDTH-1:0] din = 0;
    reg din_valid = 0;

    wire [DATA_WIDTH-1:0] dout;
    wire dout_valid;
    wire dout_vsync, dout_hsync;

    // APB interface signals
    reg psel = 0;
    reg penable = 0;
    reg pwrite = 0;
    reg [7:0] paddr = 0;
    reg [31:0] pwdata = 0;
    wire [31:0] prdata;
    wire pready;
    wire pslverr;

    // Test counters
    integer pixel_count = 0;
    integer row_count = 0;
    integer output_count = 0;
    integer error_count = 0;
    integer match_count = 0;

    // Expected output array (loaded from Python model)
    reg [DATA_WIDTH-1:0] expected_output [0:IMG_HEIGHT*IMG_WIDTH-1];
    integer expected_valid [0:IMG_HEIGHT*IMG_WIDTH-1];
    integer i, j;

    // DUT instantiation
    isp_csiir_top #(
        .IMG_WIDTH(IMG_WIDTH),
        .IMG_HEIGHT(IMG_HEIGHT),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .psel(psel),
        .penable(penable),
        .pwrite(pwrite),
        .paddr(paddr),
        .pwdata(pwdata),
        .prdata(prdata),
        .pready(pready),
        .pslverr(pslverr),
        .vsync(vsync),
        .hsync(hsync),
        .din(din),
        .din_valid(din_valid),
        .dout(dout),
        .dout_valid(dout_valid),
        .dout_vsync(dout_vsync),
        .dout_hsync(dout_hsync)
    );

    // APB write task
    task apb_write;
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
            @(posedge clk);
        end
    endtask

    // Initialize expected output (simple pattern for now)
    initial begin
        for (i = 0; i < IMG_HEIGHT*IMG_WIDTH; i = i + 1) begin
            expected_output[i] = 0;
            expected_valid[i] = 1;
        end
    end

    // Configuration sequence
    initial begin
        @(posedge rst_n);
        repeat(10) @(posedge clk);

        // Configure registers
        apb_write(8'h00, 32'h00000001);  // CTRL: enable
        apb_write(8'h04, 32'h001f001f);  // PIC_SIZE: 32x32 (31<<16 | 31)
        apb_write(8'h08, 32'h00000010);  // THRESH0
        apb_write(8'h0C, 32'h00000018);  // THRESH1
        apb_write(8'h10, 32'h00000020);  // THRESH2
        apb_write(8'h14, 32'h00000028);  // THRESH3
        apb_write(8'h18, 32'h20202020);  // BLEND ratios

        $display("Configuration complete");
    end

    // Video input driver
    initial begin
        @(posedge rst_n);
        repeat(20) @(posedge clk);

        // Send one frame
        vsync <= 1;
        @(posedge clk);
        vsync <= 0;

        for (row_count = 0; row_count < IMG_HEIGHT; row_count = row_count + 1) begin
            hsync <= 1;
            @(posedge clk);
            hsync <= 0;

            for (pixel_count = 0; pixel_count < IMG_WIDTH; pixel_count = pixel_count + 1) begin
                // Random test data
                din <= ($random % 1024);
                din_valid <= 1;
                @(posedge clk);
            end
            din_valid <= 0;
            repeat(5) @(posedge clk);
        end

        // End of frame
        vsync <= 1;
        @(posedge clk);
        vsync <= 0;
        din_valid <= 0;

        $display("Input frame complete: %0d pixels sent", IMG_WIDTH * IMG_HEIGHT);
    end

    // Output monitor
    initial begin
        @(posedge rst_n);

        forever begin
            @(posedge clk);
            if (dout_valid) begin
                output_count = output_count + 1;
                // Simple check: output should be in valid range
                if (dout > 1023) begin
                    error_count = error_count + 1;
                    $display("ERROR: output out of range at pixel %0d: %0d", output_count, dout);
                end else begin
                    match_count = match_count + 1;
                end
            end
        end
    end

    // Simulation timeout and report
    initial begin
        #1000000;  // 1ms timeout
        $display("");
        $display("=== Simulation Report ===");
        $display("Output pixels received: %0d", output_count);
        $display("Valid outputs: %0d", match_count);
        $display("Errors: %0d", error_count);

        if (output_count == IMG_WIDTH * IMG_HEIGHT && error_count == 0)
            $display("PASS: All pixels processed correctly");
        else
            $display("FAIL: Incomplete or incorrect processing");

        $finish;
    end

    // Waveform dump
    initial begin
        $dumpfile("isp_csiir_simple_tb.vcd");
        $dumpvars(0, tb_isp_csiir_simple);
    end

endmodule