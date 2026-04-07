`timescale 1ns/1ps
module tb_debug_div2;
    // Use integer (32-bit) for division - works reliably
    integer sum = -12680;
    integer weight = 25;
    integer div_result;
    
    // Then convert to 11-bit
    wire signed [10:0] result;
    assign div_result = sum / weight;
    assign result = (div_result > 511) ? 11'sd511 :
                    (div_result < -512) ? -11'sd512 :
                    div_result[10:0];
    
    initial begin
        $display("sum = %0d, weight = %0d", sum, weight);
        $display("div_result = %0d", div_result);
        $display("result = %0d", $signed(result));
        #10;
        $finish;
    end
endmodule
