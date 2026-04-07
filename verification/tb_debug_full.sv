`timescale 1ns/1ps
module tb_debug_full;
    // Simulate Stage 2's actual signal flow
    parameter ACC_WIDTH = 20;
    parameter SIGNED_WIDTH = 11;
    
    reg signed [ACC_WIDTH-1:0] sum_c = -12680;
    reg [7:0] w_c = 25;
    
    // Division - using wider intermediate
    wire signed [ACC_WIDTH-1:0] div_full = sum_c / $signed({1'b0, w_c});
    
    // Saturation to 11-bit
    wire signed [SIGNED_WIDTH-1:0] avg0_result;
    assign avg0_result = (div_full > $signed(20'sd511)) ? $signed(11'sd511) :
                         (div_full < $signed(-20'sd512)) ? $signed(-11'sd512) : 
                         div_full[SIGNED_WIDTH-1:0];
    
    initial begin
        $display("sum_c = %0d, w_c = %0d", $signed(sum_c), w_c);
        $display("div_full = %0d", $signed(div_full));
        $display("avg0_result = %0d", $signed(avg0_result));
        $display("div_full[10:0] = %b", div_full[10:0]);
        #10;
        $finish;
    end
endmodule
