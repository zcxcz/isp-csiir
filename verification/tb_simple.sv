`timescale 1ns/1ps
module tb_simple;
    integer div_result = -507;
    integer sat_result;
    
    always @(*) begin
        if (div_result > 511)
            sat_result = 511;
        else if (div_result < -512)
            sat_result = -512;
        else
            sat_result = div_result;
    end
    
    initial begin
        #1;
        $display("div_result = %0d", div_result);
        $display("sat_result = %0d", sat_result);
        #10;
        $finish;
    end
endmodule
