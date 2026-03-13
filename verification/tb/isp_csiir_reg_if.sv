//-----------------------------------------------------------------------------
// Interface: isp_csiir_reg_if
// Description: Interface for APB register configuration
//-----------------------------------------------------------------------------

interface isp_csiir_reg_if(input logic clk);

    // Clocking block for driver
    clocking driver_cb @(posedge clk);
        output psel, penable, pwrite, paddr, pwdata;
        input  prdata, pready, pslverr;
    endclocking

    // Clocking block for monitor
    clocking monitor_cb @(posedge clk);
        input psel, penable, pwrite, paddr, pwdata;
        input prdata, pready, pslverr;
    endclocking

    // APB Signals
    logic        psel;
    logic        penable;
    logic        pwrite;
    logic [7:0]  paddr;
    logic [31:0] pwdata;
    logic [31:0] prdata;
    logic        pready;
    logic        pslverr;

    // Modports
    modport driver  (clocking driver_cb);
    modport monitor (clocking monitor_cb);

    // Initialization
    initial begin
        psel    = 0;
        penable = 0;
        pwrite  = 0;
        paddr   = 0;
        pwdata  = 0;
    end

endinterface : isp_csiir_reg_if