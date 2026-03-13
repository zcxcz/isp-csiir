//-----------------------------------------------------------------------------
// Interface: isp_csiir_pixel_if
// Description: Interface for pixel data streaming
//-----------------------------------------------------------------------------

interface isp_csiir_pixel_if(input logic clk);

    // Clocking block for driver (active)
    clocking driver_cb @(posedge clk);
        output vsync, hsync, din, din_valid;
        input  dout, dout_valid, dout_vsync, dout_hsync;
    endclocking

    // Clocking block for monitor (passive)
    clocking monitor_cb @(posedge clk);
        input vsync, hsync, din, din_valid;
        input dout, dout_valid, dout_vsync, dout_hsync;
    endclocking

    // Signals
    logic        vsync;
    logic        hsync;
    logic [7:0]  din;
    logic        din_valid;

    logic [7:0]  dout;
    logic        dout_valid;
    logic        dout_vsync;
    logic        dout_hsync;

    // Modports
    modport driver  (clocking driver_cb);
    modport monitor (clocking monitor_cb);

endinterface : isp_csiir_pixel_if