//-----------------------------------------------------------------------------
// Module: isp_csiir_defines
// Description: Parameter and macro definitions for ISP-CSIIR module
//              Pure Verilog-2001 compatible
//              Supports configurable resolution and data width
//-----------------------------------------------------------------------------

`ifndef ISP_CSIIR_DEFINES_VH
`define ISP_CSIIR_DEFINES_VH

//=============================================================================
// DATA WIDTH CONFIGURATION
//=============================================================================
// Primary data width (pixel bit depth)
// 8 = 8-bit per channel, 10 = 10-bit per channel
`define DATA_WIDTH_DEFAULT       10

// Gradient width (should be DATA_WIDTH + 2 for safe margin)
`define GRAD_WIDTH_DEFAULT       14

// Window size width (bits for window size parameter)
`define WIN_SIZE_WIDTH           6

// Accumulator width (for weighted sums, should be DATA_WIDTH + 8 minimum)
`define ACC_WIDTH_DEFAULT        20

// Division result width
`define DIV_RESULT_WIDTH_DEFAULT 16

//=============================================================================
// IMAGE DIMENSION CONFIGURATION
//=============================================================================
// Default maximum resolution (8K = 5472 x 3076)
// These are used for memory sizing and address width calculation
`define MAX_WIDTH_DEFAULT        5472
`define MAX_HEIGHT_DEFAULT       3076

// Address width calculation: log2(MAX_WIDTH) + 1 for safety
`define LINE_ADDR_WIDTH_DEFAULT  14   // ceil(log2(5472)) = 13, +1 = 14

//=============================================================================
// COLOR SPACE CONFIGURATION
//=============================================================================
// Number of color channels (1 = Y only, 2 = UV interleaved, 3 = YUV separate)
`define NUM_CHANNELS_DEFAULT     3

// Channel indices
`define CH_Y   0
`define CH_U   1
`define CH_V   2

//=============================================================================
// WINDOW PARAMETERS
//=============================================================================
`define WINDOW_SIZE    5
`define WINDOW_CENTER  2

//=============================================================================
// PIPELINE STAGE LATENCIES
//=============================================================================
`define STAGE1_CYCLES  4
`define STAGE2_CYCLES  6
`define STAGE3_CYCLES  4
`define STAGE4_CYCLES  3
`define TOTAL_PIPELINE_CYCLES  17  // Sum of all stages

//=============================================================================
// REGISTER DEFAULTS
//=============================================================================
`define REG_WIN_SIZE_THRESH0_DEFAULT  16'd16
`define REG_WIN_SIZE_THRESH1_DEFAULT  16'd24
`define REG_WIN_SIZE_THRESH2_DEFAULT  16'd32
`define REG_WIN_SIZE_THRESH3_DEFAULT  16'd40

// Blending ratio defaults (0-64 range)
`define REG_BLEND_RATIO_DEFAULT       8'd32

// Window size clip Y defaults
`define REG_WIN_CLIP_Y_0_DEFAULT      10'd15
`define REG_WIN_CLIP_Y_1_DEFAULT      10'd23
`define REG_WIN_CLIP_Y_2_DEFAULT      10'd31
`define REG_WIN_CLIP_Y_3_DEFAULT      10'd39

// Window size clip shift defaults
`define REG_WIN_CLIP_SFT_DEFAULT      8'd2

//=============================================================================
// REGISTER BLOCK CONFIGURATION
//=============================================================================
`define REG_BLOCK_WIDTH  160

//=============================================================================
// DIRECTION INDICES
//=============================================================================
`define DIR_C  0
`define DIR_U  1
`define DIR_D  2
`define DIR_L  3
`define DIR_R  4
`define NUM_DIRS  5

//=============================================================================
// RESOURCE ESTIMATION MACROS (for synthesis guidance)
//=============================================================================
// Line buffer size in bits: 4 lines * MAX_WIDTH * DATA_WIDTH * NUM_CHANNELS
// For 8K 10-bit YUV: 4 * 5472 * 10 * 3 = 656,640 bits = ~82 KB

// Gradient calculation DSP usage estimate
`define GRAD_DSP_PER_CHANNEL  0   // Uses LUT-based adders

// Stage 2 multiplier count (5 directions * 2 scales = 10, but shared)
`define STAGE2_MULTIPLIER_COUNT  25

//=============================================================================
// HELPER MACROS
//=============================================================================
// Ceiling of log2 (for address width calculation)
`define CEIL_LOG2(n) \
    ((n) <= 1) ? 1 : \
    ((n) <= 2) ? 1 : \
    ((n) <= 4) ? 2 : \
    ((n) <= 8) ? 3 : \
    ((n) <= 16) ? 4 : \
    ((n) <= 32) ? 5 : \
    ((n) <= 64) ? 6 : \
    ((n) <= 128) ? 7 : \
    ((n) <= 256) ? 8 : \
    ((n) <= 512) ? 9 : \
    ((n) <= 1024) ? 10 : \
    ((n) <= 2048) ? 11 : \
    ((n) <= 4096) ? 12 : \
    ((n) <= 8192) ? 13 : 14

`endif // ISP_CSIIR_DEFINES_VH