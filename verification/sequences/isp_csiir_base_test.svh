//-----------------------------------------------------------------------------
// Class: isp_csiir_base_test
// Description: Base test class for ISP-CSIIR verification
//-----------------------------------------------------------------------------

class isp_csiir_base_test extends uvm_test;

    `uvm_component_utils(isp_csiir_base_test)

    isp_csiir_env env;
    isp_csiir_config cfg;

    function new(string name = "isp_csiir_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // Create configuration
        cfg = isp_csiir_config::type_id::create("cfg");
        cfg.img_width  = 320;
        cfg.img_height = 240;
        cfg.enable     = 1;
        cfg.bypass     = 0;

        // Set configuration
        uvm_config_db #(isp_csiir_config)::set(this, "*", "config", cfg);

        // Create environment
        env = isp_csiir_env::type_id::create("env", this);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
        super.end_of_elaboration_phase(phase);
        `uvm_info("TEST", "Testbench topology:", UVM_LOW)
        print();
    endfunction

    function void report_phase(uvm_phase phase);
        uvm_report_server server;
        int err_count;

        super.report_phase(phase);

        server = uvm_report_server::get_server();
        err_count = server.get_severity_count(UVM_ERROR) +
                    server.get_severity_count(UVM_FATAL);

        if (err_count == 0) begin
            `uvm_info("TEST", "TEST PASSED", UVM_LOW)
        end else begin
            `uvm_error("TEST", "TEST FAILED")
        end
    endfunction

endclass : isp_csiir_base_test