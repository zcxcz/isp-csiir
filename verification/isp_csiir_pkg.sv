//-----------------------------------------------------------------------------
// Package: isp_csiir_pkg
// Description: UVM package for ISP-CSIIR verification
//              Fully parameterized for different resolutions and data widths
//-----------------------------------------------------------------------------

package isp_csiir_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    //=========================================================================
    // Parameters - Default to 8K 10-bit
    //=========================================================================
    // Data width configuration
    localparam int DATA_WIDTH_DEFAULT = 10;         // 10-bit per channel
    localparam int GRAD_WIDTH_DEFAULT = 14;         // Gradient width

    // Image dimensions - Default to 8K
    localparam int MAX_WIDTH_DEFAULT  = 5472;       // 8K width
    localparam int MAX_HEIGHT_DEFAULT = 3076;       // 8K height

    // Current configuration (can be overridden via config object)
    localparam int DATA_WIDTH = DATA_WIDTH_DEFAULT;
    localparam int GRAD_WIDTH = GRAD_WIDTH_DEFAULT;
    localparam int MAX_WIDTH  = MAX_WIDTH_DEFAULT;
    localparam int MAX_HEIGHT = MAX_HEIGHT_DEFAULT;

    // Derived parameters
    localparam int LINE_ADDR_WIDTH = $clog2(MAX_WIDTH) + 1;
    localparam int ROW_CNT_WIDTH   = $clog2(MAX_HEIGHT) + 1;

    //=========================================================================
    // Typedefs
    //=========================================================================
    typedef enum bit [1:0] {
        BOUNDARY_ZERO,
        BOUNDARY_REPLICATE,
        BOUNDARY_MIRROR
    } boundary_mode_e;

    // Resolution configuration enum
    typedef enum int {
        RES_1080P = 0,  // 1920x1080
        RES_4K    = 1,  // 3840x2160
        RES_8K    = 2   // 5472x3076
    } resolution_e;

    //=========================================================================
    // Configuration object
    //=========================================================================
    `include "isp_csiir_config.svh"

    // Sequence items
    `include "isp_csiir_pixel_item.svh"
    `include "isp_csiir_reg_item.svh"

    // Sequence library
    `include "isp_csiir_pixel_sequence.svh"
    `include "isp_csiir_reg_sequence.svh"

    // Agents
    `include "isp_csiir_pixel_driver.svh"
    `include "isp_csiir_pixel_monitor.svh"
    `include "isp_csiir_pixel_agent.svh"

    `include "isp_csiir_reg_driver.svh"
    `include "isp_csiir_reg_monitor.svh"
    `include "isp_csiir_reg_agent.svh"

    // Reference Model
    `include "isp_csiir_ref_model.svh"

    // Scoreboard
    `include "isp_csiir_scoreboard.svh"

    // Coverage
    `include "isp_csiir_coverage.svh"

    // Environment
    `include "isp_csiir_env.svh"

    // Tests
    `include "isp_csiir_base_test.svh"
    `include "isp_csiir_smoke_test.svh"
    `include "isp_csiir_random_test.svh"
    `include "isp_csiir_video_test.svh"

endpackage : isp_csiir_pkg