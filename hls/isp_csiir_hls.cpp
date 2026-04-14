//==============================================================================
// ISP-CSIIR HLS Model - High-Level Synthesis Reference Model
// Aligns with isp_csiir_fixed_model.py fixed-point semantics
//==============================================================================

#ifndef ISP_CSIIR_HLS_HPP
#define ISP_CSIIR_HLS_HPP

#include <ap_fixed.h>
#include <hls_stream.h>
#include <cstring>
#include <cmath>

namespace hls_isp_csiir {

//==============================================================================
// Type Definitions - Fixed-Point Precision
//==============================================================================
static const int DATA_WIDTH_I = 10;
static const int GRAD_WIDTH_I = 14;
static const int ACC_WIDTH_I = 20;
static const int SIGNED_WIDTH_I = 11;

// Input/Output: 10-bit unsigned
typedef ap_uint<DATA_WIDTH_I> pixel_t;

// Internal signed format for stages 2-4 (zero-point = 512)
typedef ap_int<SIGNED_WIDTH_I> s11_t;

// Gradient magnitude
typedef ap_uint<GRAD_WIDTH_I> grad_t;

// Accumulator width for weighted sums
typedef ap_int<ACC_WIDTH_I> acc_t;

// 5x5 Patch: packed as 25 pixels
static const int PATCH_PIXELS = 25;
typedef pixel_t patch_5x5_t[PATCH_PIXELS];

//==============================================================================
// Configuration
//==============================================================================
struct Config {
    int img_width;
    int img_height;
    int win_size_thresh[4];
    int win_size_clip_y[4];
    int win_size_clip_sft[4];
    int blending_ratio[4];
    int reg_edge_protect;

    Config() {
        img_width = 64;
        img_height = 64;
        win_size_thresh[0] = 100;
        win_size_thresh[1] = 200;
        win_size_thresh[2] = 400;
        win_size_thresh[3] = 800;
        win_size_clip_y[0] = 15;
        win_size_clip_y[1] = 23;
        win_size_clip_y[2] = 31;
        win_size_clip_y[3] = 39;
        win_size_clip_sft[0] = 2;
        win_size_clip_sft[1] = 2;
        win_size_clip_sft[2] = 2;
        win_size_clip_sft[3] = 2;
        blending_ratio[0] = 32;
        blending_ratio[1] = 32;
        blending_ratio[2] = 32;
        blending_ratio[3] = 32;
        reg_edge_protect = 32;
    }
};

//==============================================================================
// Helper Functions
//==============================================================================

// Round division for positive numbers
inline int round_div_pos(int num, int den) {
    return (num + den / 2) / den;
}

// Round division with sign handling (matches Python _round_div)
inline int round_div(int num, int den) {
    if (den == 0) return 0;
    if (num >= 0) {
        return (num + den / 2) / den;
    } else {
        return - (((-num) + den / 2) / den);
    }
}

// Clip value to range [min_val, max_val]
template<typename T>
inline T clip(T value, int min_val, int max_val) {
    if (value < min_val) return min_val;
    if (value > max_val) return max_val;
    return value;
}

// Clip to u10 range [0, 1023]
inline pixel_t clip_u10(int value) {
    return clip<pixel_t>(value, 0, 1023);
}

// u10 to s11 conversion (zero-point = 512)
inline s11_t u10_to_s11(pixel_t value) {
    return (s11_t)value - 512;
}

// s11 to u10 conversion
inline pixel_t s11_to_u10(s11_t value) {
    return clip_u10((int)value + 512);
}

// Saturate s11 to range [-512, 511]
inline s11_t saturate_s11(s11_t value) {
    return clip<s11_t>(value, -512, 511);
}

// Clip window size to [16, 40]
inline int clip_win_size(int win_size) {
    return clip(win_size, 16, 40);
}

//==============================================================================
// Sobel Gradient Kernels (5x5)
//==============================================================================
// SOBEL_X: [[1,1,1,1,1], [0,0,0,0,0], [0,0,0,0,0], [0,0,0,0,0], [-1,-1,-1,-1,-1]]
// SOBEL_Y: [[1,0,0,0,-1], [1,0,0,0,-1], [1,0,0,0,-1], [1,0,0,0,-1], [1,0,0,0,-1]]

inline void sobel_gradient_5x5(const pixel_t window[PATCH_PIXELS],
                                grad_t& grad_h, grad_t& grad_v, grad_t& grad) {
    // Window layout: row-major, window[row][col] = window[row*5 + col]
    // Row 0: window[0] to window[4]
    // Row 1: window[5] to window[9]
    // ...
    // Row 4: window[20] to window[24]

    int sum_h = 0;
    int sum_v = 0;

    // SOBEL_X: top row (row 0) contributes +1, bottom row (row 4) contributes -1
    // Row 0: all 5 elements are +1
    sum_h += window[0] + window[1] + window[2] + window[3] + window[4];
    // Row 4: all 5 elements are -1
    sum_h -= window[20] + window[21] + window[22] + window[23] + window[24];

    // SOBEL_Y: left column contributes +1, right column contributes -1
    // Left column (col 0): rows 0,1,2,3,4
    sum_v += window[0] + window[5] + window[10] + window[15] + window[20];
    // Right column (col 4): rows 0,1,2,3,4
    sum_v -= window[4] + window[9] + window[14] + window[19] + window[24];

    grad_h = (grad_t)abs(sum_h);
    grad_v = (grad_t)abs(sum_v);
    grad = (grad_t)(round_div_pos(grad_h, 5) + round_div_pos(grad_v, 5));
}

//==============================================================================
// Window Size LUT
//==============================================================================
inline int lut_x_nodes(const Config& cfg) {
    int acc = 0;
    for (int i = 0; i < 4; i++) {
        acc += (1 << cfg.win_size_clip_sft[i]);
    }
    return acc;
}

inline int lut_win_size(const Config& cfg, int grad_triplet_max) {
    int x_nodes[4];
    int acc = 0;
    for (int i = 0; i < 4; i++) {
        acc += (1 << cfg.win_size_clip_sft[i]);
        x_nodes[i] = acc;
    }

    int x = grad_triplet_max;
    int y0 = cfg.win_size_clip_y[0];
    int y1 = cfg.win_size_clip_y[3];

    if (x <= x_nodes[0]) {
        return clip_win_size(y0);
    } else if (x >= x_nodes[3]) {
        return clip_win_size(y1);
    } else {
        int win_size = y1;
        for (int idx = 0; idx < 3; idx++) {
            if (x_nodes[idx] <= x && x <= x_nodes[idx + 1]) {
                int x0 = x_nodes[idx];
                int x1 = x_nodes[idx + 1];
                int y0_i = cfg.win_size_clip_y[idx];
                int y1_i = cfg.win_size_clip_y[idx + 1];
                win_size = y0_i + round_div((x - x0) * (y1_i - y0_i), (x1 - x0));
                break;
            }
        }
        return clip_win_size(win_size);
    }
}

//==============================================================================
// Directional Average Kernels
//==============================================================================
// AVG_FACTOR_C_2X2: center-weighted 2x2 in 5x5
// AVG_FACTOR_C_3X3: center-weighted 3x3 in 5x5
// AVG_FACTOR_C_4X4: center-weighted 4x4 in 5x5
// AVG_FACTOR_C_5X5: all ones

// Masks for directional average (U/D/L/R)
enum DirMask { DIR_C, DIR_U, DIR_D, DIR_L, DIR_R };

// Kernel selection based on window size
// Returns kernel_type: 0=zeros/2x2, 1=3x3/2x2, 2=4x4/3x3, 3=5x5/4x4, 4=5x5/zeros
inline int select_kernel_type(const Config& cfg, int win_size) {
    if (win_size < cfg.win_size_thresh[0]) return 0;
    if (win_size < cfg.win_size_thresh[1]) return 1;
    if (win_size < cfg.win_size_thresh[2]) return 2;
    if (win_size < cfg.win_size_thresh[3]) return 3;
    return 4;
}

// Compute weighted average on s11 patch for a given kernel
inline s11_t weighted_avg_s11(const s11_t patch_s11[PATCH_PIXELS],
                               const int kernel[PATCH_PIXELS]) {
    acc_t total = 0;
    int weight = 0;
    for (int i = 0; i < PATCH_PIXELS; i++) {
        if (kernel[i] != 0) {
            total += (acc_t)patch_s11[i] * kernel[i];
            weight += kernel[i];
        }
    }
    if (weight == 0) return 0;
    return saturate_s11(round_div((int)total, weight));
}

// 5x5 directional average results
struct DirAvgResult {
    s11_t avg0_c, avg0_u, avg0_d, avg0_l, avg0_r;  // Primary path
    s11_t avg1_c, avg1_u, avg1_d, avg1_l, avg1_r;  // Secondary path
    bool avg0_enable;
    bool avg1_enable;
};

// Build directional average result
inline DirAvgResult compute_directional_avg(const Config& cfg,
                                             const s11_t patch_s11[PATCH_PIXELS],
                                             int win_size) {
    DirAvgResult result;

    // Select kernels based on window size
    int kt = select_kernel_type(cfg, win_size);

    // Define kernels inline based on kernel type
    int kernel_2x2[PATCH_PIXELS] = {
        0, 0, 0, 0, 0,
        0, 1, 2, 1, 0,
        0, 2, 4, 2, 0,
        0, 1, 2, 1, 0,
        0, 0, 0, 0, 0
    };

    int kernel_3x3[PATCH_PIXELS] = {
        0, 0, 0, 0, 0,
        0, 1, 1, 1, 0,
        0, 1, 1, 1, 0,
        0, 1, 1, 1, 0,
        0, 0, 0, 0, 0
    };

    int kernel_4x4[PATCH_PIXELS] = {
        1, 1, 2, 1, 1,
        1, 2, 4, 2, 1,
        2, 4, 8, 4, 2,
        1, 2, 4, 2, 1,
        1, 1, 2, 1, 1
    };

    int kernel_5x5[PATCH_PIXELS] = {
        1, 1, 1, 1, 1,
        1, 1, 1, 1, 1,
        1, 1, 1, 1, 1,
        1, 1, 1, 1, 1,
        1, 1, 1, 1, 1
    };

    int kernel_avg0[PATCH_PIXELS];
    int kernel_avg1[PATCH_PIXELS];
    int zero_kernel[PATCH_PIXELS] = {0};

    // Select based on kernel type
    switch (kt) {
        case 0: // zeros / 2x2
            memcpy(kernel_avg0, zero_kernel, sizeof(zero_kernel));
            memcpy(kernel_avg1, kernel_2x2, sizeof(kernel_2x2));
            result.avg0_enable = false;
            result.avg1_enable = true;
            break;
        case 1: // 3x3 / 2x2
            memcpy(kernel_avg0, kernel_3x3, sizeof(kernel_3x3));
            memcpy(kernel_avg1, kernel_2x2, sizeof(kernel_2x2));
            result.avg0_enable = true;
            result.avg1_enable = true;
            break;
        case 2: // 4x4 / 3x3
            memcpy(kernel_avg0, kernel_4x4, sizeof(kernel_4x4));
            memcpy(kernel_avg1, kernel_3x3, sizeof(kernel_3x3));
            result.avg0_enable = true;
            result.avg1_enable = true;
            break;
        case 3: // 5x5 / 4x4
            memcpy(kernel_avg0, kernel_5x5, sizeof(kernel_5x5));
            memcpy(kernel_avg1, kernel_4x4, sizeof(kernel_4x4));
            result.avg0_enable = true;
            result.avg1_enable = true;
            break;
        case 4: // 5x5 / zeros
        default:
            memcpy(kernel_avg0, kernel_5x5, sizeof(kernel_5x5));
            memcpy(kernel_avg1, zero_kernel, sizeof(zero_kernel));
            result.avg0_enable = true;
            result.avg1_enable = false;
            break;
    }

    // Direction masks
    int mask_c[PATCH_PIXELS];  // Center
    int mask_u[PATCH_PIXELS];  // Up
    int mask_d[PATCH_PIXELS];  // Down
    int mask_l[PATCH_PIXELS];  // Left
    int mask_r[PATCH_PIXELS];  // Right

    // Center mask = 1 for all
    for (int i = 0; i < PATCH_PIXELS; i++) mask_c[i] = 1;

    // Up mask: rows 0,1,2 (top half)
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 5; c++)
            mask_u[r*5 + c] = 1;
    for (int r = 3; r < 5; r++)
        for (int c = 0; c < 5; c++)
            mask_u[r*5 + c] = 0;

    // Down mask: rows 2,3,4 (bottom half)
    for (int r = 0; r < 2; r++)
        for (int c = 0; c < 5; c++)
            mask_d[r*5 + c] = 0;
    for (int r = 2; r < 5; r++)
        for (int c = 0; c < 5; c++)
            mask_d[r*5 + c] = 1;

    // Left mask: cols 0,1,2 (left half)
    for (int r = 0; r < 5; r++)
        for (int c = 0; c < 3; c++)
            mask_l[r*5 + c] = 1;
    for (int r = 0; r < 5; r++)
        for (int c = 3; c < 5; c++)
            mask_l[r*5 + c] = 0;

    // Right mask: cols 2,3,4 (right half)
    for (int r = 0; r < 5; r++)
        for (int c = 0; c < 2; c++)
            mask_r[r*5 + c] = 0;
    for (int r = 0; r < 5; r++)
        for (int c = 2; c < 5; c++)
            mask_r[r*5 + c] = 1;

    // Compute masked kernels
    int masked_kernel_avg0_c[PATCH_PIXELS];
    int masked_kernel_avg0_u[PATCH_PIXELS];
    int masked_kernel_avg0_d[PATCH_PIXELS];
    int masked_kernel_avg0_l[PATCH_PIXELS];
    int masked_kernel_avg0_r[PATCH_PIXELS];

    int masked_kernel_avg1_c[PATCH_PIXELS];
    int masked_kernel_avg1_u[PATCH_PIXELS];
    int masked_kernel_avg1_d[PATCH_PIXELS];
    int masked_kernel_avg1_l[PATCH_PIXELS];
    int masked_kernel_avg1_r[PATCH_PIXELS];

    for (int i = 0; i < PATCH_PIXELS; i++) {
        masked_kernel_avg0_c[i] = kernel_avg0[i] * mask_c[i];
        masked_kernel_avg0_u[i] = kernel_avg0[i] * mask_u[i];
        masked_kernel_avg0_d[i] = kernel_avg0[i] * mask_d[i];
        masked_kernel_avg0_l[i] = kernel_avg0[i] * mask_l[i];
        masked_kernel_avg0_r[i] = kernel_avg0[i] * mask_r[i];

        masked_kernel_avg1_c[i] = kernel_avg1[i] * mask_c[i];
        masked_kernel_avg1_u[i] = kernel_avg1[i] * mask_u[i];
        masked_kernel_avg1_d[i] = kernel_avg1[i] * mask_d[i];
        masked_kernel_avg1_l[i] = kernel_avg1[i] * mask_l[i];
        masked_kernel_avg1_r[i] = kernel_avg1[i] * mask_r[i];
    }

    // Compute averages
    if (result.avg0_enable) {
        result.avg0_c = weighted_avg_s11(patch_s11, masked_kernel_avg0_c);
        result.avg0_u = weighted_avg_s11(patch_s11, masked_kernel_avg0_u);
        result.avg0_d = weighted_avg_s11(patch_s11, masked_kernel_avg0_d);
        result.avg0_l = weighted_avg_s11(patch_s11, masked_kernel_avg0_l);
        result.avg0_r = weighted_avg_s11(patch_s11, masked_kernel_avg0_r);
    } else {
        result.avg0_c = result.avg0_u = result.avg0_d = result.avg0_l = result.avg0_r = 0;
    }

    if (result.avg1_enable) {
        result.avg1_c = weighted_avg_s11(patch_s11, masked_kernel_avg1_c);
        result.avg1_u = weighted_avg_s11(patch_s11, masked_kernel_avg1_u);
        result.avg1_d = weighted_avg_s11(patch_s11, masked_kernel_avg1_d);
        result.avg1_l = weighted_avg_s11(patch_s11, masked_kernel_avg1_l);
        result.avg1_r = weighted_avg_s11(patch_s11, masked_kernel_avg1_r);
    } else {
        result.avg1_c = result.avg1_u = result.avg1_d = result.avg1_l = result.avg1_r = 0;
    }

    return result;
}

//==============================================================================
// Gradient Fusion (Stage 3)
//==============================================================================
struct FusionResult {
    s11_t blend0;
    s11_t blend1;
};

// Gradient inverse remapping
inline void grad_inverse_remap(int grad_u, int grad_d, int grad_l, int grad_r, int grad_c,
                                int grad_inv[5]) {
    // Sort gradients: U, D, L, R, C
    int pairs[5][2] = {
        {0, grad_u},
        {1, grad_d},
        {2, grad_l},
        {3, grad_r},
        {4, grad_c}
    };

    // Bubble sort by gradient (descending)
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4 - i; j++) {
            if (pairs[j][1] < pairs[j+1][1]) {
                int tmp_g = pairs[j][1];
                int tmp_idx = pairs[j][0];
                pairs[j][1] = pairs[j+1][1];
                pairs[j][0] = pairs[j+1][0];
                pairs[j+1][1] = tmp_g;
                pairs[j+1][0] = tmp_idx;
            }
        }
    }

    // Assign inverse weights (smallest gradient -> largest weight)
    // grad_inv[original_index] = sorted[4 - index].gradient
    for (int i = 0; i < 5; i++) {
        int orig_idx = pairs[4 - i][0];
        grad_inv[orig_idx] = pairs[i][1];
    }
}

inline FusionResult compute_gradient_fusion(const DirAvgResult& dir_avg, int win_size,
                                             int grad_u, int grad_d, int grad_l,
                                             int grad_r, int grad_c) {
    FusionResult result;

    // Get grad_inv mapping
    int grad_inv[5];
    grad_inverse_remap(grad_u, grad_d, grad_l, grad_r, grad_c, grad_inv);

    int grad_sum = grad_inv[0] + grad_inv[1] + grad_inv[2] + grad_inv[3] + grad_inv[4];

    // avg0 values: c, u, d, l, r
    int avg0_vals[5] = {
        (int)dir_avg.avg0_c,
        (int)dir_avg.avg0_u,
        (int)dir_avg.avg0_d,
        (int)dir_avg.avg0_l,
        (int)dir_avg.avg0_r
    };

    // avg1 values
    int avg1_vals[5] = {
        (int)dir_avg.avg1_c,
        (int)dir_avg.avg1_u,
        (int)dir_avg.avg1_d,
        (int)dir_avg.avg1_l,
        (int)dir_avg.avg1_r
    };

    // Blend function
    int blend0_total = 0;
    int blend1_total = 0;
    for (int i = 0; i < 5; i++) {
        blend0_total += avg0_vals[i] * grad_inv[i];
        blend1_total += avg1_vals[i] * grad_inv[i];
    }

    if (grad_sum == 0) {
        result.blend0 = saturate_s11(round_div(blend0_total, 5));
        result.blend1 = saturate_s11(round_div(blend1_total, 5));
    } else {
        result.blend0 = saturate_s11(round_div(blend0_total, grad_sum));
        result.blend1 = saturate_s11(round_div(blend1_total, grad_sum));
    }

    return result;
}

//==============================================================================
// Stage 4: IIR Blend
//==============================================================================
struct BlendResult {
    s11_t final_patch[PATCH_PIXELS];
};

// Blend factor selection
inline int get_blend_ratio(const Config& cfg, int win_size) {
    int idx = clip(win_size / 8 - 2, 0, 3);
    return cfg.blending_ratio[idx];
}

// Mix scalar with 5x5 patch
inline void mix_scalar_with_patch(s11_t scalar, const s11_t src_patch[PATCH_PIXELS],
                                   const int factor[PATCH_PIXELS],
                                   s11_t output[PATCH_PIXELS]) {
    for (int i = 0; i < PATCH_PIXELS; i++) {
        int val = round_div((int)scalar * factor[i] + (int)src_patch[i] * (4 - factor[i]), 4);
        output[i] = saturate_s11(val);
    }
}

inline void get_blend_factor_2x2(int factor[PATCH_PIXELS]) {
    // 2x2 blend factors (center-weighted)
    factor[0] = 0;  factor[1] = 0;  factor[2] = 0;  factor[3] = 0;  factor[4] = 0;
    factor[5] = 0;  factor[6] = 1;  factor[7] = 2;  factor[8] = 1;  factor[9] = 0;
    factor[10] = 0; factor[11] = 2; factor[12] = 4; factor[13] = 2; factor[14] = 0;
    factor[15] = 0; factor[16] = 1; factor[17] = 2; factor[18] = 1; factor[19] = 0;
    factor[20] = 0; factor[21] = 0; factor[22] = 0; factor[23] = 0; factor[24] = 0;
}

inline void get_blend_factor_2x2_h(int factor[PATCH_PIXELS]) {
    // Horizontal 2x2 (for vertical gradient)
    factor[0] = 0;  factor[1] = 0;  factor[2] = 0;  factor[3] = 0;  factor[4] = 0;
    factor[5] = 0;  factor[6] = 0;  factor[7] = 1;  factor[8] = 0;  factor[9] = 0;
    factor[10] = 0; factor[11] = 0; factor[12] = 1; factor[13] = 0; factor[14] = 0;
    factor[15] = 0; factor[16] = 0; factor[17] = 1; factor[18] = 0; factor[19] = 0;
    factor[20] = 0; factor[21] = 0; factor[22] = 0; factor[23] = 0; factor[24] = 0;
}

inline void get_blend_factor_2x2_v(int factor[PATCH_PIXELS]) {
    // Vertical 2x2 (for horizontal gradient)
    factor[0] = 0;  factor[1] = 0;  factor[2] = 0;  factor[3] = 0;  factor[4] = 0;
    factor[5] = 0;  factor[6] = 0;  factor[7] = 0;  factor[8] = 0;  factor[9] = 0;
    factor[10] = 0; factor[11] = 1; factor[12] = 1; factor[13] = 1; factor[14] = 0;
    factor[15] = 0; factor[16] = 0; factor[17] = 0; factor[18] = 0; factor[19] = 0;
    factor[20] = 0; factor[21] = 0; factor[22] = 0; factor[23] = 0; factor[24] = 0;
}

inline void get_blend_factor_3x3(int factor[PATCH_PIXELS]) {
    for (int i = 0; i < PATCH_PIXELS; i++) factor[i] = 0;
    // Center 3x3
    for (int r = 1; r < 4; r++)
        for (int c = 1; c < 4; c++)
            factor[r*5 + c] = 1;
}

inline void get_blend_factor_4x4(int factor[PATCH_PIXELS]) {
    // 4x4 center with weights
    factor[0] = 1;  factor[1] = 1;  factor[2] = 2;  factor[3] = 1;  factor[4] = 1;
    factor[5] = 1;  factor[6] = 2;  factor[7] = 4;  factor[8] = 2;  factor[9] = 1;
    factor[10] = 2; factor[11] = 4; factor[12] = 4; factor[13] = 4; factor[14] = 2;
    factor[15] = 1; factor[16] = 2; factor[17] = 4; factor[18] = 2; factor[19] = 1;
    factor[20] = 1; factor[21] = 1;  factor[22] = 2;  factor[23] = 1;  factor[24] = 1;
}

inline void get_blend_factor_5x5(int factor[PATCH_PIXELS]) {
    for (int i = 0; i < PATCH_PIXELS; i++) factor[i] = 4;
}

inline BlendResult compute_iir_blend(const Config& cfg,
                                      const s11_t src_patch[PATCH_PIXELS],
                                      int win_size,
                                      s11_t blend0_grad, s11_t blend1_grad,
                                      s11_t avg0_u, s11_t avg1_u,
                                      int grad_h, int grad_v) {
    BlendResult result;

    int ratio = get_blend_ratio(cfg, win_size);

    // Horizontal blend
    s11_t blend0_hor = saturate_s11(round_div((int)ratio * blend0_grad + (64 - ratio) * avg0_u, 64));
    s11_t blend1_hor = saturate_s11(round_div((int)ratio * blend1_grad + (64 - ratio) * avg1_u, 64));

    // Determine orientation
    bool vertical_dominant = abs(grad_v) > abs(grad_h);

    // Get orientation factor
    int orient_factor[PATCH_PIXELS];
    if (vertical_dominant) {
        get_blend_factor_2x2_v(orient_factor);
    } else {
        get_blend_factor_2x2_h(orient_factor);
    }

    // Get 2x2 blend factor
    int factor_2x2[PATCH_PIXELS];
    get_blend_factor_2x2(factor_2x2);

    // Get other blend factors
    int factor_3x3[PATCH_PIXELS];
    get_blend_factor_3x3(factor_3x3);

    int factor_4x4[PATCH_PIXELS];
    get_blend_factor_4x4(factor_4x4);

    int factor_5x5[PATCH_PIXELS];
    get_blend_factor_5x5(factor_5x5);

    // Compute blend windows based on window size
    s11_t blend0_win[PATCH_PIXELS];
    s11_t blend1_win[PATCH_PIXELS];
    int t0 = cfg.win_size_thresh[0];
    int t1 = cfg.win_size_thresh[1];
    int t2 = cfg.win_size_thresh[2];
    int t3 = cfg.win_size_thresh[3];

    if (win_size < t0) {
        // Small window: use blend1 only with edge protection
        s11_t tmp_blend10[PATCH_PIXELS];
        s11_t tmp_blend11[PATCH_PIXELS];
        mix_scalar_with_patch(blend1_hor, src_patch, orient_factor, tmp_blend10);
        mix_scalar_with_patch(blend1_hor, src_patch, factor_2x2, tmp_blend11);
        for (int i = 0; i < PATCH_PIXELS; i++) {
            int val = round_div((int)tmp_blend10[i] * cfg.reg_edge_protect +
                                 (int)tmp_blend11[i] * (64 - cfg.reg_edge_protect), 64);
            blend1_win[i] = saturate_s11(val);
        }
        // blend0_win is not used
        for (int i = 0; i < PATCH_PIXELS; i++) blend0_win[i] = 0;
    } else if (win_size < t1) {
        // 3x3 window
        s11_t tmp_blend10[PATCH_PIXELS];
        s11_t tmp_blend11[PATCH_PIXELS];
        mix_scalar_with_patch(blend1_hor, src_patch, orient_factor, tmp_blend10);
        mix_scalar_with_patch(blend1_hor, src_patch, factor_2x2, tmp_blend11);
        for (int i = 0; i < PATCH_PIXELS; i++) {
            int val = round_div((int)tmp_blend10[i] * cfg.reg_edge_protect +
                                 (int)tmp_blend11[i] * (64 - cfg.reg_edge_protect), 64);
            blend1_win[i] = saturate_s11(val);
        }
        mix_scalar_with_patch(blend0_hor, src_patch, factor_3x3, blend0_win);
    } else if (win_size < t2) {
        // 4x4 window
        mix_scalar_with_patch(blend1_hor, src_patch, factor_3x3, blend1_win);
        mix_scalar_with_patch(blend0_hor, src_patch, factor_4x4, blend0_win);
    } else if (win_size < t3) {
        // 5x5 window
        mix_scalar_with_patch(blend1_hor, src_patch, factor_4x4, blend1_win);
        mix_scalar_with_patch(blend0_hor, src_patch, factor_5x5, blend0_win);
    } else {
        // Large window: use blend0 only
        mix_scalar_with_patch(blend0_hor, src_patch, factor_5x5, blend0_win);
        for (int i = 0; i < PATCH_PIXELS; i++) blend1_win[i] = 0;
    }

    // Final patch selection
    int remain = win_size % 8;
    if (win_size < t0) {
        for (int i = 0; i < PATCH_PIXELS; i++)
            result.final_patch[i] = blend1_win[i];
    } else if (win_size >= t3) {
        for (int i = 0; i < PATCH_PIXELS; i++)
            result.final_patch[i] = blend0_win[i];
    } else {
        // Interpolate between blend0 and blend1
        for (int i = 0; i < PATCH_PIXELS; i++) {
            int val = round_div((int)blend0_win[i] * remain + (int)blend1_win[i] * (8 - remain), 8);
            result.final_patch[i] = saturate_s11(val);
        }
    }

    return result;
}

//==============================================================================
// Full Processing Functions
//==============================================================================

// Process one pixel through the full pipeline (feed-forward, no feedback)
// Returns the center pixel value of the output patch
inline pixel_t process_pixel(const Config& cfg,
                              const pixel_t window[PATCH_PIXELS]) {
    // Convert to s11
    s11_t patch_s11[PATCH_PIXELS];
    for (int i = 0; i < PATCH_PIXELS; i++) {
        patch_s11[i] = u10_to_s11(window[i]);
    }

    // Stage 1: Gradient
    grad_t grad_h, grad_v, grad;
    sobel_gradient_5x5(window, grad_h, grad_v, grad);

    // Get window size from gradient LUT
    int win_size = lut_win_size(cfg, (int)grad);

    // Stage 2: Directional Average
    DirAvgResult dir_avg = compute_directional_avg(cfg, patch_s11, win_size);

    // For gradient fusion, we need gradients of neighboring patches
    // In feed-forward mode, assume neighbors have same gradient
    grad_t grad_u = grad, grad_d = grad, grad_l = grad, grad_c = grad;

    // Stage 3: Gradient Fusion
    FusionResult fusion = compute_gradient_fusion(dir_avg, win_size,
                                                   (int)grad_u, (int)grad_d,
                                                   (int)grad_l, (int)grad_c,
                                                   (int)grad);

    // Stage 4: IIR Blend
    BlendResult blend = compute_iir_blend(cfg, patch_s11, win_size,
                                           fusion.blend0, fusion.blend1,
                                           dir_avg.avg0_u, dir_avg.avg1_u,
                                           (int)grad_h, (int)grad_v);

    // Return center pixel (index 12 = row 2, col 2)
    return s11_to_u10(blend.final_patch[12]);
}

//==============================================================================
// Stream-based Processing with Feedback
//==============================================================================

// Feedback writeback calculation
inline void feedback_writeback_x(int center_x, int img_width, int writebacks[5], int& num_writebacks) {
    num_writebacks = 0;
    for (int dx = -2; dx <= 2; dx++) {
        int raw_x = center_x + dx * 2;
        if (0 <= raw_x && raw_x < img_width) {
            writebacks[num_writebacks++] = raw_x;
        }
    }
}

inline bool feedback_column_is_safe(int center_x, int raw_x, int img_width) {
    for (int future_x = center_x + 1; future_x <= center_x + 4 && future_x < img_width; future_x++) {
        // Check if future center uses this raw_x
        for (int dx = -2; dx <= 2; dx++) {
            int x = future_x + dx * 2;
            if (x < 0) x = 0;
            if (x >= img_width) x = img_width - 1;
            if (x == raw_x) return false;
        }
    }
    return true;
}

} // namespace hls_isp_csiir

#endif // ISP_CSIIR_HLS_HPP
