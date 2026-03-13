//-----------------------------------------------------------------------------
// Class: isp_csiir_video_test
// Description: Test with video-like stream (multiple frames)
//-----------------------------------------------------------------------------

class isp_csiir_video_test extends isp_csiir_base_test;

    `uvm_component_utils(isp_csiir_video_test)

    function new(string name = "isp_csiir_video_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        isp_csiir_pixel_sequence pixel_seq;
        isp_csiir_reg_sequence reg_seq;

        phase.raise_objection(this);

        // Configure for 320x240 video
        reg_seq = isp_csiir_reg_sequence::type_id::create("reg_seq");
        reg_seq.pic_width_m1  = 16'd319;
        reg_seq.pic_height_m1 = 16'd239;
        reg_seq.start(env.reg_agent.sequencer);

        #100ns;

        // Send multiple frames
        pixel_seq = isp_csiir_pixel_sequence::type_id::create("pixel_seq");
        pixel_seq.frame_width  = 320;
        pixel_seq.frame_height = 240;
        pixel_seq.num_frames   = 5;
        pixel_seq.start(env.pixel_agent.sequencer);

        // Wait for all frames to complete
        #10us;

        phase.drop_objection(this);
    endtask

endclass : isp_csiir_video_test