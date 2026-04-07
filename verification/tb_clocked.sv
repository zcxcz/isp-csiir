`timescale 1ns/1ps
module tb_clocked;
    reg clk = 0;
    always #5 clk = ~clk;
    
    reg signed [31:0] div_result = -507;
    reg signed [31:0] sat_result;
    
    always @(posedge clk) begin
        if (div_result > 511)
            sat_result <= 511;
        else if (div_result < -512)
            sat_result <= -512;
        else
            sat_result <= div_result;
    end
    
    initial begin
        @(posedge clk);
        @(posedge clk);
        $display("div_result = %0d", div_result);
        $display("sat_result = %0d", sat_result);
        #10;
        $finish;
    end
endmodule
