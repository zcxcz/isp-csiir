//-----------------------------------------------------------------------------
// Class: isp_csiir_pixel_driver
// Description: Driver for pixel input interface
//-----------------------------------------------------------------------------

class isp_csiir_pixel_driver extends uvm_driver #(isp_csiir_pixel_item);

    `uvm_component_utils(isp_csiir_pixel_driver)

    virtual isp_csiir_pixel_if vif;
    isp_csiir_config cfg;

    function new(string name = "isp_csiir_pixel_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(isp_csiir_config)::get(this, "", "config", cfg)) begin
            `uvm_error("NOCONFIG", "Configuration not found")
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (!uvm_config_db #(virtual isp_csiir_pixel_if)::get(this, "", "vif", vif)) begin
            `uvm_error("NOVIF", "Virtual interface not found")
        end
    endfunction

    task run_phase(uvm_phase phase);
        fork
            get_and_drive();
        join
    endtask

    task get_and_drive();
        forever begin
            seq_item_port.get_next_item(req);
            drive_item(req);
            seq_item_port.item_done();
        end
    endtask

    task drive_item(isp_csiir_pixel_item item);
        @(posedge vif.clk);
        vif.din       <= item.pixel_data;
        vif.din_valid <= item.valid;
        vif.vsync     <= item.vsync;
        vif.hsync     <= item.hsync;
    endtask

endclass : isp_csiir_pixel_driver