`timescale 1ns/1ps
module tb_debug_final;
    integer sum = -12680;
    integer weight = 25;
    integer div_result;
    integer sat_result;
    
    // Procedural saturation
    always @(*) begin
        div_result = sum / weight;
        if (div_result > 511)
            sat_result = 511;
        else if (div_result < -512)
            sat_result = -512;
        else
            sat_result = div_result;
    end
    
    // Convert to 11-bit
    wire signed [10:0] result = sat_result[10:0];
    
    initial begin
        $display("sum = %0d, weight = %0d", sum, weight);
        $display("div_result = %0d", div_result);
        $display("sat_result = %0d", sat_result);
        $display("result = %0d", $signed(result));
        #10;
        $finish;
    end
endmodule
