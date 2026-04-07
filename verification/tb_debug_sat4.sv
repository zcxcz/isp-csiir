`timescale 1ns/1ps
module tb_debug_sat4;
    parameter ACC_WIDTH = 20;
    parameter SIGNED_WIDTH = 11;
    
    reg signed [ACC_WIDTH-1:0] div_full = -507;
    
    // Saturation flags
    wire ovf_pos = (div_full > 20'sd511);
    wire ovf_neg = (div_full < -20'sd512);
    
    // Truncate
    wire signed [SIGNED_WIDTH-1:0] trunc = div_full[SIGNED_WIDTH-1:0];
    
    // Result using separate wires
    wire signed [SIGNED_WIDTH-1:0] sat_pos = 11'sd511;
    wire signed [SIGNED_WIDTH-1:0] sat_neg = -11'sd512;
    wire signed [SIGNED_WIDTH-1:0] result_no_of = trunc;
    
    // Final result - try using separate ternary
    wire signed [SIGNED_WIDTH-1:0] intermediate = ovf_neg ? sat_neg : result_no_of;
    wire signed [SIGNED_WIDTH-1:0] result = ovf_pos ? sat_pos : intermediate;
    
    initial begin
        $display("div_full = %0d", $signed(div_full));
        $display("ovf_pos = %b, ovf_neg = %b", ovf_pos, ovf_neg);
        $display("trunc = %0d", $signed(trunc));
        $display("sat_pos = %0d, sat_neg = %0d", $signed(sat_pos), $signed(sat_neg));
        $display("intermediate = %0d", $signed(intermediate));
        $display("result = %0d", $signed(result));
        #10;
        $finish;
    end
endmodule
