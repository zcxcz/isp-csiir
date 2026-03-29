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
    input  wire [DATA_WIDTH-1:0] dinb,
    input  wire                  dout_ready,
    output wire                  dout_valid,
    output wire [DATA_WIDTH:0]   dout
);

localparam DOUT_WIDTH = DATA_WIDTH + 1;
localparam PIPE_S0_WIDTH = DOUT_WIDTH;
localparam PIPE_S1_WIDTH = DOUT_WIDTH;

// declaration part.

// using /*autowire*/ identify and generate wire signal in this module.
// using /*autoreg*/ identify and generate reg signal in this module.
// manual declaration for the following example of the pipeline design.
wire                  din_shake;
wire [DATA_WIDTH-1:0] dina_mask;
wire [DATA_WIDTH-1:0] dinb_mask;
wire [DOUT_WIDTH-1:0] add_result_comb;
wire [PIPE_S0_WIDTH-1:0] pipe_s0_din;
wire [PIPE_S0_WIDTH-1:0] pipe_s0_dout;
wire                     valid_s0;
wire                     stage1_ready;
wire [DOUT_WIDTH-1:0]    sum_s0;
wire [DOUT_WIDTH-1:0]    dout_s1_comb;
wire [PIPE_S1_WIDTH-1:0] pipe_s1_din;
wire [PIPE_S1_WIDTH-1:0] pipe_s1_dout;
wire                     valid_s1;

// logic part, including pipeline design and integration of some function module
// instances.

// The following mask logic is an optional power optimization example.
// If ready-path timing is critical, consider removing this masking and feeding
// the combinational result directly into the pipe slice.
assign din_shake = din_valid & din_ready;
assign dina_mask = din_shake ? dina : {DATA_WIDTH{1'b0}};
assign dinb_mask = din_shake ? dinb : {DATA_WIDTH{1'b0}};
assign add_result_comb = dina_mask + dinb_mask;

// Cycle 0 pipeline stage packing example:
//   - Pack all stage-local data path signals into pipe_sX_din
//   - Sideband signals such as pixel_x/pixel_y/win_size/mode can be appended
//     here when the real algorithm IP needs them
assign pipe_s0_din = {add_result_comb};

// using auto_template to template module if emacs-verilog-mode is available.
// using /*autoinst*/ to instance module if emacs-verilog-mode is available.
/* common_pipe_slice auto_template "\(u_pipe_s0\)" (
    .DATA_WIDTH (PIPE_S0_WIDTH),
    .RESET_VAL  (0            ),
    .PIPE_TYPE  (0            ),
    .clk        (clk          ),
    .rst_n      (rst_n        ),
    .din        (pipe_s0_din  ),
    .valid_in   (din_shake    ),
    .ready_out  (din_ready    ),
    .dout       (pipe_s0_dout ),
    .valid_out  (valid_s0     ),
    .ready_in   (stage1_ready )
); */
common_pipe_slice #(
    .DATA_WIDTH (PIPE_S0_WIDTH),
    .RESET_VAL  (0),
    .PIPE_TYPE  (0)
) u_pipe_s0 (
    .clk       (clk),
    .rst_n     (rst_n),
    .din       (pipe_s0_din),
    .valid_in  (din_shake),
    .ready_out (din_ready),
    .dout      (pipe_s0_dout),
    .valid_out (valid_s0),
    .ready_in  (stage1_ready)
);

// Unpack stage outputs.
assign sum_s0 = pipe_s0_dout[DOUT_WIDTH-1:0];

// Cycle 1 combinational logic.
// This stage is intentionally simple in the template. Real algorithm IP can
// place rounding/saturation/selection or sideband update logic here.
assign dout_s1_comb = sum_s0;
assign pipe_s1_din  = {dout_s1_comb};

/* common_pipe_slice auto_template "\(u_pipe_s1\)" (
    .DATA_WIDTH (PIPE_S1_WIDTH),
    .RESET_VAL  (0            ),
    .PIPE_TYPE  (0            ),
    .clk        (clk          ),
    .rst_n      (rst_n        ),
    .din        (pipe_s1_din  ),
    .valid_in   (valid_s0     ),
    .ready_out  (stage1_ready ),
    .dout       (pipe_s1_dout ),
    .valid_out  (valid_s1     ),
    .ready_in   (dout_ready   )
); */
common_pipe_slice #(
    .DATA_WIDTH (PIPE_S1_WIDTH),
    .RESET_VAL  (0),
    .PIPE_TYPE  (0)
) u_pipe_s1 (
    .clk       (clk),
    .rst_n     (rst_n),
    .din       (pipe_s1_din),
    .valid_in  (valid_s0),
    .ready_out (stage1_ready),
    .dout      (pipe_s1_dout),
    .valid_out (valid_s1),
    .ready_in  (dout_ready)
);

// Unpack final stage outputs.
assign dout       = pipe_s1_dout[DOUT_WIDTH-1:0];
assign dout_valid = valid_s1;

endmodule
