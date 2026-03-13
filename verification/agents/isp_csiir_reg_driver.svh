//-----------------------------------------------------------------------------
// Class: isp_csiir_reg_driver
// Description: Driver for APB register interface
//-----------------------------------------------------------------------------

class isp_csiir_reg_driver extends uvm_driver #(isp_csiir_reg_item);

    `uvm_component_utils(isp_csiir_reg_driver)

    virtual isp_csiir_reg_if vif;

    function new(string name = "isp_csiir_reg_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual isp_csiir_reg_if)::get(this, "", "vif", vif)) begin
            `uvm_error("NOVIF", "Virtual interface not found")
        end
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            seq_item_port.get_next_item(req);
            drive_item(req);
            seq_item_port.item_done();
        end
    endtask

    task drive_item(isp_csiir_reg_item item);
        // APB write sequence
        if (item.write) begin
            // Setup phase
            @(posedge vif.clk);
            vif.psel    <= 1'b1;
            vif.pwrite  <= 1'b1;
            vif.paddr   <= item.addr;
            vif.pwdata  <= item.data;
            vif.penable <= 1'b0;

            // Access phase
            @(posedge vif.clk);
            vif.penable <= 1'b1;

            // Wait for ready
            @(posedge vif.clk);
            while (!vif.pready) @(posedge vif.clk);

            // Idle phase
            vif.psel    <= 1'b0;
            vif.penable <= 1'b0;
        end
        // APB read sequence
        else begin
            // Setup phase
            @(posedge vif.clk);
            vif.psel    <= 1'b1;
            vif.pwrite  <= 1'b0;
            vif.paddr   <= item.addr;
            vif.penable <= 1'b0;

            // Access phase
            @(posedge vif.clk);
            vif.penable <= 1'b1;

            // Wait for ready
            @(posedge vif.clk);
            while (!vif.pready) @(posedge vif.clk);
            item.rdata = vif.prdata;

            // Idle phase
            vif.psel    <= 1'b0;
            vif.penable <= 1'b0;
        end
    endtask

endclass : isp_csiir_reg_driver