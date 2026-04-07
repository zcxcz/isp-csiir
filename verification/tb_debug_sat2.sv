`timescale 1ns/1ps
module tb_debug_sat2;
    parameter ACC_WIDTH = 20;
    parameter SIGNED_WIDTH = 11;
    
    reg signed [ACC_WIDTH-1:0] div_full = -507;
    
    // Try different approaches to truncate
    wire signed [SIGNED_WIDTH-1:0] trunc1 = div_full[10:0];
    wire signed [SIGNED_WIDTH-1:0] trunc2 = $signed(div_full[10:0]);
    wire signed [SIGNED_WIDTH-1:0] trunc3;
    assign trunc3 = div_full[10:0];
    
    // Saturation test with assignment
    reg signed [SIGNED_WIDTH-1:0] result;
    always @(*) begin
        if (div_full > 20'sd511)
            result = 11'sd511;
        else if (div_full < -20'sd512)
            result = -11'sd512;
        else
            result = div_full[10:0];
    end
    
    initial begin
        $display("div_full = %0d (%b)", $signed(div_full), div_full);
        $display("div_full[10:0] = %b", div_full[10:0]);
        $display("trunc1 = %0d", $signed(trunc1));
        $display("trunc2 = %0d", $signed(trunc2));
        $display("trunc3 = %0d", $signed(trunc3));
        $display("result = %0d", $signed(result));
        #10;
        $finish;
    end
endmodule
