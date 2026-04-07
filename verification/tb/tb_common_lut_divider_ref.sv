`timescale 1ns/1ps

module tb_common_lut_divider_ref;

    localparam DIVIDEND_WIDTH = 17;
    localparam QUOTIENT_WIDTH = 11;
    localparam PRODUCT_SHIFT  = 26;
    localparam CLK_PERIOD     = 10;

    reg                         clk;
    reg                         rst_n;
    reg                         enable;
    reg  [DIVIDEND_WIDTH-1:0]   dividend;
    reg  [PRODUCT_SHIFT-1:0]    numerator;
    reg                         valid_in;
    wire [QUOTIENT_WIDTH-1:0]   quotient;
    wire                        valid_out;

    integer fail_count;

    `define CHECK_EQ_U(TAG, ACT, EXP) \
        if ((ACT) != (EXP)) begin \
            $display("FAIL: %s expected %0d got %0d", TAG, EXP, ACT); \
            fail_count = fail_count + 1; \
        end

    common_lut_divider #(
        .DIVIDEND_WIDTH (DIVIDEND_WIDTH),
        .QUOTIENT_WIDTH (QUOTIENT_WIDTH),
        .PRODUCT_SHIFT  (PRODUCT_SHIFT)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .enable    (enable),
        .dividend  (dividend),
        .numerator (numerator),
        .valid_in  (valid_in),
        .quotient  (quotient),
        .valid_out (valid_out)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    task automatic reset_dut;
        begin
            rst_n     = 1'b0;
            enable    = 1'b1;
            dividend  = {DIVIDEND_WIDTH{1'b0}};
            numerator = {PRODUCT_SHIFT{1'b0}};
            valid_in  = 1'b0;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic apply_case;
        input [DIVIDEND_WIDTH-1:0] dividend_i;
        input [PRODUCT_SHIFT-1:0]  numerator_i;
        input [QUOTIENT_WIDTH-1:0] expected_q;
        input [255:0]              tag;
        begin
            @(negedge clk);
            dividend  = dividend_i;
            numerator = numerator_i;
            valid_in  = 1'b1;
            @(posedge clk);
            @(negedge clk);
            valid_in  = 1'b0;
            dividend  = {DIVIDEND_WIDTH{1'b0}};
            numerator = {PRODUCT_SHIFT{1'b0}};

            while (valid_out !== 1'b1) @(posedge clk);
            `CHECK_EQ_U(tag, quotient, expected_q)
            @(posedge clk);
        end
    endtask

    initial begin
        fail_count = 0;
        reset_dut();

        apply_case(17'd140, 26'd1000, 11'd7,  "divide 1000 by 140");
        apply_case(17'd250, 26'd1000, 11'd4,  "divide 1000 by 250");
        apply_case(17'd280, 26'd20000, 11'd71, "divide 20000 by 280");
        apply_case(17'd374, 26'd184418, 11'd493, "divide 184418 by 374");
        apply_case(17'd374, 26'd186730, 11'd499, "divide 186730 by 374");

        if (fail_count != 0) begin
            $display("FAIL: common_lut_divider reference cases (%0d failures)", fail_count);
            $fatal(1);
        end

        $display("PASS: common_lut_divider reference cases");
        $finish;
    end

endmodule
