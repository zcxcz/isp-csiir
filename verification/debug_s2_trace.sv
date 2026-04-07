// Track Stage 2 avg0_u output
integer s2_avg_cnt;
initial s2_avg_cnt = 0;
always @(posedge clk) begin
    if (dut.s2_valid && s2_avg_cnt < 5) begin
        s2_avg_cnt = s2_avg_cnt + 1;
        $display("[S2 AVG %0d] avg0_c=%0d avg0_u=%0d avg0_d=%0d avg0_l=%0d avg0_r=%0d",
            s2_avg_cnt, $signed(dut.s2_avg0_c), $signed(dut.s2_avg0_u),
            $signed(dut.s2_avg0_d), $signed(dut.s2_avg0_l), $signed(dut.s2_avg0_r));
    end
end
