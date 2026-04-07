`timescale 1ns/1ps
module tb_debug_stage2f;
    reg signed [19:0] sum = -12680;
    reg [7:0] weight = 25;
    
    // Use procedural assignment for division
    reg signed [10:0] result;
    reg signed [19:0] div_temp;
    
    always @(*) begin
        div_temp = sum / $signed({1'b0, weight});
        // Manual truncation with sign extension
        if (div_temp > 511)
            result = 11'sd511;
        else if (div_temp < -512)
            result = -11'sd512;
        else
            result = div_temp[10:0];
    end
    
    initial begin
        $display("sum = %0d, weight = %0d", sum, weight);
        $display("div_temp = %0d", div_temp);
        $display("result = %0d", result);
        #10;
        $finish;
    end
endmodule
