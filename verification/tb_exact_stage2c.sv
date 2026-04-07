`timescale 1ns/1ps
module tb_exact_stage2c;
    reg signed [19:0] sum_c_s6 = -12680;
    reg [7:0] w_c_s6 = 25;
    
    // Test different approaches
    wire signed [19:0] d1 = sum_c_s6 / $signed(w_c_s6);
    wire signed [19:0] d2 = sum_c_s6 / w_c_s6;  // No cast
    
    initial begin
        #1;
        $display("sum_c_s6 = %0d", $signed(sum_c_s6));
        $display("w_c_s6 = %0d", w_c_s6);
        $display("d1 = %0d", $signed(d1));
        $display("d2 = %0d", $signed(d2));
        #10;
        $finish;
    end
endmodule
