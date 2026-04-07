`timescale 1ns/1ps
module tb_debug_sat3;
    parameter ACC_WIDTH = 20;
    parameter SIGNED_WIDTH = 11;
    
    reg signed [ACC_WIDTH-1:0] div_full = -507;
    
    // Saturation flags
    wire ovf_pos = (div_full > 20'sd511);
    wire ovf_neg = (div_full < -20'sd512);
    
    // Truncate
    wire signed [SIGNED_WIDTH-1:0] trunc = div_full[SIGNED_WIDTH-1:0];
    
    // Result
    wire signed [SIGNED_WIDTH-1:0] result = ovf_pos ? 11'sd511 : ovf_neg ? -11'sd512 : trunc;
    
    initial begin
        $display("div_full = %0d", $signed(div_full));
        $display("20'sd511 = %0d", $signed(20'sd511));
        $display("-20'sd512 = %0d", $signed(-20'sd512));
        $display("ovf_pos = %b (div_full > 511)", ovf_pos);
        $display("ovf_neg = %b (div_full < -512)", ovf_neg);
        $display("trunc = %0d", $signed(trunc));
        $display("result = %0d", $signed(result));
        #10;
        $finish;
    end
endmodule
