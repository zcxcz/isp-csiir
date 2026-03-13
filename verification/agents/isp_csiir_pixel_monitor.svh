//-----------------------------------------------------------------------------
// Class: isp_csiir_pixel_monitor
// Description: Monitor for pixel input/output interface
//-----------------------------------------------------------------------------

class isp_csiir_pixel_monitor extends uvm_monitor;

    `uvm_component_utils(isp_csiir_pixel_monitor)

    virtual isp_csiir_pixel_if vif;
    uvm_analysis_port #(isp_csiir_pixel_item) ap;

    function new(string name = "isp_csiir_pixel_monitor", uvm_component parent = null);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual isp_csiir_pixel_if)::get(this, "", "vif", vif)) begin
            `uvm_error("NOVIF", "Virtual interface not found")
        end
    endfunction

    task run_phase(uvm_phase phase);
        fork
            collect_input();
            collect_output();
        join
    endtask

    task collect_input();
        isp_csiir_pixel_item item;
        forever begin
            @(posedge vif.clk);
            if (vif.din_valid) begin
                item = isp_csiir_pixel_item::type_id::create("item");
                item.pixel_data = vif.din;
                item.valid      = vif.din_valid;
                item.vsync      = vif.vsync;
                item.hsync      = vif.hsync;
                ap.write(item);
            end
        end
    endtask

    task collect_output();
        isp_csiir_pixel_item item;
        forever begin
            @(posedge vif.clk);
            if (vif.dout_valid) begin
                item = isp_csiir_pixel_item::type_id::create("item");
                item.result_data  = vif.dout;
                item.result_valid = vif.dout_valid;
                ap.write(item);
            end
        end
    endtask

endclass : isp_csiir_pixel_monitor