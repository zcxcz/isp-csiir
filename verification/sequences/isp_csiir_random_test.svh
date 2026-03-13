//-----------------------------------------------------------------------------
// Class: isp_csiir_random_test
// Description: Randomized test with various image sizes and configurations
//-----------------------------------------------------------------------------

class isp_csiir_random_test extends isp_csiir_base_test;

    `uvm_component_utils(isp_csiir_random_test)

    function new(string name = "isp_csiir_random_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        isp_csiir_pixel_sequence pixel_seq;
        isp_csiir_reg_sequence reg_seq;
        int test_frames [5] = '{10, 32, 64, 128, 256};
        int test_widths [5] = '{16, 64, 128, 320, 640};
        int test_heights[5] = '{16, 64, 128, 240, 480};

        phase.raise_objection(this);

        for (int test = 0; test < 5; test++) begin
            `uvm_info("TEST", $sformatf("Running test iteration %0d: %0dx%0d",
                      test, test_widths[test], test_heights[test]), UVM_LOW)

            // Configure registers
            reg_seq = isp_csiir_reg_sequence::type_id::create("reg_seq");
            reg_seq.pic_width_m1  = test_widths[test] - 1;
            reg_seq.pic_height_m1 = test_heights[test] - 1;
            reg_seq.start(env.reg_agent.sequencer);

            #100ns;

            // Send pixel data
            pixel_seq = isp_csiir_pixel_sequence::type_id::create("pixel_seq");
            pixel_seq.frame_width  = test_widths[test];
            pixel_seq.frame_height = test_heights[test];
            pixel_seq.num_frames   = 1;
            pixel_seq.start(env.pixel_agent.sequencer);

            // Wait between tests
            #1us;
        end

        phase.drop_objection(this);
    endtask

endclass : isp_csiir_random_test