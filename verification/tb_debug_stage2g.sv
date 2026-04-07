`timescale 1ns/1ps
module tb_debug_stage2g;
    // Use integer type which has automatic width
    integer sum = -12680;
    integer weight = 25;
    integer result;
    
    assign result = sum / weight;
    
    initial begin
        $display("sum = %0d, weight = %0d", sum, weight);
        $display("result = %0d", result);
        #10;
        $finish;
    end
endmodule
