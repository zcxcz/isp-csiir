`timescale 1ns/1ps
module tb_debug_div;
    parameter ACC_WIDTH = 20;
    parameter SIGNED_WIDTH = 11;
    
    reg signed [ACC_WIDTH-1:0] sum_c = -12680;
    reg signed [7:0] w_c = 25;  // Make weight signed
    
    // Division with signed weight
    wire signed [ACC_WIDTH-1:0] div_full;
    assign div_full = sum_c / w_c;
    
    initial begin
        $display("sum_c = %0d, w_c = %0d", $signed(sum_c), $signed(w_c));
        $display("div_full = %0d", $signed(div_full));
        #10;
        $finish;
    end
endmodule
