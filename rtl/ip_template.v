//////
// description:     Summary the function of this IP.
// created date:    2024-01-01
// created author:  Author Name
// last modified:   2024-01-01
// last author:     Author Name
//////

// module define, make sure the module name is equal to the file name.
module ip_template #(
    parameter DATA_WIDTH = 8
) (
    input  wire                  clk,
    input  wire                  rst_n,
    output wire                  din_ready,
    input  wire                  din_valid,
    input  wire [DATA_WIDTH-1:0] din,
    input  wire                  dout_ready,
    output wire                  dout_valid,
    output wire [DATA_WIDTH:0]   dout
);


////// localparam and parameter define.
localparam DOUT_WIDTH = DATA_WIDTH + 1;
localparam PIPE_S0_WIDTH = DOUT_WIDTH;
localparam PIPE_S1_WIDTH = DOUT_WIDTH;
localparam PIPE_S2_WIDTH = DOUT_WIDTH;


////// declaration part.
// using /*autowire*/ identify and generate wire signal in this module.
// using /*autoreg*/ identify and generate reg signal in this module.
// manual declaration for the following example of the pipeline design.
wire [DATA_WIDTH-1:0] din_mask;

// Pipe stage 0: unpack data
wire [DATA_WIDTH:0]   pipe_s0_din_var_0;
wire [DATA_WIDTH:0]   pipe_s0_din_var_1;
// Pipe stage 0: combinational logic
wire [DATA_WIDTH:0]   pipe_s0_comb_add_0;
wire [DATA_WIDTH:0]   pipe_s0_comb_sub_0;
// Pipe stage 0: pipeline interface
wire [PIPE_S0_WIDTH-1:0] pipe_s0_din;
wire [PIPE_S0_WIDTH-1:0] pipe_s0_dout;
wire                    pipe_s0_din_valid;
wire                    pipe_s0_din_ready;
wire                    pipe_s0_dout_valid;
wire                    pipe_s0_dout_ready;
wire                    valid_s0;
wire                    stage1_ready;

// Pipe stage 1: unpack data (from pipe_s0 delayed by 1 cycle)
wire [DATA_WIDTH:0]   pipe_s1_din_var_0;
wire [DATA_WIDTH:0]   pipe_s1_din_var_1;
// Pipe stage 1: combinational logic
wire [DATA_WIDTH:0]   pipe_s1_comb_mult_0;
wire [2*DATA_WIDTH:0] pipe_s1_comb_mau_0;
wire [DATA_WIDTH:0]   pipe_s1_comb_add_0;
// Pipe stage 1: pipeline interface
wire [PIPE_S1_WIDTH-1:0] pipe_s1_din;
wire [PIPE_S1_WIDTH-1:0] pipe_s1_dout;
wire                    pipe_s1_din_valid;
wire                    pipe_s1_dout_valid;
wire                    pipe_s1_dout_ready;
wire                    valid_s1;

// Pipe stage 2: combinational logic (bypass stage)
wire [DOUT_WIDTH-1:0] pipe_s2_comb_add_0;
wire [DOUT_WIDTH-1:0] pipe_s2_comb_logic_0;
// Pipe stage 2: pipeline interface
wire [PIPE_S2_WIDTH-1:0] pipe_s2_din;
wire [PIPE_S2_WIDTH-1:0] pipe_s2_dout;
wire                    pipe_s2_din_valid;
wire                    pipe_s2_dout_valid;
wire                    valid_s2;


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
assign pipe_s0_din_var_0 = din[DATA_WIDTH+:0];   // the part of the variable name: var can be named as data type.
assign pipe_s0_din_var_1 = din[DATA_WIDTH+:DATA_WIDTH];
// pipe stage 0 combinational logic.
assign pipe_s0_comb_add_0 = pipe_s0_din_var_0 + pipe_s0_din_var_1;
assign pipe_s0_comb_sub_0 = pipe_s0_din_var_0 - pipe_s0_din_var_1; // the part of the variable name: logic can be named as add/sub/mult/div or something else according to the real function.
// pipe stage 0 input data valid.
assign pipe_s0_din_valid = din_valid && din_ready;
// pipe stage 0 input data package.
assign pipe_s0_din = {
    pipe_s0_comb_add_0,
    pipe_s0_comb_sub_0
};


////// pipe stage 1
// pipe stage 1 unpack data (from pipe_s0 output, delayed by 1 cycle via delay_1 instance)
assign pipe_s1_din_var_0 = pipe_s0_dout[PIPE_S0_WIDTH-1:DATA_WIDTH];
assign pipe_s1_din_var_1 = pipe_s0_dout[DATA_WIDTH-1:0];
// pipe stage 1 combinational logic.
assign pipe_s1_comb_mult_0 = pipe_s1_din_var_0 * pipe_s1_din_var_1;
assign pipe_s1_comb_add_0 = pipe_s1_din_var_0 + pipe_s1_din_var_1;
// pipe stage 1 input data valid.
assign pipe_s1_din_valid = pipe_s0_dout_valid && pipe_s0_dout_ready;
// pipe stage 1 input data package.
assign pipe_s1_din = {
    pipe_s1_comb_mult_0,
    pipe_s1_comb_add_0
};


////// pipe stage 2 (bypass stage)
// pipe stage 2 unpack data
assign pipe_s2_comb_add_0 = pipe_s1_dout[PIPE_S1_WIDTH-1:DATA_WIDTH];
assign pipe_s2_comb_logic_0 = pipe_s1_dout[DATA_WIDTH-1:0];
// pipe stage 2 combinational logic (simple pass-through or additional processing)
assign pipe_s2_din = {pipe_s2_comb_add_0};
// pipe stage 2 input data valid.
assign pipe_s2_din_valid = pipe_s1_dout_valid;


////// final output
// Unpack final stage outputs.
assign dout       = pipe_s2_dout[PIPE_S2_WIDTH-1:0];
assign dout_valid = valid_s2;


////// pipeline instances
// using auto_template to template module if emacs-verilog-mode is available.
// using /*autoinst*/ to instance module if emacs-verilog-mode is available.

////// pipe stage 0 instance
/* common_pipe_slice auto_template "\(u_pipe_s0\)" (
    .DATA_WIDTH (PIPE_S0_WIDTH),
    .RESET_VAL  (0            ),
    .PIPE_TYPE  (0            ),
    .clk        (clk          ),
    .rst_n      (rst_n        ),
    .din        (pipe_s0_din  ),
    .din_valid  (din_shake    ),
    .din_ready  (din_ready    ),
    .dout       (pipe_s0_dout ),
    .dout_valid (valid_s0     ),
    .dout_ready (stage1_ready )
); */
common_pipe_slice #(
    .DATA_WIDTH (PIPE_S0_WIDTH),
    .RESET_VAL  (0),
    .PIPE_TYPE  (0)
) u_pipe_s0 (
    .clk        (clk),
    .rst_n      (rst_n),
    .din        (pipe_s0_din),
    .din_valid  (din_valid),
    .din_ready  (pipe_s0_din_ready),
    .dout       (pipe_s0_dout),
    .dout_valid (valid_s0),
    .dout_ready (pipe_s0_dout_ready)
);

assign din_ready = pipe_s0_din_ready;

////// delay_1 instances for pipe_s1 operands
// delay pipe_s0 variables by 1 cycle to align with pipe_s1 timing
/* common_pipe_slice auto_template "u_pipe_s0_din_var_0_delay_1" (
    .DATA_WIDTH (DATA_WIDTH+1),
    .RESET_VAL  (0            ),
    .PIPE_TYPE  (0            ),
    .clk        (clk          ),
    .rst_n      (rst_n        ),
    .din        (pipe_s0_din_var_0),
    .din_valid  (valid_s0     ),
    .din_ready  (stage1_ready ),
    .dout       (pipe_s1_din_var_0),
    .dout_valid (pipe_s1_din_valid),
    .dout_ready (pipe_s1_dout_ready)
); */
common_pipe_slice #(
    .DATA_WIDTH (DATA_WIDTH + 1),
    .RESET_VAL  (0),
    .PIPE_TYPE  (0)
) u_pipe_s0_din_var_0_delay_1 (
    .clk        (clk),
    .rst_n      (rst_n),
    .din        (pipe_s0_din_var_0),
    .din_valid  (valid_s0),
    .din_ready  (stage1_ready),
    .dout       (pipe_s1_din_var_0),
    .dout_valid (),
    .dout_ready (1'b1)
);

/* common_pipe_slice auto_template "u_pipe_s0_din_var_1_delay_1" (
    .DATA_WIDTH (DATA_WIDTH+1),
    .RESET_VAL  (0            ),
    .PIPE_TYPE  (0            ),
    .clk        (clk          ),
    .rst_n      (rst_n        ),
    .din        (pipe_s0_din_var_1),
    .din_valid  (valid_s0     ),
    .din_ready  (stage1_ready ),
    .dout       (pipe_s1_din_var_1),
    .dout_valid (pipe_s1_din_valid),
    .dout_ready (pipe_s1_dout_ready)
); */
common_pipe_slice #(
    .DATA_WIDTH (DATA_WIDTH + 1),
    .RESET_VAL  (0),
    .PIPE_TYPE  (0)
) u_pipe_s0_din_var_1_delay_1 (
    .clk        (clk),
    .rst_n      (rst_n),
    .din        (pipe_s0_din_var_1),
    .din_valid  (valid_s0),
    .din_ready  (stage1_ready),
    .dout       (pipe_s1_din_var_1),
    .dout_valid (),
    .dout_ready (1'b1)
);

////// pipe stage 1 instance
/* common_pipe_slice auto_template "u_pipe_s1" (
    .DATA_WIDTH (PIPE_S1_WIDTH),
    .RESET_VAL  (0            ),
    .PIPE_TYPE  (0            ),
    .clk        (clk          ),
    .rst_n      (rst_n        ),
    .din        (pipe_s1_din  ),
    .din_valid  (pipe_s1_din_valid),
    .din_ready  (stage1_ready ),
    .dout       (pipe_s1_dout ),
    .dout_valid (valid_s1     ),
    .dout_ready (pipe_s1_dout_ready)
); */
common_pipe_slice #(
    .DATA_WIDTH (PIPE_S1_WIDTH),
    .RESET_VAL  (0),
    .PIPE_TYPE  (0)
) u_pipe_s1 (
    .clk        (clk),
    .rst_n      (rst_n),
    .din        (pipe_s1_din),
    .din_valid  (pipe_s1_din_valid),
    .din_ready  (stage1_ready),
    .dout       (pipe_s1_dout),
    .dout_valid (valid_s1),
    .dout_ready (pipe_s1_dout_ready)
);

////// pipe stage 2 instance (bypass/passthrough stage)
/* common_pipe_slice auto_template "u_pipe_s2" (
    .DATA_WIDTH (PIPE_S2_WIDTH),
    .RESET_VAL  (0            ),
    .PIPE_TYPE  (0            ),
    .clk        (clk          ),
    .rst_n      (rst_n        ),
    .din        (pipe_s2_din  ),
    .din_valid  (pipe_s2_din_valid),
    .din_ready  (stage1_ready ),
    .dout       (pipe_s2_dout ),
    .dout_valid (valid_s2     ),
    .dout_ready (dout_ready   )
); */
common_pipe_slice #(
    .DATA_WIDTH (PIPE_S2_WIDTH),
    .RESET_VAL  (0),
    .PIPE_TYPE  (0)
) u_pipe_s2 (
    .clk        (clk),
    .rst_n      (rst_n),
    .din        (pipe_s2_din),
    .din_valid  (pipe_s2_din_valid),
    .din_ready  (pipe_s1_dout_ready),
    .dout       (pipe_s2_dout),
    .dout_valid (valid_s2),
    .dout_ready (dout_ready)
);


endmodule