`timescale 1ns/1ps
module tb_debug_stage2d;
    reg clk = 0;
    always #(1.67/2) clk = ~clk;
    
    // Test division with proper casting
    wire signed [19:0] sum = -12680;
    wire [7:0] weight = 25;
    
    // Calculate division and explicitly cast to 11-bit
    wire signed [19:0] div_full = sum / $signed({1'b0, weight});
    wire signed [10:0] div_11bit = div_full[10:0];  // Truncate to 11 bits
    
    // Try $signed() cast
    wire signed [10:0] div_cast = $signed(div_full);
    
    // Try direct assignment with saturation check
    wire signed [10:0] div_saturate;
    assign div_saturate = (div_full > 511) ? 11'sd511 :
                          (div_full < -512) ? -11'sd512 :
                          div_full[10:0];
    
    initial begin
        $display("sum = %0d", $signed(sum));
        $display("div_full = %0d", $signed(div_full));
        $display("div_full binary = %b", div_full);
        $display("div_11bit = %0d (binary: %b)", $signed(div_11bit), div_11bit);
        $display("div_cast = %0d", $signed(div_cast));
        $display("div_saturate = %0d", $signed(div_saturate));
        $display("Expected: %0d", -507);
        #10;
        $finish;
    end
endmodule
