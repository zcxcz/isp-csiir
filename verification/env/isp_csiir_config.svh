//-----------------------------------------------------------------------------
// Class: isp_csiir_config
// Description: Configuration object for ISP-CSIIR testbench
//-----------------------------------------------------------------------------

class isp_csiir_config extends uvm_object;

    `uvm_object_utils(isp_csiir_config)

    // Interface handles (would be set in testbench top)
    virtual isp_csiir_pixel_if pixel_vif;
    virtual isp_csiir_reg_if   reg_vif;

    // Configuration parameters
    rand int img_width;
    rand int img_height;
    rand bit enable;
    rand bit bypass;

    // Register defaults
    rand bit [15:0] win_size_thresh0;
    rand bit [15:0] win_size_thresh1;
    rand bit [15:0] win_size_thresh2;
    rand bit [15:0] win_size_thresh3;
    rand bit [7:0]  blending_ratio[4];
    rand bit [7:0]  win_size_clip_y[4];
    rand bit [7:0]  win_size_clip_sft[4];

    // Constraints
    constraint img_size_c {
        img_width  inside {[64:1920]};
        img_height inside {[64:1080]};
    }

    constraint thresh_c {
        win_size_thresh0 == 16;
        win_size_thresh1 == 24;
        win_size_thresh2 == 32;
        win_size_thresh3 == 40;
    }

    constraint blend_ratio_c {
        foreach (blending_ratio[i]) {
            blending_ratio[i] inside {[16:48]};
        }
    }

    constraint clip_y_c {
        win_size_clip_y[0] == 15;
        win_size_clip_y[1] == 23;
        win_size_clip_y[2] == 31;
        win_size_clip_y[3] == 39;
    }

    constraint clip_sft_c {
        foreach (win_size_clip_sft[i]) {
            win_size_clip_sft[i] == 2;
        }
    }

    function new(string name = "isp_csiir_config");
        super.new(name);
    endfunction

endclass : isp_csiir_config