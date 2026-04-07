`timescale 1ns/1ps
module tb_div_approaches;
    parameter ACC_WIDTH = 20;
    
    reg signed [ACC_WIDTH-1:0] sum = -12680;
    reg [7:0] w_u8 = 25;
    
    // Different approaches
    wire signed [ACC_WIDTH-1:0] d1 = sum / $signed(w_u8);  // Cast in division
    wire signed [ACC_WIDTH-1:0] d2 = sum / $signed({1'b0, w_u8});  // Cast with zero extend
    wire signed [ACC_WIDTH-1:0] d3 = sum / $unsigned(w_u8);  // Force unsigned
    
    // Try with explicit signed intermediate
    wire signed [7:0] w_s8 = w_u8;
    wire signed [ACC_WIDTH-1:0] d4 = sum / w_s8;
    
    // Try with integer
    wire integer d5 = sum / w_u8;
    
    initial begin
        #1;
        $display("sum = %0d", $signed(sum));
        $display("w_u8 = %0d", w_u8);
        $display("d1 (/$signed(w_u8)) = %0d", $signed(d1));
        $display("d2 (/$signed({1'b0,w})) = %0d", $signed(d2));
        $display("d3 (/$unsigned(w)) = %0d", $signed(d3));
        $display("d4 (/w_s8) = %0d", $signed(d4));
        $display("d5 (integer) = %0d", d5);
        $display("Expected = %0d", -507);
        #10;
        $finish;
    end
endmodule
