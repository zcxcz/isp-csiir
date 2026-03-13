//-----------------------------------------------------------------------------
// Module: common_counter
// Description: Parameterized counter with enable, load, and direction control
//              Supports up/down counting with saturating or wrap-around behavior
//-----------------------------------------------------------------------------

module common_counter #(
    parameter WIDTH       = 16,
    parameter RESET_VAL   = 0,
    parameter COUNT_UP    = 1,      // 1 = count up, 0 = count down
    parameter SATURATE    = 0       // 1 = saturate at max/min, 0 = wrap around
)(
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      enable,
    input  wire                      load,
    input  wire [WIDTH-1:0]          load_val,
    input  wire                      count_en,   // Count enable
    input  wire                      count_dir,  // 1 = up, 0 = down (overrides COUNT_UP)

    output wire [WIDTH-1:0]          count,
    output wire                      max_reached,
    output wire                      min_reached
);

    // Internal counter register
    reg [WIDTH-1:0] count_reg;

    // Determine counting direction
    wire counting_up = count_dir;

    // Max and min values
    wire [WIDTH-1:0] max_val = {WIDTH{1'b1}};
    wire [WIDTH-1:0] min_val = {WIDTH{1'b0}};

    // Counter logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count_reg <= RESET_VAL[WIDTH-1:0];
        end else if (!enable) begin
            count_reg <= count_reg;
        end else if (load) begin
            count_reg <= load_val;
        end else if (count_en) begin
            if (counting_up) begin
                // Counting up
                if (SATURATE && count_reg == max_val)
                    count_reg <= max_val;
                else
                    count_reg <= count_reg + 1'b1;
            end else begin
                // Counting down
                if (SATURATE && count_reg == min_val)
                    count_reg <= min_val;
                else
                    count_reg <= count_reg - 1'b1;
            end
        end
    end

    // Output assignments
    assign count       = count_reg;
    assign max_reached = (count_reg == max_val);
    assign min_reached = (count_reg == min_val);

endmodule