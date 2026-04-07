`timescale 1ns/1ps
module tb_exact_stage2;
    parameter ACC_WIDTH = 20;
    parameter SIGNED_WIDTH = 11;
    
    reg signed [ACC_WIDTH-1:0] sum_c_s6 = -12680;
    reg [7:0] w_c_s6 = 25;
    
    // Exact Stage 2 pattern
    wire signed [7:0] w_c_s6_signed = w_c_s6;
    wire signed [ACC_WIDTH-1:0] avg0_c_div_full = (w_c_s6 != 0) ? (sum_c_s6 / w_c_s6_signed) : {ACC_WIDTH{1'b0}};
    
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
    
    wire signed [10:0] avg0_c_comb = saturate_s11(avg0_c_div_full);
    
    initial begin
        #1;
        $display("sum_c_s6 = %0d", $signed(sum_c_s6));
        $display("w_c_s6 = %0d", w_c_s6);
        $display("w_c_s6_signed = %0d", $signed(w_c_s6_signed));
        $display("avg0_c_div_full = %0d", $signed(avg0_c_div_full));
        $display("avg0_c_comb = %0d", $signed(avg0_c_comb));
        $display("Expected = %0d", -507);
        #10;
        $finish;
    end
endmodule
