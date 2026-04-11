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
    input  wire [2*DATA_WIDTH-1:0] din,
    input  wire                  dout_ready,
    output wire                  dout_valid,
    output wire [DATA_WIDTH:0]   dout
);


////// localparam and parameter define.
// Data unpack width
localparam UNPACK_WIDTH = DATA_WIDTH;         // width of each unpacked variable
// Operation result width (add/sub: DATA_WIDTH+1, mult: 2*(DATA_WIDTH+1))
localparam OP_WIDTH     = DATA_WIDTH + 1;      // result width of add/sub
localparam MULT_WIDTH   = 2 * (DATA_WIDTH + 1); // result width of multiply
// Pipeline stage width: based on what each stage packs
localparam PIPE_S0_WIDTH = 2 * OP_WIDTH;       // packs {add_0, sub_0}
localparam PIPE_S1_WIDTH = MULT_WIDTH + OP_WIDTH; // packs {mult_0, add_0}
localparam PIPE_S2_WIDTH = DOUT_WIDTH;         // final output width
// Output width
localparam DOUT_WIDTH = DATA_WIDTH + 1;


////// declaration part.
// using /*autowire*/ identify and generate wire signal in this module.
// using /*autoreg*/ identify and generate reg signal in this module.
// manual declaration for the following example of the pipeline design.
wire [2*DATA_WIDTH-1:0] din_mask;

// Pipe stage 0: unpack data
wire [UNPACK_WIDTH-1:0]   pipe_s0_din_var_0;
wire [UNPACK_WIDTH-1:0]   pipe_s0_din_var_1;
// Pipe stage 0: combinational logic
wire [OP_WIDTH-1:0]       pipe_s0_comb_add_0;
wire [OP_WIDTH-1:0]       pipe_s0_comb_sub_0;
// Pipe stage 0: pipeline interface
wire [PIPE_S0_WIDTH-1:0]  pipe_s0_din;
wire [PIPE_S0_WIDTH-1:0]  pipe_s0_dout;
wire                      pipe_s0_din_valid;
wire                      pipe_s0_din_ready;
wire                      pipe_s0_dout_valid;
wire                      pipe_s0_dout_ready;

// Pipe stage 1: unpack data (from pipe_s0 delayed by 1 cycle)
wire [OP_WIDTH-1:0]       pipe_s1_din_var_0;
wire [OP_WIDTH-1:0]       pipe_s1_din_var_1;
// Pipe stage 1: delayed operands (1 cycle delay from pipe_s0 input)
wire [OP_WIDTH-1:0]       pipe_s0_din_var_0_delay_1;
wire [OP_WIDTH-1:0]       pipe_s0_din_var_1_delay_1;
// Pipe stage 1: combinational logic
wire [MULT_WIDTH-1:0]     pipe_s1_comb_mult_0;
wire [OP_WIDTH-1:0]       pipe_s1_comb_add_0;
// Pipe stage 1: pipeline interface
wire [PIPE_S1_WIDTH-1:0]  pipe_s1_din;
wire [PIPE_S1_WIDTH-1:0]  pipe_s1_dout;
wire                      pipe_s1_din_valid;
wire                      pipe_s1_dout_valid;
wire                      pipe_s1_dout_ready;

// Pipe stage 2: unpack data (from pipe_s1)
wire [MULT_WIDTH-1:0]     pipe_s2_din_mult_0;
wire [OP_WIDTH-1:0]       pipe_s2_din_add_0;
// Pipe stage 2: combinational logic (select/convert to final output)
wire [DOUT_WIDTH-1:0]     pipe_s2_comb_result;
// Pipe stage 2: pipeline interface
wire [PIPE_S2_WIDTH-1:0]  pipe_s2_din;
wire [PIPE_S2_WIDTH-1:0]  pipe_s2_dout;
wire                      pipe_s2_din_valid;
wire                      pipe_s2_din_ready;
wire                      pipe_s2_dout_valid;


////// din mask logic
// The following mask logic is an optional power optimization choice,
// which means to prevent the combinational logic input without din_valid.
`ifdef DIN_MASK
    assign din_mask = din_valid ? din : {2*DATA_WIDTH{1'b0}};
`else
    assign din_mask = din;
`endif


////// din
// din ready: from pipe_s0 output (backpressure propagation)
assign din_ready = pipe_s0_din_ready;


////// pipe stage 0
// data unpack from input
assign pipe_s0_din_var_0 = din_mask[0+:UNPACK_WIDTH];             // [DATA_WIDTH-1:0]
assign pipe_s0_din_var_1 = din_mask[DATA_WIDTH+:UNPACK_WIDTH];    // [DATA_WIDTH-1:0]
// comb: add and subtract
assign pipe_s0_comb_add_0 = pipe_s0_din_var_0 + pipe_s0_din_var_1;  // [OP_WIDTH-1:0]
assign pipe_s0_comb_sub_0 = pipe_s0_din_var_0 - pipe_s0_din_var_1;  // [OP_WIDTH-1:0]
// din_valid: forward from input
assign pipe_s0_din_valid = din_valid;
// din_ready: from pipe_s1 output (backpressure)
assign pipe_s0_din_ready = pipe_s1_din_ready;
// din_shake: handshake indicator for pattern extraction
assign pipe_s0_din_shake = pipe_s0_din_valid & pipe_s0_din_ready;
// data pack for pipeline register input
assign pipe_s0_din = {pipe_s0_comb_add_0, pipe_s0_comb_sub_0};
// dout_ready: from pipe_s1
assign pipe_s0_dout_ready = pipe_s1_din_ready;


////// pipe stage 1
// data unpack from pipe_s0 output
assign pipe_s1_din_var_0 = pipe_s0_dout[OP_WIDTH-1:0];                           // [OP_WIDTH-1:0]
assign pipe_s1_din_var_1 = pipe_s0_dout[2*OP_WIDTH-1:OP_WIDTH];                 // [OP_WIDTH-1:0]
assign pipe_s1_din_var_2 = pipe_s0_din_var_0_delay_1;   // delayed var_0 from delay_1 instance
assign pipe_s1_din_var_3 = pipe_s0_din_var_1_delay_1;   // delayed var_1 from delay_1 instance
// comb
assign pipe_s1_comb_mult_0 = pipe_s1_din_var_0 * pipe_s1_din_var_1;  // [MULT_WIDTH-1:0]
assign pipe_s1_comb_abs_0  = pipe_s1_din_var_2;   // [OP_WIDTH-1:0]
assign pipe_s1_comb_abs_1  = pipe_s1_din_var_3;   // [OP_WIDTH-1:0]
// din_valid: from pipe_s0 output valid
assign pipe_s1_din_valid = pipe_s0_dout_valid;
// din_ready: from pipe_s1 output (backpressure from pipe_s1 itself)
// pipe_s1_din_ready IS pipe_s1_dout_ready (backward propagation through pipeline)
// pipe_s1_dout_ready is driven by pipe_s1 instance's dout_ready port
assign pipe_s1_din_ready = pipe_s1_dout_ready;
// din_shake: handshake indicator for pattern extraction
assign pipe_s1_din_shake = pipe_s1_din_valid & pipe_s1_din_ready;
// data pack for pipeline register input
assign pipe_s1_din = {pipe_s1_comb_mult_0, pipe_s1_comb_abs_0, pipe_s1_comb_abs_1};
// dout_ready: from pipe_s2 din_ready
assign pipe_s1_dout_ready = pipe_s2_din_ready;


////// pipe stage 2 (bypass/convert stage)
// din_valid: from pipe_s1 output valid
assign pipe_s2_din_valid = pipe_s1_dout_valid;
// din_ready: from dout_ready (backpressure)
assign pipe_s2_din_ready = dout_ready;
// din_shake: handshake indicator for pattern extraction
assign pipe_s2_din_shake = pipe_s2_din_valid & pipe_s2_din_ready;
// comb: unpack and convert to final output width
assign pipe_s2_din_mult_0 = pipe_s1_dout[MULT_WIDTH-1:0];                        // [MULT_WIDTH-1:0]
assign pipe_s2_din_add_0  = pipe_s1_dout[MULT_WIDTH+:OP_WIDTH];                  // [OP_WIDTH-1:0]
assign pipe_s2_comb_result = pipe_s2_din_mult_0[MULT_WIDTH-1:OP_WIDTH];  // take upper OP_WIDTH bits
// data pack for pipeline register input
assign pipe_s2_din = {pipe_s2_comb_result};
// dout_ready: to dout_ready
assign pipe_s2_dout_ready = dout_ready;


////// dout
// dout valid
assign dout       = pipe_s2_dout[PIPE_S2_WIDTH-1:0];
assign dout_valid = pipe_s2_dout_valid;


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
    .din_valid  (pipe_s0_din_valid),
    .din_ready  (pipe_s0_din_ready),
    .dout       (pipe_s0_dout ),
    .dout_valid (pipe_s0_dout_valid),
    .dout_ready (pipe_s0_dout_ready)
); */
common_pipe_slice #(
    .DATA_WIDTH (PIPE_S0_WIDTH),
    .RESET_VAL  (0),
    .PIPE_TYPE  (0)
) u_pipe_s0 (
    .clk        (clk),
    .rst_n      (rst_n),
    .din        (pipe_s0_din),
    .din_valid  (pipe_s0_din_valid),
    .din_ready  (pipe_s0_din_ready),
    .dout       (pipe_s0_dout),
    .dout_valid (pipe_s0_dout_valid),
    .dout_ready (pipe_s0_dout_ready)
);

////// delay_1 instances for pipe_s0 operands
// delay pipe_s0_din_var_0/1 by 1 cycle to align with pipe_s1 multiply+abs timing
// _delay_1: 1 cycle delay from pipe_s0 input (which is din timing)
/* common_pipe_slice auto_template "u_pipe_s0_din_var_0_delay_1" (
    .DATA_WIDTH (OP_WIDTH),
    .RESET_VAL  (0       ),
    .PIPE_TYPE  (0       ),
    .clk        (clk     ),
    .rst_n      (rst_n   ),
    .din        (pipe_s0_din_var_0),
    .din_valid  (pipe_s0_din_valid),
    .din_ready  (pipe_s0_din_ready),
    .dout       (pipe_s0_din_var_0_delay_1),
    .dout_valid (),
    .dout_ready (1'b1)
); */
common_pipe_slice #(
    .DATA_WIDTH (OP_WIDTH),
    .RESET_VAL  (0),
    .PIPE_TYPE  (0)
) u_pipe_s0_din_var_0_delay_1 (
    .clk        (clk),
    .rst_n      (rst_n),
    .din        (pipe_s0_din_var_0),
    .din_valid  (pipe_s0_din_valid),
    .din_ready  (pipe_s0_din_ready),
    .dout       (pipe_s0_din_var_0_delay_1),
    .dout_valid (),
    .dout_ready (1'b1)
);

/* common_pipe_slice auto_template "u_pipe_s0_din_var_1_delay_1" (
    .DATA_WIDTH (OP_WIDTH),
    .RESET_VAL  (0       ),
    .PIPE_TYPE  (0       ),
    .clk        (clk     ),
    .rst_n      (rst_n   ),
    .din        (pipe_s0_din_var_1),
    .din_valid  (pipe_s0_din_valid),
    .din_ready  (pipe_s0_din_ready),
    .dout       (pipe_s0_din_var_1_delay_1),
    .dout_valid (),
    .dout_ready (1'b1)
); */
common_pipe_slice #(
    .DATA_WIDTH (OP_WIDTH),
    .RESET_VAL  (0),
    .PIPE_TYPE  (0)
) u_pipe_s0_din_var_1_delay_1 (
    .clk        (clk),
    .rst_n      (rst_n),
    .din        (pipe_s0_din_var_1),
    .din_valid  (pipe_s0_din_valid),
    .din_ready  (pipe_s0_din_ready),
    .dout       (pipe_s0_din_var_1_delay_1),
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
    .din_ready  (pipe_s1_din_ready),
    .dout       (pipe_s1_dout ),
    .dout_valid (pipe_s1_dout_valid),
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
    .din_ready  (pipe_s1_din_ready),
    .dout       (pipe_s1_dout),
    .dout_valid (pipe_s1_dout_valid),
    .dout_ready (pipe_s1_dout_ready)
);

////// pipe stage 2 instance (bypass/convert stage)
/* common_pipe_slice auto_template "u_pipe_s2" (
    .DATA_WIDTH (PIPE_S2_WIDTH),
    .RESET_VAL  (0            ),
    .PIPE_TYPE  (0            ),
    .clk        (clk          ),
    .rst_n      (rst_n        ),
    .din        (pipe_s2_din  ),
    .din_valid  (pipe_s2_din_valid),
    .din_ready  (pipe_s2_din_ready),
    .dout       (pipe_s2_dout ),
    .dout_valid (pipe_s2_dout_valid     ),
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
    .din_ready  (pipe_s2_din_ready),
    .dout       (pipe_s2_dout),
    .dout_valid (pipe_s2_dout_valid),
    .dout_ready (dout_ready)
);


endmodule
