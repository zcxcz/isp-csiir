`timescale 1ns/1ps
module tb_simplest;
    reg signed [31:0] div_result = -507;
    reg signed [31:0] sat_result;
    
    always @(*) begin
        sat_result = div_result;  // Simple assignment
    end
    
    initial begin
        #1;
        $display("div_result = %0d", div_result);
        $display("sat_result = %0d", sat_result);
        #10;
        $finish;
    end
endmodule
