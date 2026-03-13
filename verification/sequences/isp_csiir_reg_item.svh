//-----------------------------------------------------------------------------
// Class: isp_csiir_reg_item
// Description: Sequence item for register transactions
//-----------------------------------------------------------------------------

class isp_csiir_reg_item extends uvm_sequence_item;

    `uvm_object_utils(isp_csiir_reg_item)

    // Transaction fields
    rand bit [7:0]  addr;
    rand bit [31:0] data;
    rand bit        write;  // 1=write, 0=read
    rand bit        psel;
    rand bit        penable;

    // Response
    bit [31:0]      rdata;
    bit             pready;
    bit             pslverr;

    function new(string name = "isp_csiir_reg_item");
        super.new(name);
    endfunction

    function string convert2string();
        string s;
        s = $sformatf("addr=0x%02h, data=0x%08h, write=%0b, rdata=0x%08h",
                      addr, data, write, rdata);
        return s;
    endfunction

endclass : isp_csiir_reg_item