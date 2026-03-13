//-----------------------------------------------------------------------------
// Class: isp_csiir_reg_monitor
// Description: Monitor for APB register interface
//-----------------------------------------------------------------------------

class isp_csiir_reg_monitor extends uvm_monitor;

    `uvm_component_utils(isp_csiir_reg_monitor)

    virtual isp_csiir_reg_if vif;
    uvm_analysis_port #(isp_csiir_reg_item) ap;

    function new(string name = "isp_csiir_reg_monitor", uvm_component parent = null);
        super.new(name, parent);
        ap = new("ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual isp_csiir_reg_if)::get(this, "", "vif", vif)) begin
            `uvm_error("NOVIF", "Virtual interface not found")
        end
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            collect_transaction();
        end
    endtask

    task collect_transaction();
        isp_csiir_reg_item item;

        // Wait for APB setup phase
        @(posedge vif.clk);
        while (!(vif.psel && vif.penable)) begin
            @(posedge vif.clk);
        end

        // Capture transaction
        item = isp_csiir_reg_item::type_id::create("item");
        item.addr   = vif.paddr;
        item.write  = vif.pwrite;
        item.data   = vif.pwdata;
        item.rdata  = vif.prdata;
        item.pready = vif.pready;

        ap.write(item);

        // Wait for end of transaction
        while (vif.penable) begin
            @(posedge vif.clk);
        end
    endtask

endclass : isp_csiir_reg_monitor