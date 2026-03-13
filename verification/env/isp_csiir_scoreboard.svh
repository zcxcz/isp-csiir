//-----------------------------------------------------------------------------
// Class: isp_csiir_scoreboard
// Description: Scoreboard for comparing DUT output with reference model
//-----------------------------------------------------------------------------

class isp_csiir_scoreboard extends uvm_scoreboard;

    `uvm_component_utils(isp_csiir_scoreboard)

    // Analysis ports
    uvm_analysis_imp #(isp_csiir_pixel_item, isp_csiir_scoreboard) dut_ap;
    uvm_analysis_imp #(isp_csiir_pixel_item, isp_csiir_scoreboard) ref_ap;

    // Queues for comparison
    isp_csiir_pixel_item dut_queue[$];
    isp_csiir_pixel_item ref_queue[$];

    // Statistics
    int match_count;
    int mismatch_count;
    int total_count;

    // Tolerance for comparison
    int tolerance = 2;  // Allow small differences due to rounding

    function new(string name = "isp_csiir_scoreboard", uvm_component parent = null);
        super.new(name, parent);
        dut_ap = new("dut_ap", this);
        ref_ap = new("ref_ap", this);
        match_count = 0;
        mismatch_count = 0;
        total_count = 0;
    endfunction

    // Write from DUT
    function void write_dut(isp_csiir_pixel_item item);
        dut_queue.push_back(item);
        compare();
    endfunction

    // Write from reference model
    function void write_ref(isp_csiir_pixel_item item);
        ref_queue.push_back(item);
        compare();
    endfunction

    // Compare items
    function void compare();
        isp_csiir_pixel_item dut_item, ref_item;
        int diff;

        while (dut_queue.size() > 0 && ref_queue.size() > 0) begin
            dut_item = dut_queue.pop_front();
            ref_item = ref_queue.pop_front();

            total_count++;

            diff = dut_item.result_data - ref_item.result_data;
            if (diff < 0) diff = -diff;

            if (diff <= tolerance) begin
                match_count++;
                `uvm_info("SCOREBOARD",
                    $sformatf("MATCH: DUT=%0d, REF=%0d, diff=%0d",
                    dut_item.result_data, ref_item.result_data, diff),
                    UVM_DEBUG)
            end else begin
                mismatch_count++;
                `uvm_error("SCOREBOARD",
                    $sformatf("MISMATCH: DUT=%0d, REF=%0d, diff=%0d",
                    dut_item.result_data, ref_item.result_data, diff))
            end
        end
    endfunction

    function void report_phase(uvm_phase phase);
        real match_rate;
        super.report_phase(phase);

        if (total_count > 0) begin
            match_rate = (real'(match_count) / real'(total_count)) * 100.0;
        end else begin
            match_rate = 0.0;
        end

        `uvm_info("SCOREBOARD",
            $sformatf("\n--- Scoreboard Report ---\n" +
                     "Total comparisons: %0d\n" +
                     "Matches:           %0d\n" +
                     "Mismatches:        %0d\n" +
                     "Match rate:        %.2f%%\n" +
                     "Tolerance:         %0d",
                     total_count, match_count, mismatch_count, match_rate, tolerance),
            UVM_LOW)
    endfunction

endclass : isp_csiir_scoreboard