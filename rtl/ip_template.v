//////
// description:     Summary the function of this IP.
// created date:    Record the time of this module creation.
// created author:  Record the author of this module creation.
// last modified:   Record the time of the last modification.
// last author:     Record the author of the last modification.
//////

// module define, make sure the module name is equal to the file name.
module ip_template #(
    parameter DATA_WIDTH = 8
) (
    input  wire                  clk,
    input  wire                  rst_n,
    output wire                  din_ready,
    input  wire                  din_valid,
    input  wire [DATA_WIDTH-1:0] dina,
    input  wire [DATA_WIDTH-1:0] din,
    input  wire                  dout_ready,
    output wire                  dout_valid,
    output wire [DATA_WIDTH:0]   dout
);


////// localparam and parameter define.
localparam DOUT_WIDTH = DATA_WIDTH + 1;
localparam PIPE_S0_WIDTH = DOUT_WIDTH;
localparam PIPE_S1_WIDTH = DOUT_WIDTH;


////// declaration part.
// using /*autowire*/ identify and generate wire signal in this module.
// using /*autoreg*/ identify and generate reg signal in this module.
// manual declaration for the following example of the pipeline design.
wire [DATA_WIDTH-1:0] din_mask;
wire [DATA_WIDTH:0] pipe_s0_comb_add_0;
wire [DATA_WIDTH:0] pipe_s0_comb_sub_0;
wire [DATA_WIDTH:0] pipe_s1_comb_mult_0;
wire [2*DATA_WIDTH:0] pipe_s1_comb_mau_0;


////// din mask logic
// The following mask logic is an optional power optimization choice,
// which means to prevent the combinational logic input without din_valid.
`ifdef DIN_MASK
    assign din_mask = din_valid ? din : {DATA_WIDTH{1'b0}};
`else
    assign din_mask = din;
`endif


////// pipe stage 0
// pipe stage 0 unpack data
assign pipe_s0_din_var_0 = din[DATA_WIDTH+:0]; // the part of the variable name: var can be named as data type.
assign pipe_s0_din_var_1 = din[DATA_WIDTH+:DATA_WIDTH];
// pipe stage 0 combinational logic.
assign pipe_s0_din_logic_0 = pipe_s0_din_var_0 + pipe_s0_din_var_1;
assign pipe_s0_din_logic_1 = pipe_s0_din_var_0 - pipe_s0_din_var_1; // the part of the variable name: logic can be named as add/sub/mult/div or something else according to the real function.
// pipe stage 0 input data valid.
assign pipe_s0_din_valid = din_valid && din_ready;
// pipe stage 0 input data package.
assign pipe_s0_din = {
    pipe_s0_din_logic_0,
    pipe_s0_din_logic_1
};


////// pipe stage 1
// pipe stage 1 unpack data
assign pipe_s1_din_var_0 = pipe_s0_dout_pack[DATA_WIDTH+:0];
assign pipe_s1_din_var_1 = pipe_s0_dout_pack[DATA_WIDTH+:DATA_WIDTH];
// pipe stage 1 combinational logic.
assign pipe_s1_din_logic_0 = pipe_s0_din_var_0_delay1 * pipe_s0_din_var_1_delay1;
assign pipe_s1_din_logic_1 = pipe_s1_din_var_0 + pipe_s1_din_var_1;
// pipe stage 1 input data valid.
assign pipe_s1_din_valid = pipe_s0_dout_valid && pipe_s0_dout_ready;
// pipe stage 1 input data package.
assign pipe_s1_din = {
    pipe_s1_din_logic_0,
    pipe_s1_din_logic_1
};
// pipe stage 1 unpack output data
assign pipe_s1_dout_logic_0 = pipe_s1_dout_pack[DATA_WIDTH+:0];
assign pipe_s1_dout_logic_1 = pipe_s1_dout_pack[(DATA_WIDTH*2-1):DATA_WIDTH];

// pipe stage 0 input data valid.
assign pipe_s0_din_valid = din_valid && din_ready;
// pipe stage 1 input data package.
assign pipe_s1_din_pack = {
    pipe_s1_comb_add_0,
    pipe_s1_comb_logic_0
};

// unpack pipe0 output data
assign pipe_s2_din_valid = pipe_s0_dout_valid;
assign pipe_s2_comb_add_0 = pipe_s0_dout_pack;
assign pipe_s2_comb_logic_0 = pipe_s1_comb_add_0 & {DOUT_WIDTH{1'b1}}; 

assign pipe_s1_din_pack = {
    pipe_s1_comb_add_0,
    pipe_s1_comb_logic_0
};



// Unpack final stage outputs.
assign dout       = pipe_s2_dout[DOUT_WIDTH-1:0];
assign dout_valid = valid_s2;

// pipeline instance.
// using auto_template to template module if emacs-verilog-mode is available.
// using /*autoinst*/ to instance module if emacs-verilog-mode is available.
/* common_pipe_slice auto_template "\(u_pipe_s0\)" (
    .DATA_WIDTH (PIPE_S0_WIDTH),
    .RESET_VAL  (0            ),
    .PIPE_TYPE  (0            ),
    .clk        (clk          ),
    .rst_n      (rst_n        ),
    .din        (pipe_s0_din  ),
    .din_valid   (din_shake    ),
    .din_ready  (din_ready    ),
    .dout       (pipe_s0_dout ),
    .dout_valid  (valid_s0     ),
    .dout_ready   (stage1_ready )
); */
common_pipe_slice #(
    .DATA_WIDTH (PIPE_S0_WIDTH),
    .RESET_VAL  (0),
    .PIPE_TYPE  (0)
) u_pipe_s0 (
    .clk       (clk),
    .rst_n     (rst_n),
    .din       (pipe_s0_din),
    .din_valid  (din_shake),
    .din_ready (din_ready),
    .dout      (pipe_s0_dout),
    .dout_valid (valid_s0),
    .dout_ready  (stage1_ready)
);

// Unpack stage outputs.
assign sum_s0 = pipe_s0_dout[DOUT_WIDTH-1:0];

// Cycle 1 combinational logic.
// This stage is intentionally simple in the template. Real algorithm IP can
// place rounding/saturation/selection or sideband update logic here.
assign dout_s1_comb = sum_s0;
assign pipe_s1_din  = {dout_s1_comb};

////// pipeline instance.
/* common_pipe_slice auto_template "u_\(pipe_s[0-9]+\)" (
    .DATA_WIDTH (PIPE_S1_WIDTH),
    .RESET_VAL  (0            ),
    .PIPE_TYPE  (0            ),
    .clk        (clk          ),
    .rst_n      (rst_n        ),
    .\(din.*\)  (@_\1[]),
    .\(dout.*\) (@_\1[]),
); */
common_pipe_slice #(
    .DATA_WIDTH (PIPE_S1_WIDTH),
    .RESET_VAL  (0),
    .PIPE_TYPE  (0)
) u_pipe_s0 (
    .clk       (clk),
    .rst_n     (rst_n),
    .din       (pipe_s1_din),
    .din_valid  (valid_s0),
    .din_ready (stage1_ready),
    .dout      (pipe_s1_dout),
    .dout_valid (valid_s1),
    .dout_ready  (dout_ready)
);
/* common_pipe_slice auto_template "u_\(pipe_s[0-9]+\)" (
    .DATA_WIDTH (PIPE_S1_WIDTH),
    .RESET_VAL  (0            ),
    .PIPE_TYPE  (0            ),
    .clk        (clk          ),
    .rst_n      (rst_n        ),
    .\(din.*\)  (@_\1[]),
    .\(dout.*\) (@_\1[]),
); */
common_pipe_slice #(
    .DATA_WIDTH (PIPE_S1_WIDTH),
    .RESET_VAL  (0),
    .PIPE_TYPE  (0)
) u_pipe_s1 (
    .clk       (clk),
    .rst_n     (rst_n),
    .din       (pipe_s1_din),
    .din_valid  (valid_s0),
    .din_ready (stage1_ready),
    .dout      (pipe_s1_dout),
    .dout_valid (valid_s1),
    .dout_ready  (dout_ready)
);
/* common_pipe_slice auto_template "u_\(pipe_s[0-9]+\)" (
    .DATA_WIDTH (PIPE_S1_WIDTH),
    .RESET_VAL  (0            ),
    .PIPE_TYPE  (0            ),
    .clk        (clk          ),
    .rst_n      (rst_n        ),
    .\(din.*\)  (@_\1[]),
    .\(dout.*\) (@_\1[]),
); */
common_pipe_slice #(
    .DATA_WIDTH (PIPE_S1_WIDTH),
    .RESET_VAL  (0),
    .PIPE_TYPE  (0)
) u_pipe_s2 (
    .clk       (clk),
    .rst_n     (rst_n),
    .din       (pipe_s1_din),
    .din_valid  (valid_s0),
    .din_ready (stage1_ready),
    .dout      (pipe_s1_dout),
    .dout_valid (valid_s1),
    .dout_ready  (dout_ready)
);

////// bypass instance.
/* common_pipe_slice auto_template "u_\(pipe_s[0-9]+\)" (
    .DATA_WIDTH (PIPE_S1_WIDTH),
    .RESET_VAL  (0            ),
    .PIPE_TYPE  (0            ),
    .clk        (clk          ),
    .rst_n      (rst_n        ),
    .\(din.*\)  (@_\1[]),
    .\(dout.*\) (@_\1[]),
); */
common_pipe_slice #(
    .DATA_WIDTH (PIPE_S1_WIDTH),
    .RESET_VAL  (0),
    .PIPE_TYPE  (0)
) u_pipe_s0_din_var_0_delay_1 (
    .clk       (clk),
    .rst_n     (rst_n),
    .din       (pipe_s1_din),
    .din_valid  (valid_s0),
    .din_ready (stage1_ready),
    .dout      (pipe_s1_dout),
    .dout_valid (valid_s1),
    .dout_ready  (dout_ready)
);


endmodule
