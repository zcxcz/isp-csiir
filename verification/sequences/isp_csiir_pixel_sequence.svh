//-----------------------------------------------------------------------------
// Class: isp_csiir_pixel_sequence
// Description: Sequence for pixel data transactions
//-----------------------------------------------------------------------------

class isp_csiir_pixel_sequence extends uvm_sequence #(isp_csiir_pixel_item);

    `uvm_object_utils(isp_csiir_pixel_sequence)

    // Sequence parameters
    rand int num_frames;
    rand int frame_width;
    rand int frame_height;

    constraint frame_size_c {
        frame_width  inside {[64:1920]};
        frame_height inside {[64:1080]};
    }

    constraint num_frames_c {
        num_frames inside {[1:10]};
    }

    function new(string name = "isp_csiir_pixel_sequence");
        super.new(name);
        num_frames = 1;
        frame_width = 320;
        frame_height = 240;
    endfunction

    task body();
        isp_csiir_pixel_item item;
        int pixel_count;

        for (int frame = 0; frame < num_frames; frame++) begin
            `uvm_info("SEQ", $sformatf("Starting frame %0d", frame), UVM_LOW)

            // Send VSYNC
            `uvm_do_with(item, {
                item.vsync == 1;
                item.valid == 0;
            })

            // Send frame data
            for (int y = 0; y < frame_height; y++) begin
                for (int x = 0; x < frame_width; x++) begin
                    `uvm_do_with(item, {
                        item.pixel_data inside {[0:255]};
                        item.valid == 1;
                        item.vsync == 0;
                        item.hsync == (x == frame_width - 1);
                    })
                end
            end

            // End of frame
            `uvm_do_with(item, {
                item.vsync == 1;
                item.valid == 0;
            })
        end
    endtask

endclass : isp_csiir_pixel_sequence