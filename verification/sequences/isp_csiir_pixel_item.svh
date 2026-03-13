//-----------------------------------------------------------------------------
// Class: isp_csiir_pixel_item
// Description: Sequence item for pixel data transactions
//-----------------------------------------------------------------------------

class isp_csiir_pixel_item extends uvm_sequence_item;

    `uvm_object_utils(isp_csiir_pixel_item)

    // Transaction fields
    rand bit [7:0] pixel_data;
    rand bit       valid;
    rand bit       vsync;
    rand bit       hsync;
    rand bit       sof;
    rand bit       eol;

    // Response fields
    bit [7:0]      result_data;
    bit            result_valid;

    function new(string name = "isp_csiir_pixel_item");
        super.new(name);
    endfunction

    function void do_copy(uvm_object rhs);
        isp_csiir_pixel_item rhs_item;

        if (!$cast(rhs_item, rhs)) begin
            `uvm_error("COPY", "Failed to cast rhs to isp_csiir_pixel_item")
            return;
        end

        super.do_copy(rhs);
        pixel_data = rhs_item.pixel_data;
        valid      = rhs_item.valid;
        vsync      = rhs_item.vsync;
        hsync      = rhs_item.hsync;
        sof        = rhs_item.sof;
        eol        = rhs_item.eol;
        result_data = rhs_item.result_data;
        result_valid = rhs_item.result_valid;
    endfunction

    function string convert2string();
        string s;
        s = $sformatf("pixel_data=%0d, valid=%0b, vsync=%0b, hsync=%0b, sof=%0b, eol=%0b",
                      pixel_data, valid, vsync, hsync, sof, eol);
        return s;
    endfunction

    function void do_print(uvm_printer printer);
        printer.print_field("pixel_data", pixel_data, 8);
        printer.print_field("valid", valid, 1);
        printer.print_field("vsync", vsync, 1);
        printer.print_field("hsync", hsync, 1);
        printer.print_field("sof", sof, 1);
        printer.print_field("eol", eol, 1);
    endfunction

endclass : isp_csiir_pixel_item