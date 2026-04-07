`timescale 1ns/1ps
module tb_debug_sat5;
    parameter ACC_WIDTH = 20;
    parameter SIGNED_WIDTH = 11;
    
    reg signed [ACC_WIDTH-1:0] div_full = -507;
    
    // Saturation flags
    wire ovf_pos = (div_full > 20'sd511);
    wire ovf_neg = (div_full < -20'sd512);
    
    // Truncate
    wire signed [SIGNED_WIDTH-1:0] trunc = div_full[SIGNED_WIDTH-1:0];
    
    // Try with all operands explicitly 11-bit signed
    wire signed [SIGNED_WIDTH-1:0] sat_pos = $signed(11'sd511);
    wire signed [SIGNED_WIDTH-1:0] sat_neg = $signed(-11'sd512);
    
    // Try using $signed() on the whole expression
    wire signed [SIGNED_WIDTH-1:0] result = $signed(ovf_pos ? sat_pos : (ovf_neg ? sat_neg : trunc));
    
    initial begin
        $display("div_full = %0d", $signed(div_full));
        $display("ovf_pos = %b, ovf_neg = %b", ovf_pos, ovf_neg);
        $display("trunc = %0d", $signed(trunc));
        $display("result = %0d", $signed(result));
        #10;
        $finish;
    end
endmodule
