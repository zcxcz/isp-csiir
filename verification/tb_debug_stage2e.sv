`timescale 1ns/1ps
module tb_debug_stage2e;
    wire signed [19:0] sum = -12680;
    wire [7:0] weight = 25;
    
    // Correct approach: Use the same pattern as Stage 2
    wire signed [10:0] div_result;
    assign div_result = sum / $signed({1'b0, weight});
    
    // What Stage 2 actually does
    wire signed [10:0] avg0_c_div = (weight != 0) ? (sum / $signed({1'b0, weight})) : 11'sd0;
    
    // Alternative: use a wider intermediate then truncate
    wire signed [19:0] div_temp = sum / $signed({1'b0, weight});
    wire signed [10:0] div_trunc;
    
    // Saturation logic like Stage 2
    wire signed [10:0] avg0_c_comb = (avg0_c_div > $signed(11'sd511)) ? $signed(11'sd511) :
                                     (avg0_c_div < $signed(-11'sd512)) ? $signed(-11'sd512) : avg0_c_div;
    
    initial begin
        $display("sum = %0d, weight = %0d", $signed(sum), weight);
        $display("div_result (direct) = %0d", $signed(div_result));
        $display("avg0_c_div = %0d", $signed(avg0_c_div));
        $display("avg0_c_comb (saturated) = %0d", $signed(avg0_c_comb));
        #10;
        $finish;
    end
endmodule
