//-----------------------------------------------------------------------------
// Class: isp_csiir_reg_sequence
// Description: Sequence for register configuration transactions
//-----------------------------------------------------------------------------

class isp_csiir_reg_sequence extends uvm_sequence #(isp_csiir_reg_item);

    `uvm_object_utils(isp_csiir_reg_sequence)

    // Configuration values
    rand bit [15:0] pic_width_m1;
    rand bit [15:0] pic_height_m1;
    rand bit [15:0] win_size_thresh0;
    rand bit [15:0] win_size_thresh1;
    rand bit [15:0] win_size_thresh2;
    rand bit [15:0] win_size_thresh3;

    function new(string name = "isp_csiir_reg_sequence");
        super.new(name);
        pic_width_m1    = 16'd319;   // 320 - 1
        pic_height_m1   = 16'd239;   // 240 - 1
        win_size_thresh0 = 16'd16;
        win_size_thresh1 = 16'd24;
        win_size_thresh2 = 16'd32;
        win_size_thresh3 = 16'd40;
    endfunction

    task body();
        isp_csiir_reg_item item;

        `uvm_info("REG_SEQ", "Configuring ISP-CSIIR registers", UVM_LOW)

        // Write enable register
        `uvm_do_with(item, {
            item.addr == 8'h00;
            item.data == 32'h00000001;  // enable = 1, bypass = 0
            item.write == 1;
        })

        // Write picture size
        `uvm_do_with(item, {
            item.addr == 8'h04;
            item.data == {pic_height_m1, pic_width_m1};
            item.write == 1;
        })

        // Write thresholds
        `uvm_do_with(item, {
            item.addr == 8'h08;
            item.data == {16'h0, win_size_thresh0};
            item.write == 1;
        })

        `uvm_do_with(item, {
            item.addr == 8'h0C;
            item.data == {16'h0, win_size_thresh1};
            item.write == 1;
        })

        `uvm_do_with(item, {
            item.addr == 8'h10;
            item.data == {16'h0, win_size_thresh2};
            item.write == 1;
        })

        `uvm_do_with(item, {
            item.addr == 8'h14;
            item.data == {16'h0, win_size_thresh3};
            item.write == 1;
        })

        // Write blending ratios
        `uvm_do_with(item, {
            item.addr == 8'h18;
            item.data == {8'h0, 8'd32, 8'd32, 8'd32, 8'd32};
            item.write == 1;
        })

        `uvm_info("REG_SEQ", "Register configuration complete", UVM_LOW)
    endtask

endclass : isp_csiir_reg_sequence