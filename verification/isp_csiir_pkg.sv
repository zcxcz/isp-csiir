//-----------------------------------------------------------------------------
// Package: isp_csiir_pkg
// Description: UVM package for ISP-CSIIR verification
//-----------------------------------------------------------------------------

package isp_csiir_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // Parameters
    localparam int DATA_WIDTH = 8;
    localparam int MAX_WIDTH  = 1920;
    localparam int MAX_HEIGHT = 1080;

    // Typedefs
    typedef enum bit [1:0] {
        BOUNDARY_ZERO,
        BOUNDARY_REPLICATE,
        BOUNDARY_MIRROR
    } boundary_mode_e;

    // Configuration object
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