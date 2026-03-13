//-----------------------------------------------------------------------------
// Class: isp_csiir_coverage
// Description: Functional coverage collector for ISP-CSIIR
//-----------------------------------------------------------------------------

class isp_csiir_coverage extends uvm_subscriber #(isp_csiir_pixel_item);

    `uvm_component_utils(isp_csiir_coverage)

    // Coverage groups
    covergroup pixel_cg;
        // Input pixel value coverage
        cp_pixel_value: coverpoint req.pixel_data {
            bins zero      = {0};
            bins low       = {[1:63]};
            bins mid       = {[64:191]};
            bins high      = {[192:254]};
            bins max       = {255};
        }

        // Control signal coverage
        cp_valid: coverpoint req.valid {
            bins valid   = {1};
            bins invalid = {0};
        }

        cp_vsync: coverpoint req.vsync {
            bins vsync_active = {1};
            bins vsync_idle   = {0};
        }

        cp_hsync: coverpoint req.hsync {
            bins hsync_active = {1};
            bins hsync_idle   = {0};
        }

        // Cross coverage
        cross cp_pixel_value, cp_valid;
    endgroup

    covergroup output_cg;
        // Output pixel value coverage
        cp_result_value: coverpoint req.result_data {
            bins zero      = {0};
            bins low       = {[1:63]};
            bins mid       = {[64:191]};
            bins high      = {[192:254]};
            bins max       = {255};
        }

        cp_result_valid: coverpoint req.result_valid {
            bins valid   = {1};
            bins invalid = {0};
        }
    endgroup

    function new(string name = "isp_csiir_coverage", uvm_component parent = null);
        super.new(name, parent);
        pixel_cg  = new();
        output_cg = new();
    endfunction

    function void write(isp_csiir_pixel_item t);
        req = t;

        // Sample appropriate coverage group
        if (t.valid) begin
            pixel_cg.sample();
        end

        if (t.result_valid) begin
            output_cg.sample();
        end
    endfunction

    function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        `uvm_info("COVERAGE",
            $sformatf("\n--- Coverage Report ---\n" +
                     "Pixel Coverage:   %.2f%%\n" +
                     "Output Coverage:  %.2f%%",
                     pixel_cg.get_coverage(), output_cg.get_coverage()),
            UVM_LOW)
    endfunction

endclass : isp_csiir_coverage