//-----------------------------------------------------------------------------
// Module: isp_csiir_tb_top
// Description: Top-level testbench module for ISP-CSIIR verification
//-----------------------------------------------------------------------------

`timescale 1ns/1ps

// Include UVM package
`include "uvm_macros.svh"
import uvm_pkg::*;

// Include verification package
`include "isp_csiir_pkg.sv"

module isp_csiir_tb_top;

    // Clock and reset
    logic clk;
    logic rst_n;

    // Interfaces
    isp_csiir_pixel_if pixel_if(clk);
    isp_csiir_reg_if   reg_if(clk);

    // DUT instance
    isp_csiir_top #(
        .IMG_WIDTH (1920),
        .IMG_HEIGHT(1080),
        .DATA_WIDTH(8)
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

    // Clock generation
    initial begin
        clk = 0;
        forever #5ns clk = ~clk;  // 100MHz clock
    end

    // Reset generation
    initial begin
        rst_n = 0;
        #100ns;
        rst_n = 1;
    end

    // UVM run
    initial begin
        // Set interface handles in config db
        uvm_config_db #(virtual isp_csiir_pixel_if)::set(null, "uvm_test_top.env.pixel_agent*", "vif", pixel_if);
        uvm_config_db #(virtual isp_csiir_reg_if)::set(null, "uvm_test_top.env.reg_agent*", "vif", reg_if);

        // Run test
        run_test();
    end

    // Timeout
    initial begin
        #100ms;
        `uvm_error("TIMEOUT", "Simulation timeout reached")
        $finish;
    end

    // Waveform dump (for debugging)
    initial begin
        $dumpfile("isp_csiir_tb.vcd");
        $dumpvars(0, isp_csiir_tb_top);
    end

endmodule