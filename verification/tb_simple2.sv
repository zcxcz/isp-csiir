`timescale 1ns/1ps
module tb_simple2;
    integer div_result = -507;
    integer sat_result;
    
    localparam MAX_VAL = 511;
    localparam MIN_VAL = -512;
    
    always @(*) begin
        if (div_result > MAX_VAL)
            sat_result = MAX_VAL;
        else if (div_result < MIN_VAL)
            sat_result = MIN_VAL;
        else
            sat_result = div_result;
    end
    
    initial begin
        #1;
        $display("div_result = %0d", div_result);
        $display("MAX_VAL = %0d, MIN_VAL = %0d", MAX_VAL, MIN_VAL);
        $display("div_result > MAX_VAL = %b", div_result > MAX_VAL);
        $display("div_result < MIN_VAL = %b", div_result < MIN_VAL);
        $display("sat_result = %0d", sat_result);
        #10;
        $finish;
    end
endmodule
