`timescale 1ns/1ps
module tb_func2;
    parameter ACC_WIDTH = 20;
    parameter SIGNED_WIDTH = 11;
    
    wire signed [ACC_WIDTH-1:0] div_result = -507;
    
    function automatic signed [10:0] saturate_s11;
        input signed [19:0] value;
        begin
            $display("Function called with value = %0d", $signed(value));
            if (value > 511)
                saturate_s11 = 11'sd511;
            else if (value < -512)
                saturate_s11 = -11'sd512;
            else
                saturate_s11 = value[10:0];
            $display("Returning saturate_s11 = %0d", $signed(saturate_s11));
        end
    endfunction
    
    wire signed [10:0] result = saturate_s11(div_result);
    
    initial begin
        #1;
        $display("div_result = %0d", $signed(div_result));
        $display("result = %0d", $signed(result));
        #10;
        $finish;
    end
endmodule
