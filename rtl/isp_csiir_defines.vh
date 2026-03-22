//-----------------------------------------------------------------------------
// Module: isp_csiir_defines
// Purpose: Global definitions for ISP-CSIIR module
// Author: rtl-impl
// Date: 2026-03-22
// Version: v1.0
//-----------------------------------------------------------------------------

`ifndef ISP_CSIIR_DEFINES_VH
`define ISP_CSIIR_DEFINES_VH

//=============================================================================
// Data Width Definitions
//=============================================================================
`define DATA_WIDTH        10     // Input/Output pixel width
`define GRAD_WIDTH        14     // Gradient width
`define ACC_WIDTH         20     // Accumulator width
`define BLEND_SUM_WIDTH   26     // Blend sum width
`define WIN_SIZE_WIDTH    6      // Window size width

//=============================================================================
// Image Dimensions (8K max)
//=============================================================================
`define IMG_WIDTH         5472   // Maximum image width
`define IMG_HEIGHT        3076   // Maximum image height
`define LINE_ADDR_WIDTH   14     // Line address width (log2(IMG_WIDTH))
`define ROW_CNT_WIDTH     13     // Row counter width (log2(IMG_HEIGHT))

//=============================================================================
// Pipeline Depth Definitions
//=============================================================================
`define STAGE1_DEPTH      5      // Stage 1 pipeline depth
`define STAGE2_DEPTH      8      // Stage 2 pipeline depth
`define STAGE3_DEPTH      6      // Stage 3 pipeline depth
`define STAGE4_DEPTH      5      // Stage 4 pipeline depth
`define TOTAL_LATENCY     24     // Total latency from din_valid to dout_valid

//=============================================================================
// Line Buffer Definitions
//=============================================================================
`define PIXEL_LINE_COUNT  5      // Number of pixel line buffers
`define GRAD_LINE_COUNT   2      // Number of gradient line buffers

//=============================================================================
// Configuration Registers Default Values
//=============================================================================
`define WIN_SIZE_THRESH_0  16'd16
`define WIN_SIZE_THRESH_1  16'd24
`define WIN_SIZE_THRESH_2  16'd32
`define WIN_SIZE_THRESH_3  16'd40

`define BLENDING_RATIO_0   8'd32
`define BLENDING_RATIO_1   8'd32
`define BLENDING_RATIO_2   8'd32
`define BLENDING_RATIO_3   8'd32

//=============================================================================
// Kernel Weight Definitions (for Stage 2)
//=============================================================================
// Kernel weights for different window sizes
// Format: {center, up, down, left, right}
`define KERNEL_5X5_WEIGHT_C  4'd5
`define KERNEL_5X5_WEIGHT_U  4'd5
`define KERNEL_5X5_WEIGHT_D  4'd5
`define KERNEL_5X5_WEIGHT_L  4'd5
`define KERNEL_5X5_WEIGHT_R  4'd5

`define KERNEL_7X7_WEIGHT_C  4'd7
`define KERNEL_7X7_WEIGHT_U  4'd7
`define KERNEL_7X7_WEIGHT_D  4'd7
`define KERNEL_7X7_WEIGHT_L  4'd7
`define KERNEL_7X7_WEIGHT_R  4'd7

//=============================================================================
// Timing Definitions
//=============================================================================
`define TARGET_CLK_PERIOD  1.67  // ns (600 MHz)

`endif // ISP_CSIIR_DEFINES_VH