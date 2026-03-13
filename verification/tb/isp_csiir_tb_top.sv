//-----------------------------------------------------------------------------
// Module: isp_csiir_tb_top
// Description: Top-level testbench module for ISP-CSIIR verification
//              Fully parameterized for different resolutions and data widths
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

// Include UVM package
`include "uvm_macros.svh"
import uvm_pkg::*;

// Include verification package
`include "isp_csiir_pkg.sv"

module isp_csiir_tb_top;

    //=========================================================================
    // Parameters - Can be overridden via command line
    //=========================================================================
    // Default to 8K 10-bit, can be changed via +IMG_WIDTH=1920 +IMG_HEIGHT=1080 +DATA_WIDTH=8
    parameter int IMG_WIDTH  = 5472;
    parameter int IMG_HEIGHT = 3076;
    parameter int DATA_WIDTH = 10;
    parameter int GRAD_WIDTH = 14;
    parameter int LINE_ADDR_WIDTH = 14;
    parameter int ROW_CNT_WIDTH = 13;

    // Clock and reset
    logic clk;
    logic rst_n;

    // Interfaces
    isp_csiir_pixel_if #(.DATA_WIDTH(DATA_WIDTH)) pixel_if(clk);
    isp_csiir_reg_if   reg_if(clk);

    //=========================================================================
    // DUT Instance - Fully Parameterized
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

        // APB Interface
        .psel     (reg_if.psel),
        .penable  (reg_if.penable),
        .pwrite   (reg_if.pwrite),
        .paddr    (reg_if.paddr),
        .pwdata   (reg_if.pwdata),
        .prdata   (reg_if.prdata),
        .pready   (reg_if.pready),
        .pslverr  (reg_if.pslverr),

        // Video Input
        .vsync    (pixel_if.vsync),
        .hsync    (pixel_if.hsync),
        .din      (pixel_if.din),
        .din_valid(pixel_if.din_valid),

        // Video Output
        .dout       (pixel_if.dout),
        .dout_valid (pixel_if.dout_valid),
        .dout_vsync (pixel_if.dout_vsync),
        .dout_hsync (pixel_if.dout_hsync)
    );

    //=========================================================================
    // Clock Generation - 100MHz (10ns period)
    //=========================================================================
    initial begin
        clk = 0;
        forever #5ns clk = ~clk;
    end

    //=========================================================================
    // Reset Generation
    //=========================================================================
    initial begin
        rst_n = 0;
        #100ns;
        rst_n = 1;
    end

    //=========================================================================
    // UVM Run
    //=========================================================================
    initial begin
        // Set interface handles in config db
        uvm_config_db #(virtual isp_csiir_pixel_if #(.DATA_WIDTH(DATA_WIDTH)))::set(
            null, "uvm_test_top.env.pixel_agent*", "vif", pixel_if);
        uvm_config_db #(virtual isp_csiir_reg_if)::set(
            null, "uvm_test_top.env.reg_agent*", "vif", reg_if);

        // Set parameters in config db
        uvm_config_db #(int)::set(null, "*", "img_width", IMG_WIDTH);
        uvm_config_db #(int)::set(null, "*", "img_height", IMG_HEIGHT);
        uvm_config_db #(int)::set(null, "*", "data_width", DATA_WIDTH);

        // Run test
        run_test();
    end

    //=========================================================================
    // Timeout - Extended for 8K resolution
    //=========================================================================
    initial begin
        // 8K image takes longer to process
        #500ms;
        `uvm_error("TIMEOUT", "Simulation timeout reached")
        $finish;
    end

    //=========================================================================
    // Waveform Dump (for debugging)
    //=========================================================================
    initial begin
        $dumpfile("isp_csiir_tb.vcd");
        $dumpvars(0, isp_csiir_tb_top);
    end

endmodule