//==============================================================================
// ISP-CSIIR Register Definition
//==============================================================================
// All registers with HLS-compatible bit-accurate types
// Used by both HLS top and testbench
//==============================================================================

#ifndef ISP_CSIIR_REGS_HPP
#define ISP_CSIIR_REGS_HPP

#include <ap_fixed.h>
#include <ap_int.h>

//==============================================================================
// Register Group Struct
//==============================================================================
struct ISPCSIIR_Regs {
    // Image dimensions
    ap_uint<16> img_width;
    ap_uint<16> img_height;

    // Window size thresholds [4]
    ap_uint<8> win_thresh0;
    ap_uint<8> win_thresh1;
    ap_uint<8> win_thresh2;
    ap_uint<8> win_thresh3;

    // Gradient clipping [4]
    ap_uint<8> grad_clip0;
    ap_uint<8> grad_clip1;
    ap_uint<8> grad_clip2;
    ap_uint<8> grad_clip3;

    // Blending ratios [4]
    ap_uint<8> blend_ratio0;
    ap_uint<8> blend_ratio1;
    ap_uint<8> blend_ratio2;
    ap_uint<8> blend_ratio3;

    // Edge protection
    ap_uint<8> edge_protect;

    // Initialize with default values
    void reset() {
        img_width = 64;
        img_height = 64;
        win_thresh0 = 100; win_thresh1 = 200; win_thresh2 = 400; win_thresh3 = 800;
        grad_clip0 = 15; grad_clip1 = 23; grad_clip2 = 31; grad_clip3 = 39;
        blend_ratio0 = 32; blend_ratio1 = 32; blend_ratio2 = 32; blend_ratio3 = 32;
        edge_protect = 32;
    }
};

#endif // ISP_CSIIR_REGS_HPP