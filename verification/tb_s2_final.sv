`timescale 1ns/1ps
module tb_s2_final;
    reg clk = 0;
    always #(1.67/2) clk = ~clk;
    
    reg signed [19:0] sum_c = -12680;
    reg [7:0] weight = 25;
    
    // Exact Stage 2 pattern
    wire signed [7:0] weight_signed = weight;
    wire signed [19:0] div_full = sum_c / weight_signed;
    
    function automatic signed [10:0] saturate_s11;
        input signed [19:0] value;
        begin
            if (value > 511)
                saturate_s11 = 11'sd511;
            else if (value < -512)
                saturate_s11 = -11'sd512;
            else
                saturate_s11 = value[10:0];
        end
    endfunction
    
    wire signed [10:0] avg0 = saturate_s11(div_full);
    
    initial begin
        #1;
        $display("sum_c = %0d, weight = %0d", sum_c, weight);
        $display("weight_signed = %0d", $signed(weight_signed));
        $display("div_full = %0d", $signed(div_full));
        $display("avg0 = %0d", $signed(avg0));
        $display("Expected avg0 = %0d", -507);
        
        if ($signed(avg0) == -507)
            $display("TEST PASSED");
        else
            $display("TEST FAILED");
        
        #10;
        $finish;
    end
endmodule
