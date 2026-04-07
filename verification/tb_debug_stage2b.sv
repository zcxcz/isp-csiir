`timescale 1ns/1ps
module tb_debug_stage2b;
    reg clk = 0;
    always #(1.67/2) clk = ~clk;
    
    // Use correct widths from Stage 2
    wire signed [19:0] sum = -12680;  // ACC_WIDTH = 20
    wire [7:0] weight = 25;
    
    // The division from Stage 2
    wire signed [10:0] div_result = (weight != 0) ? (sum / $signed({1'b0, weight})) : 11'sd0;
    
    initial begin
        $display("sum = %0d, weight = %0d", $signed(sum), weight);
        $display("div_result = %0d", $signed(div_result));
        $display("Expected: %0d", -12680 / 25);
        #10;
        $finish;
    end
endmodule
