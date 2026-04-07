`timescale 1ns/1ps
module tb_func;
    wire signed [31:0] div_result = -507;
    
    function automatic signed [10:0] saturate;
        input signed [31:0] value;
        begin
            if (value > 511)
                saturate = 511;
            else if (value < -512)
                saturate = -512;
            else
                saturate = value[10:0];
        end
    endfunction
    
    wire signed [10:0] result = saturate(div_result);
    
    initial begin
        #1;
        $display("div_result = %0d", div_result);
        $display("result = %0d", $signed(result));
        #10;
        $finish;
    end
endmodule
