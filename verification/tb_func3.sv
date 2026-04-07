`timescale 1ns/1ps
module tb_func3;
    parameter ACC_WIDTH = 20;
    parameter SIGNED_WIDTH = 11;
    
    wire signed [ACC_WIDTH-1:0] div_result = -507;
    
    function automatic signed [SIGNED_WIDTH-1:0] saturate_s11;
        input signed [ACC_WIDTH-1:0] value;
        begin
            if (value > 511)
                saturate_s11 = 11'sd511;
            else if (value < -512)
                saturate_s11 = -11'sd512;
            else
                saturate_s11 = value[SIGNED_WIDTH-1:0];
        end
    endfunction
    
    wire signed [SIGNED_WIDTH-1:0] result = saturate_s11(div_result);
    
    initial begin
        #1;
        $display("div_result = %0d", $signed(div_result));
        $display("result = %0d", $signed(result));
        #10;
        $finish;
    end
endmodule
