//-----------------------------------------------------------------------------
// Class: isp_csiir_env
// Description: UVM environment for ISP-CSIIR verification
//-----------------------------------------------------------------------------

class isp_csiir_env extends uvm_env;

    `uvm_component_utils(isp_csiir_env)

    // Components
    isp_csiir_config       config_obj;
    isp_csiir_pixel_agent  pixel_agent;
    isp_csiir_reg_agent    reg_agent;
    isp_csiir_ref_model    ref_model;
    isp_csiir_scoreboard   scoreboard;
    isp_csiir_coverage     coverage;

    function new(string name = "isp_csiir_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // Get or create configuration
        if (!uvm_config_db #(isp_csiir_config)::get(this, "", "config", config_obj)) begin
            config_obj = isp_csiir_config::type_id::create("config_obj");
            `uvm_info("ENV", "Created default configuration", UVM_LOW)
        end

        uvm_config_db #(isp_csiir_config)::set(this, "*", "config", config_obj);

        // Create agents
        pixel_agent = isp_csiir_pixel_agent::type_id::create("pixel_agent", this);
        reg_agent   = isp_csiir_reg_agent::type_id::create("reg_agent", this);

        // Create reference model
        ref_model = isp_csiir_ref_model::type_id::create("ref_model", this);

        // Create scoreboard
        scoreboard = isp_csiir_scoreboard::type_id::create("scoreboard", this);

        // Create coverage collector
        coverage = isp_csiir_coverage::type_id::create("coverage", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        // Connect monitor to reference model
        pixel_agent.monitor.ap.connect(ref_model.input_ap);

        // Connect monitor and reference model to scoreboard
        pixel_agent.monitor.ap.connect(scoreboard.dut_ap);
        ref_model.output_ap.connect(scoreboard.ref_ap);

        // Connect monitor to coverage
        pixel_agent.monitor.ap.connect(coverage.analysis_export);
    endfunction

endclass : isp_csiir_env