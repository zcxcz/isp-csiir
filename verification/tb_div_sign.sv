`timescale 1ns/1ps
module tb_div_sign;
    parameter ACC_WIDTH = 20;
    
    reg signed [ACC_WIDTH-1:0] sum = -12680;
    reg [7:0] w_unsigned = 25;
    reg signed [7:0] w_signed = 25;
    
    // Different approaches
    wire signed [ACC_WIDTH-1:0] div1 = sum / w_unsigned;  // signed / unsigned
    wire signed [ACC_WIDTH-1:0] div2 = sum / w_signed;    // signed / signed
    wire signed [ACC_WIDTH-1:0] div3 = sum / $signed(w_unsigned);  // with cast
    
    initial begin
        #1;
        $display("sum = %0d", $signed(sum));
        $display("w_unsigned = %0d", w_unsigned);
        $display("w_signed = %0d", $signed(w_signed));
        $display("div1 (signed/unsigned) = %0d", $signed(div1));
        $display("div2 (signed/signed) = %0d", $signed(div2));
        $display("div3 (with cast) = %0d", $signed(div3));
        #10;
        $finish;
    end
endmodule
