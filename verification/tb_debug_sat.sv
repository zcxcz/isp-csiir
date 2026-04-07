`timescale 1ns/1ps
module tb_debug_sat;
    parameter ACC_WIDTH = 20;
    parameter SIGNED_WIDTH = 11;
    
    reg signed [ACC_WIDTH-1:0] div_full = -507;
    
    // Saturation test
    wire signed [SIGNED_WIDTH-1:0] result;
    assign result = (div_full > 20'sd511) ? 11'sd511 :
                    (div_full < -20'sd512) ? -11'sd512 :
                    div_full[SIGNED_WIDTH-1:0];
    
    initial begin
        $display("div_full = %0d", $signed(div_full));
        $display("20'sd511 = %0d", $signed(20'sd511));
        $display("-20'sd512 = %0d", $signed(-20'sd512));
        $display("div_full > 511: %b", div_full > 20'sd511);
        $display("div_full < -512: %b", div_full < -20'sd512);
        $display("result = %0d", $signed(result));
        #10;
        $finish;
    end
endmodule
