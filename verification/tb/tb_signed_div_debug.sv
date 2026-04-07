`timescale 1ns/1ps

module tb_signed_div_debug;
    reg clk = 0;

    // Test values from actual Stage 2 output
    wire signed [19:0] sum_c = -20'sd12680;
    wire [7:0] w_c = 8'd25;

    // Test different division approaches
    wire signed [19:0] d1 = sum_c / $signed(w_c);  // With $signed cast
    wire signed [19:0] d2 = sum_c / w_c;           // Without cast
    wire signed [19:0] d3 = sum_c / 25;            // With literal

    // Saturation test
    wire signed [10:0] s1 = (d1 > 511) ? 11'sd511 : (d1 < -512) ? -11'sd512 : d1[10:0];
    wire signed [10:0] s2 = (d2 > 511) ? 11'sd511 : (d2 < -512) ? -11'sd512 : d2[10:0];
    wire signed [10:0] s3 = (d3 > 511) ? 11'sd511 : (d3 < -512) ? -11'sd512 : d3[10:0];

    always #5 clk = ~clk;

    initial begin
        #10;
        $display("Testing signed division with sum_c=%0d, w_c=%0d", $signed(sum_c), w_c);
        $display("d1 (/$signed):  %0d -> saturated: %0d", $signed(d1), $signed(s1));
        $display("d2 (/unsigned): %0d -> saturated: %0d", $signed(d2), $signed(s2));
        $display("d3 (/literal):  %0d -> saturated: %0d", $signed(d3), $signed(s3));

        // Expected: -12680 / 25 = -507.2 -> -507
        if ($signed(d1) != -507) begin
            $display("ERROR: d1 should be -507, got %0d", $signed(d1));
        end else begin
            $display("PASS: d1 = -507");
        end

        $finish;
    end

endmodule