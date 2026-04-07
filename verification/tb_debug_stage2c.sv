`timescale 1ns/1ps
module tb_debug_stage2c;
    reg clk = 0;
    always #(1.67/2) clk = ~clk;
    
    // Use correct widths from Stage 2
    wire signed [19:0] sum = -12680;  // ACC_WIDTH = 20
    wire [7:0] weight = 25;
    
    // Test the exact expression from Stage 2
    wire signed [10:0] div_result = sum / $signed({1'b0, weight});
    
    // Also test intermediate steps
    wire signed [8:0] weight_signed = $signed({1'b0, weight});
    wire signed [19:0] div_full = sum / weight_signed;
    
    initial begin
        $display("sum = %0d, weight = %0d", $signed(sum), weight);
        $display("weight_signed = %0d", $signed(weight_signed));
        $display("div_full (20-bit) = %0d", $signed(div_full));
        $display("div_result (11-bit) = %0d", $signed(div_result));
        $display("Expected: %0d", -12680 / 25);
        #10;
        $finish;
    end
endmodule
