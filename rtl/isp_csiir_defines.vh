//-----------------------------------------------------------------------------
// Module: isp_csiir_defines
// Description: Parameter and macro definitions for ISP-CSIIR module
//              Pure Verilog-2001 compatible
//-----------------------------------------------------------------------------

`ifndef ISP_CSIIR_DEFINES_VH
`define ISP_CSIIR_DEFINES_VH

// Data widths
`define DATA_WIDTH       8
`define GRAD_WIDTH       12
`define WIN_SIZE_WIDTH   6
`define ACC_WIDTH        20
`define DIV_RESULT_WIDTH 12

// Image dimensions (configurable)
`define MAX_WIDTH  1920
`define MAX_HEIGHT 1080

// Window parameters
`define WINDOW_SIZE    5
`define WINDOW_CENTER  2

// Pipeline stage latencies
`define STAGE1_CYCLES  4
`define STAGE2_CYCLES  6
`define STAGE3_CYCLES  4
`define STAGE4_CYCLES  3

// Register defaults
`define REG_WIN_SIZE_THRESH0_DEFAULT  16'd16
`define REG_WIN_SIZE_THRESH1_DEFAULT  16'd24
`define REG_WIN_SIZE_THRESH2_DEFAULT  16'd32
`define REG_WIN_SIZE_THRESH3_DEFAULT  16'd40

// Register block bit width
`define REG_BLOCK_WIDTH  160

// Direction indices
`define DIR_C  0
`define DIR_U  1
`define DIR_D  2
`define DIR_L  3
`define DIR_R  4
`define NUM_DIRS  5

`endif // ISP_CSIIR_DEFINES_VH