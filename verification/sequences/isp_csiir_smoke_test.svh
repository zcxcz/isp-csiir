//-----------------------------------------------------------------------------
// Class: isp_csiir_smoke_test
// Description: Quick smoke test for basic functionality
//-----------------------------------------------------------------------------

class isp_csiir_smoke_test extends isp_csiir_base_test;

    `uvm_component_utils(isp_csiir_smoke_test)

    function new(string name = "isp_csiir_smoke_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        isp_csiir_pixel_sequence pixel_seq;
        isp_csiir_reg_sequence reg_seq;

        phase.raise_objection(this);

        // Configure registers
        reg_seq = isp_csiir_reg_sequence::type_id::create("reg_seq");
        reg_seq.pic_width_m1  = 16'd63;   // 64x64 image
        reg_seq.pic_height_m1 = 16'd63;
        reg_seq.start(env.reg_agent.sequencer);

        // Wait for configuration to settle
        #100ns;

        // Send pixel data
        pixel_seq = isp_csiir_pixel_sequence::type_id::create("pixel_seq");
        pixel_seq.frame_width  = 64;
        pixel_seq.frame_height = 64;
        pixel_seq.num_frames   = 1;
        pixel_seq.start(env.pixel_agent.sequencer);

        // Wait for processing to complete
        #1us;

        phase.drop_objection(this);
    endtask

endclass : isp_csiir_smoke_test