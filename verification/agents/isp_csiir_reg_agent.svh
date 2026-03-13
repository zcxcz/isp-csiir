//-----------------------------------------------------------------------------
// Class: isp_csiir_reg_agent
// Description: Agent for APB register interface
//-----------------------------------------------------------------------------

class isp_csiir_reg_agent extends uvm_agent;

    `uvm_component_utils(isp_csiir_reg_agent)

    isp_csiir_reg_driver  driver;
    isp_csiir_reg_monitor monitor;
    uvm_sequencer #(isp_csiir_reg_item) sequencer;

    function new(string name = "isp_csiir_reg_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        monitor = isp_csiir_reg_monitor::type_id::create("monitor", this);

        if (get_is_active() == UVM_ACTIVE) begin
            driver    = isp_csiir_reg_driver::type_id::create("driver", this);
            sequencer = uvm_sequencer #(isp_csiir_reg_item)::type_id::create("sequencer", this);
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (get_is_active() == UVM_ACTIVE) begin
            driver.seq_item_port.connect(sequencer.seq_item_export);
        end
    endfunction

endclass : isp_csiir_reg_agent