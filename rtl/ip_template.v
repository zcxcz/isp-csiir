//////
// description:     summary the function of this ip.
// created date:    record the time of this module created.
// created author:  record the author of this module created.
// last modified:   record the time of this module last modified.
// last author:     record the author of this module last modified.
//////


// module define, make sure the module name is equal to the file name.
module ip_template(
    // using /*autoarg*/ to generate input/output/inout port automatically if emacs-verilog-mode is available.
);

// parameter part.

parameter DATA_WIDTH 8


// port part.

// using /*autoinput*/ if current block is integrate any sub-module, when its input port is not driven by any other signal.
// using /*autooutput*/ if current block is integrate any sub-module, when its output port is not used by any other signal.
// manual declaration for somewhat the emacs-verilog-mode script cannot adopted.
input                       clk;
input                       rst_n;
output                      din_ready;
input                       din_valid;
input [DATA_WIDTH-1:0]      dina;
input [DATA_WIDTH-1:0]      dinb;
input                       dout_ready;
output                      dout_valid;
output [DATA_WIDTH:0]       dout;


// declaration part.

// using /*autowire*/ identify and generate wire signal in this module.
// using /*autowire*/ identify and generate reg signal in this module.
// manual declaration for the following example of the pipeline design.
wire                  din_shake;
wire [DATA_WIDTH-1:0] dina_mask;
wire [DATA_WIDTH-1:0] dinb_mask;
wire [DATA_WIDTH:0] dout_comb;


// logic part, including pipeline design and integration of some function module instances.

// the following mask logic is power optimization if its available.
assign din_shake = din_valid & din_ready;
assign dina_mask = din_shake ? dina : {DATA_WIDTH{1'b0}};
assign dinb_mask = din_shake ? dinb : {DATA_WIDTH{1'b0}};
assign dout_comb = dina_mask + dinb_mask;
// using auto_template to template module if emacs-verilog-mode is available.
// using /*autoinst*/ to instance module if emacs-verilog-mode is available.
/* common_ff auto_template "\(u_ADDER\)" (
    .clk        (clk        ),
    .rst_n      (rst_n      ),
    .din        (din_shake  ),
    .valid_in   (dout_comb  ),
    .ready_out  (din_ready  ),
    .dout       (dout       ),
    .valid_out  (dout_valid ),
    .ready_in   (dout_ready ),
); */
common_ff u_ADDER(/*autoinst*/
    .clk        (clk        ),
    .rst_n      (rst_n      ),
    .din        (din_shake  ),
    .valid_in   (dout_comb  ),
    .ready_out  (din_ready  ),
    .dout       (dout       ),
    .valid_out  (dout_valid ),
    .ready_in   (dout_ready )
);


endmodule