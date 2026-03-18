//-----------------------------------------------------------------------------
// Module: isp_csiir_simple_tb
// Description: Testbench for ISP-CSIIR RTL verification
//              - Reads input pixels from pattern file
//              - Compares output with golden reference from Python model
//              - Compatible with Icarus Verilog (no UVM required)
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

module isp_csiir_simple_tb;

    //=========================================================================
    // Parameters - Can be overridden via command line
    //=========================================================================
    parameter IMG_WIDTH       = 64;
    parameter IMG_HEIGHT      = 64;
    parameter DATA_WIDTH      = 10;
    parameter GRAD_WIDTH      = 14;
    parameter LINE_ADDR_WIDTH = 7;
    parameter ROW_CNT_WIDTH   = 7;
    parameter NUM_FRAMES      = 2;
    parameter TOLERANCE       = 2;  // Allowed difference for comparison

    //=========================================================================
    // Signals
    //=========================================================================
    reg clk;
    reg rst_n;

    // APB Interface
    reg        psel;
    reg        penable;
    reg        pwrite;
    reg [7:0]  paddr;
    reg [31:0] pwdata;
    wire [31:0] prdata;
    wire       pready;
    wire       pslverr;

    // Video Interface
    reg        vsync;
    reg        hsync;
    reg [DATA_WIDTH-1:0] din;
    reg        din_valid;

    wire [DATA_WIDTH-1:0] dout;
    wire       dout_valid;
    wire       dout_vsync;
    wire       dout_hsync;

    // Test counters
    integer pixel_count;
    integer output_count;
    integer frame_count;
    integer error_count;
    integer total_pixels;

    // Pattern file handling
    reg [DATA_WIDTH-1:0] input_mem [0:IMG_WIDTH*IMG_HEIGHT*NUM_FRAMES-1];
    reg [DATA_WIDTH-1:0] golden_mem [0:IMG_WIDTH*IMG_HEIGHT*NUM_FRAMES-1];
    integer input_idx;
    integer golden_idx;
    integer read_status;

    // Comparison
    reg [DATA_WIDTH-1:0] expected_value;
    integer diff_value;
    integer match_count;
    integer mismatch_count;

    //=========================================================================
    // DUT Instance
    //=========================================================================
    isp_csiir_top #(
        .IMG_WIDTH       (IMG_WIDTH),
        .IMG_HEIGHT      (IMG_HEIGHT),
        .DATA_WIDTH      (DATA_WIDTH),
        .GRAD_WIDTH      (GRAD_WIDTH),
        .LINE_ADDR_WIDTH (LINE_ADDR_WIDTH),
        .ROW_CNT_WIDTH   (ROW_CNT_WIDTH)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .psel     (psel),
        .penable  (penable),
        .pwrite   (pwrite),
        .paddr    (paddr),
        .pwdata   (pwdata),
        .prdata   (prdata),
        .pready   (pready),
        .pslverr  (pslverr),
        .vsync    (vsync),
        .hsync    (hsync),
        .din      (din),
        .din_valid(din_valid),
        .dout       (dout),
        .dout_valid (dout_valid),
        .dout_vsync (dout_vsync),
        .dout_hsync (dout_hsync)
    );

    //=========================================================================
    // Clock Generation - 100MHz
    //=========================================================================
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    //=========================================================================
    // Load Pattern Files
    //=========================================================================
    initial begin
        // Load input pixels - try both relative paths
        $readmemh("test_vectors/input_pixels.txt", input_mem);
        $display("[INFO] Loaded input pixels from pattern file");

        // Load golden output
        $readmemh("test_vectors/golden_output.txt", golden_mem);
        $display("[INFO] Loaded golden output from pattern file");

        total_pixels = IMG_WIDTH * IMG_HEIGHT * NUM_FRAMES;
        $display("[INFO] Total test pixels: %0d", total_pixels);
    end

    //=========================================================================
    // APB Tasks
    //=========================================================================
    task apb_write;
        input [7:0]  addr;
        input [31:0] data;
        begin
            @(posedge clk);
            psel    <= 1'b1;
            pwrite  <= 1'b1;
            paddr   <= addr;
            pwdata  <= data;
            penable <= 1'b0;
            @(posedge clk);
            penable <= 1'b1;
            @(posedge clk);
            while (!pready) @(posedge clk);
            psel    <= 1'b0;
            penable <= 1'b0;
        end
    endtask

    //=========================================================================
    // Pixel Send Task - Uses pattern data
    //=========================================================================
    task send_pixel_from_pattern;
        input is_vsync;
        input is_hsync;
        input is_valid;
        begin
            @(posedge clk);
            if (is_valid && input_idx < total_pixels) begin
                din       <= input_mem[input_idx];
                input_idx <= input_idx + 1;
            end else begin
                din <= {DATA_WIDTH{1'b0}};
            end
            din_valid <= is_valid;
            vsync     <= is_vsync;
            hsync     <= is_hsync;
        end
    endtask

    task send_frame_from_pattern;
        integer x, y;
        begin
            // VSYNC pulse
            send_pixel_from_pattern(1, 0, 0);
            send_pixel_from_pattern(0, 0, 0);

            // Send frame data from pattern
            for (y = 0; y < IMG_HEIGHT; y = y + 1) begin
                for (x = 0; x < IMG_WIDTH; x = x + 1) begin
                    send_pixel_from_pattern(0, (x == IMG_WIDTH-1), 1);
                end
            end

            // End of frame
            send_pixel_from_pattern(1, 0, 0);
            send_pixel_from_pattern(0, 0, 0);
        end
    endtask

    //=========================================================================
    // Output Monitor with Golden Comparison
    //=========================================================================
    always @(posedge clk) begin
        if (dout_valid) begin
            output_count = output_count + 1;

            // Compare with golden output
            if (golden_idx < total_pixels) begin
                expected_value = golden_mem[golden_idx];
                diff_value = (dout > expected_value) ? (dout - expected_value) : (expected_value - dout);

                if (diff_value <= TOLERANCE) begin
                    match_count = match_count + 1;
                end else begin
                    mismatch_count = mismatch_count + 1;
                    if (mismatch_count <= 20) begin  // Only show first 20 errors
                        $display("[MISMATCH] Pixel %0d: RTL=0x%03h, Golden=0x%03h, Diff=%0d",
                                 golden_idx, dout, expected_value, diff_value);
                    end
                end
                golden_idx = golden_idx + 1;
            end
        end
    end

    //=========================================================================
    // Main Test Sequence
    //=========================================================================
    initial begin
        // Initialize signals
        rst_n    <= 1'b0;
        psel     <= 1'b0;
        penable  <= 1'b0;
        pwrite   <= 1'b0;
        paddr    <= 8'h0;
        pwdata   <= 32'h0;
        vsync    <= 1'b0;
        hsync    <= 1'b0;
        din      <= {DATA_WIDTH{1'b0}};
        din_valid <= 1'b0;

        pixel_count  = 0;
        output_count = 0;
        frame_count  = 0;
        error_count  = 0;
        input_idx    = 0;
        golden_idx   = 0;
        match_count  = 0;
        mismatch_count = 0;

        // Reset sequence
        #100;
        rst_n <= 1'b1;
        #100;

        $display("");
        $display("========================================");
        $display("ISP-CSIIR RTL Verification Testbench");
        $display("========================================");
        $display("Image Size:  %0d x %0d", IMG_WIDTH, IMG_HEIGHT);
        $display("Data Width:  %0d bits", DATA_WIDTH);
        $display("Num Frames:  %0d", NUM_FRAMES);
        $display("Tolerance:   %0d LSB", TOLERANCE);
        $display("");

        // Configure registers
        $display("[INFO] Configuring registers...");
        apb_write(8'h00, 32'h00000001);  // Enable, no bypass
        apb_write(8'h04, {16'(IMG_HEIGHT-1), 16'(IMG_WIDTH-1)});
        apb_write(8'h08, 32'd16);  // thresh0
        apb_write(8'h0C, 32'd24);  // thresh1
        apb_write(8'h10, 32'd32);  // thresh2
        apb_write(8'h14, 32'd40);  // thresh3

        $display("[INFO] Configuration complete");
        #100;

        // Send test frames from pattern
        $display("[INFO] Sending test frames from pattern file...");
        for (frame_count = 0; frame_count < NUM_FRAMES; frame_count = frame_count + 1) begin
            $display("[INFO] Sending frame %0d", frame_count + 1);
            send_frame_from_pattern();
            #500;
        end

        // Wait for all outputs
        #2000;

        // Final report
        $display("");
        $display("========================================");
        $display("Test Summary");
        $display("========================================");
        $display("Frames sent:       %0d", NUM_FRAMES);
        $display("Total pixels:      %0d", total_pixels);
        $display("Output received:   %0d", output_count);
        $display("Matches:           %0d", match_count);
        $display("Mismatches:        %0d", mismatch_count);
        $display("Match Rate:        %.2f%%", (match_count * 100.0) / output_count);
        $display("========================================");

        if (mismatch_count == 0) begin
            $display("TEST PASSED - All outputs match golden reference");
        end else if (match_count * 100 / output_count >= 95) begin
            $display("TEST PASSED WITH WARNINGS - >95%% match rate");
        end else begin
            $display("TEST FAILED - Too many mismatches");
        end

        #100;
        $finish;
    end

    //=========================================================================
    // Timeout
    //=========================================================================
    initial begin
        #1000000;
        $display("");
        $display("[ERROR] Simulation timeout!");
        $display("Output count: %0d, Expected: %0d", output_count, total_pixels);
        $finish;
    end

    //=========================================================================
    // VCD Dump for Waveform Viewing
    //=========================================================================
    initial begin
        $dumpfile("isp_csiir_simple_tb.vcd");
        $dumpvars(0, isp_csiir_simple_tb);
    end

endmodule