//==============================================================================
// ISP-CSIIR HLS Model - Standard C++ Version (No HLS dependencies)
// This version can be compiled with standard g++ for testing
//==============================================================================

#ifndef ISP_CSIIR_HLS_STANDALONE_HPP
#define ISP_CSIIR_HLS_STANDALONE_HPP

#include <cstdint>
#include <algorithm>
#include <cmath>

namespace hls_isp_csiir {

//==============================================================================
// Type Definitions - Using standard C++ types
//==============================================================================
static const int DATA_WIDTH_I = 10;
static const int GRAD_WIDTH_I = 14;
static const int ACC_WIDTH_I = 20;
static const int SIGNED_WIDTH_I = 11;
static const int PATCH_SIZE = 25;

typedef int16_t pixel_t;
typedef int16_t s11_t;
typedef int16_t grad_t;
typedef int32_t acc_t;

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
        win_size_thresh[0] = 16;
        win_size_thresh[1] = 24;
        win_size_thresh[2] = 32;
        win_size_thresh[3] = 40;
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
inline int round_div(int num, int den) {
    if (den == 0) return 0;
    if (num >= 0) return (num + den / 2) / den;
    return - (((-num) + den / 2) / den);
}

template<typename T>
inline T clip(T value, int min_val, int max_val) {
    return std::max(min_val, std::min(max_val, (int)value));
}

inline pixel_t clip_u10(int value) {
    return (pixel_t)clip<int>(value, 0, 1023);
}

inline s11_t u10_to_s11(pixel_t value) {
    return (s11_t)value - 512;
}

inline pixel_t s11_to_u10(s11_t value) {
    return clip_u10((int)value + 512);
}

inline s11_t saturate_s11(s11_t value) {
    return (s11_t)clip<int>(value, -512, 511);
}

inline int clip_win_size(int win_size) {
    return clip<int>(win_size, 16, 40);
}

//==============================================================================
// Sobel Gradient (5x5)
//==============================================================================
inline void sobel_gradient_5x5(const pixel_t window[PATCH_SIZE],
                                grad_t& grad_h, grad_t& grad_v, grad_t& grad) {
    // Row 0 (+1), Row 4 (-1) for horizontal
    int sum_h = window[0] + window[1] + window[2] + window[3] + window[4]
              - window[20] - window[21] - window[22] - window[23] - window[24];

    // Col 0 (+1), Col 4 (-1) for vertical
    int sum_v = window[0] + window[5] + window[10] + window[15] + window[20]
              - window[4] - window[9] - window[14] - window[19] - window[24];

    grad_h = (grad_t)std::abs(sum_h);
    grad_v = (grad_t)std::abs(sum_v);
    grad = (grad_t)clip<int>(round_div(grad_h, 5) + round_div(grad_v, 5), 0, 127);
}

//==============================================================================
// Window Size LUT
//==============================================================================
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

    if (x <= x_nodes[0]) return clip_win_size(y0);
    if (x >= x_nodes[3]) return clip_win_size(y1);

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

//==============================================================================
// Directional Average
//==============================================================================
inline int select_kernel_type(const Config& cfg, int win_size) {
    if (win_size < cfg.win_size_thresh[0]) return 0;
    if (win_size < cfg.win_size_thresh[1]) return 1;
    if (win_size < cfg.win_size_thresh[2]) return 2;
    if (win_size < cfg.win_size_thresh[3]) return 3;
    return 4;
}

inline s11_t weighted_avg(const s11_t patch_s11[PATCH_SIZE], const int* kernel) {
    acc_t total = 0;
    int weight = 0;
    for (int i = 0; i < PATCH_SIZE; i++) {
        if (kernel[i] != 0) {
            total += (acc_t)patch_s11[i] * kernel[i];
            weight += kernel[i];
        }
    }
    if (weight == 0) return 0;
    return saturate_s11(round_div((int)total, weight));
}

struct DirAvgResult {
    s11_t avg0_c, avg0_u, avg0_d, avg0_l, avg0_r;
    s11_t avg1_c, avg1_u, avg1_d, avg1_l, avg1_r;
    bool avg0_enable;
    bool avg1_enable;
};

// 2x2 center and directional kernels
static const int K2X2_C[PATCH_SIZE] = {
    0, 0, 0, 0, 0,
    0, 1, 2, 1, 0,
    0, 2, 4, 2, 0,
    0, 1, 2, 1, 0,
    0, 0, 0, 0, 0
};
static const int K2X2_U[PATCH_SIZE] = {
    0, 0, 0, 0, 0,
    0, 1, 1, 1, 0,
    0, 1, 3, 1, 0,
    0, 0, 0, 0, 0,
    0, 0, 0, 0, 0
};
static const int K2X2_D[PATCH_SIZE] = {
    0, 0, 0, 0, 0,
    0, 0, 0, 0, 0,
    0, 1, 3, 1, 0,
    0, 1, 1, 1, 0,
    0, 0, 0, 0, 0
};
static const int K2X2_L[PATCH_SIZE] = {
    0, 0, 0, 0, 0,
    0, 1, 1, 0, 0,
    0, 1, 3, 0, 0,
    0, 1, 1, 0, 0,
    0, 0, 0, 0, 0
};
static const int K2X2_R[PATCH_SIZE] = {
    0, 0, 0, 0, 0,
    0, 0, 1, 1, 0,
    0, 0, 3, 1, 0,
    0, 0, 1, 1, 0,
    0, 0, 0, 0, 0
};

// 3x3 center and directional kernels
static const int K3X3_C[PATCH_SIZE] = {
    0, 0, 0, 0, 0,
    0, 1, 2, 1, 0,
    0, 2, 4, 2, 0,
    0, 1, 2, 1, 0,
    0, 0, 0, 0, 0
};
static const int K3X3_U[PATCH_SIZE] = {
    0, 0, 0, 0, 0,
    0, 1, 2, 1, 0,
    0, 1, 2, 1, 0,
    0, 0, 0, 0, 0,
    0, 0, 0, 0, 0
};
static const int K3X3_D[PATCH_SIZE] = {
    0, 0, 0, 0, 0,
    0, 0, 0, 0, 0,
    0, 1, 2, 1, 0,
    0, 1, 2, 1, 0,
    0, 0, 0, 0, 0
};
static const int K3X3_L[PATCH_SIZE] = {
    0, 0, 0, 0, 0,
    0, 1, 1, 0, 0,
    0, 2, 2, 0, 0,
    0, 1, 1, 0, 0,
    0, 0, 0, 0, 0
};
static const int K3X3_R[PATCH_SIZE] = {
    0, 0, 0, 0, 0,
    0, 0, 1, 1, 0,
    0, 0, 2, 2, 0,
    0, 0, 1, 1, 0,
    0, 0, 0, 0, 0
};

// 4x4 center and directional kernels
static const int K4X4_C[PATCH_SIZE] = {
    1, 2, 2, 2, 1,
    2, 4, 4, 4, 2,
    2, 4, 4, 4, 2,
    2, 4, 4, 4, 2,
    1, 2, 2, 2, 1
};
static const int K4X4_U[PATCH_SIZE] = {
    1, 2, 2, 2, 1,
    2, 2, 4, 2, 2,
    2, 2, 4, 2, 2,
    0, 0, 0, 0, 0,
    0, 0, 0, 0, 0
};
static const int K4X4_D[PATCH_SIZE] = {
    0, 0, 0, 0, 0,
    0, 0, 0, 0, 0,
    2, 2, 4, 2, 2,
    2, 2, 4, 2, 2,
    1, 2, 2, 2, 1
};
static const int K4X4_L[PATCH_SIZE] = {
    1, 2, 2, 0, 0,
    2, 2, 2, 0, 0,
    2, 4, 4, 0, 0,
    2, 2, 2, 0, 0,
    1, 2, 2, 0, 0
};
static const int K4X4_R[PATCH_SIZE] = {
    0, 0, 2, 2, 1,
    0, 0, 2, 2, 2,
    0, 0, 4, 4, 2,
    0, 0, 2, 2, 2,
    0, 0, 2, 2, 1
};

// 5x5 center and directional kernels
static const int K5X5_C[PATCH_SIZE] = {
    1, 2, 1, 2, 1,
    1, 1, 1, 1, 1,
    2, 1, 2, 1, 2,
    1, 1, 1, 1, 1,
    1, 2, 1, 2, 1
};
static const int K5X5_U[PATCH_SIZE] = {
    1, 1, 1, 1, 1,
    1, 1, 2, 1, 1,
    1, 1, 1, 1, 1,
    0, 0, 0, 0, 0,
    0, 0, 0, 0, 0
};
static const int K5X5_D[PATCH_SIZE] = {
    0, 0, 0, 0, 0,
    0, 0, 0, 0, 0,
    1, 1, 1, 1, 1,
    1, 1, 2, 1, 1,
    1, 1, 1, 1, 1
};
static const int K5X5_L[PATCH_SIZE] = {
    1, 1, 1, 0, 0,
    1, 1, 1, 0, 0,
    1, 2, 1, 0, 0,
    1, 1, 1, 0, 0,
    1, 1, 1, 0, 0
};
static const int K5X5_R[PATCH_SIZE] = {
    0, 0, 1, 1, 1,
    0, 0, 1, 1, 1,
    0, 0, 1, 2, 1,
    0, 0, 1, 1, 1,
    0, 0, 1, 1, 1
};

static const int ZERO[PATCH_SIZE] = {0};

inline DirAvgResult compute_directional_avg(const Config& cfg,
                                             const s11_t patch_s11[PATCH_SIZE],
                                             int win_size) {
    DirAvgResult result = {};
    int kt = select_kernel_type(cfg, win_size);

    const int* k0_c, *k0_u, *k0_d, *k0_l, *k0_r;
    const int* k1_c, *k1_u, *k1_d, *k1_l, *k1_r;
    bool avg0_en, avg1_en;

    switch (kt) {
        case 0:
            k0_c = ZERO; k0_u = ZERO; k0_d = ZERO; k0_l = ZERO; k0_r = ZERO;
            k1_c = K2X2_C; k1_u = K2X2_U; k1_d = K2X2_D; k1_l = K2X2_L; k1_r = K2X2_R;
            avg0_en = false; avg1_en = true;
            break;
        case 1:
            k0_c = K2X2_C; k0_u = K2X2_U; k0_d = K2X2_D; k0_l = K2X2_L; k0_r = K2X2_R;
            k1_c = K3X3_C; k1_u = K3X3_U; k1_d = K3X3_D; k1_l = K3X3_L; k1_r = K3X3_R;
            avg0_en = true; avg1_en = true;
            break;
        case 2:
            k0_c = K3X3_C; k0_u = K3X3_U; k0_d = K3X3_D; k0_l = K3X3_L; k0_r = K3X3_R;
            k1_c = K4X4_C; k1_u = K4X4_U; k1_d = K4X4_D; k1_l = K4X4_L; k1_r = K4X4_R;
            avg0_en = true; avg1_en = true;
            break;
        case 3:
            k0_c = K4X4_C; k0_u = K4X4_U; k0_d = K4X4_D; k0_l = K4X4_L; k0_r = K4X4_R;
            k1_c = K5X5_C; k1_u = K5X5_U; k1_d = K5X5_D; k1_l = K5X5_L; k1_r = K5X5_R;
            avg0_en = true; avg1_en = true;
            break;
        default:
            k0_c = K5X5_C; k0_u = K5X5_U; k0_d = K5X5_D; k0_l = K5X5_L; k0_r = K5X5_R;
            k1_c = ZERO; k1_u = ZERO; k1_d = ZERO; k1_l = ZERO; k1_r = ZERO;
            avg0_en = true; avg1_en = false;
            break;
    }

    result.avg0_enable = avg0_en;
    result.avg1_enable = avg1_en;

    result.avg0_c = weighted_avg(patch_s11, k0_c);
    result.avg0_u = weighted_avg(patch_s11, k0_u);
    result.avg0_d = weighted_avg(patch_s11, k0_d);
    result.avg0_l = weighted_avg(patch_s11, k0_l);
    result.avg0_r = weighted_avg(patch_s11, k0_r);

    result.avg1_c = weighted_avg(patch_s11, k1_c);
    result.avg1_u = weighted_avg(patch_s11, k1_u);
    result.avg1_d = weighted_avg(patch_s11, k1_d);
    result.avg1_l = weighted_avg(patch_s11, k1_l);
    result.avg1_r = weighted_avg(patch_s11, k1_r);

    return result;
}

//==============================================================================
// Gradient Fusion (Min-tracking algorithm per ref)
//==============================================================================
struct FusionResult {
    s11_t blend0;
    s11_t blend1;
};

inline FusionResult compute_gradient_fusion(const DirAvgResult& dir_avg,
                                           int grad_u, int grad_d,
                                           int grad_l, int grad_r, int grad_c) {
    FusionResult result;
    // Order: u(0), d(1), l(2), r(3), c(4)
    int g[5] = {grad_u, grad_d, grad_l, grad_r, grad_c};
    int v0[5] = {(int)dir_avg.avg0_u, (int)dir_avg.avg0_d, (int)dir_avg.avg0_l,
                 (int)dir_avg.avg0_r, (int)dir_avg.avg0_c};
    int v1[5] = {(int)dir_avg.avg1_u, (int)dir_avg.avg1_d, (int)dir_avg.avg1_l,
                 (int)dir_avg.avg1_r, (int)dir_avg.avg1_c};

    // min0 tracking
    int min0_grad = 2048;
    int min0_grad_avg = 0;
    if (g[0] <= min0_grad) {
        min0_grad = g[0];
        min0_grad_avg = v0[0];
    }
    if (g[2] <= min0_grad) {
        min0_grad = g[2];
        min0_grad_avg = round_div(v0[2] + min0_grad_avg + 1, 2);
    }
    if (g[4] <= min0_grad) {
        min0_grad = g[4];
        min0_grad_avg = round_div(v0[4] + min0_grad_avg + 1, 2);
    }
    if (g[3] <= min0_grad) {
        min0_grad = g[3];
        min0_grad_avg = round_div(v0[3] + min0_grad_avg + 1, 2);
    }
    if (g[1] <= min0_grad) {
        min0_grad = g[1];
        min0_grad_avg = round_div(v0[1] + min0_grad_avg + 1, 2);
    }

    // min1 tracking
    int min1_grad = 2048;
    int min1_grad_avg = 0;
    if (g[0] <= min1_grad) {
        min1_grad = g[0];
        min1_grad_avg = v1[0];
    }
    if (g[2] <= min1_grad) {
        min1_grad = g[2];
        min1_grad_avg = round_div(v1[2] + min1_grad_avg + 1, 2);
    }
    if (g[4] <= min1_grad) {
        min1_grad = g[4];
        min1_grad_avg = round_div(v1[4] + min1_grad_avg + 1, 2);
    }
    if (g[3] <= min1_grad) {
        min1_grad = g[3];
        min1_grad_avg = round_div(v1[3] + min1_grad_avg + 1, 2);
    }
    if (g[1] <= min1_grad) {
        min1_grad = g[1];
        min1_grad_avg = round_div(v1[1] + min1_grad_avg + 1, 2);
    }

    result.blend0 = saturate_s11(min0_grad_avg);
    result.blend1 = saturate_s11(min1_grad_avg);
    return result;
}

//==============================================================================
// Stage 4: IIR Blend
//==============================================================================
inline int get_ratio(const Config& cfg, int win_size) {
    int idx = clip<int>(win_size / 8 - 2, 0, 3);
    return cfg.blending_ratio[idx];
}

inline void mix_scalar(s11_t scalar, const s11_t src[PATCH_SIZE],
                       const int factor[PATCH_SIZE], s11_t out[PATCH_SIZE]) {
    for (int i = 0; i < PATCH_SIZE; i++) {
        int val = round_div((int)scalar * factor[i] + (int)src[i] * (4 - factor[i]), 4);
        out[i] = saturate_s11(val);
    }
}

// Blend factors (per ref section 5.2)
static const int F2X2[PATCH_SIZE] = {0,0,0,0,0,0,1,2,1,0,0,2,4,2,0,0,1,2,1,0,0,0,0,0,0};
static const int F3X3[PATCH_SIZE] = {0,0,0,0,0,0,1,1,1,0,0,1,1,1,0,0,1,1,1,0,0,0,0,0,0};
// 4x4 per ref: center is 4, not 8
static const int F4X4[PATCH_SIZE] = {1,2,2,2,1,2,4,4,4,2,2,4,4,4,2,2,4,4,4,2,1,2,2,2,1};
// 5x5 per ref: all 4s
static const int F5X5[PATCH_SIZE] = {4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4};
static const int F_ORI_V[PATCH_SIZE] = {0,0,0,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,0,0,0};
static const int F_ORI_H[PATCH_SIZE] = {0,0,0,0,0,0,0,0,0,0,0,1,1,1,0,0,0,0,0,0,0,0,0,0,0};

inline void compute_iir_blend(const Config& cfg, const s11_t src[PATCH_SIZE],
                              int win_size, s11_t blend0_g, s11_t blend1_g,
                              s11_t avg0_u, s11_t avg1_u,
                              int grad_h, int grad_v,
                              s11_t final_patch[PATCH_SIZE]) {
    int ratio = get_ratio(cfg, win_size);

    s11_t b0_hor = saturate_s11(round_div((int)ratio * blend0_g + (64 - ratio) * avg0_u, 64));
    s11_t b1_hor = saturate_s11(round_div((int)ratio * blend1_g + (64 - ratio) * avg1_u, 64));

    // G_H = |grad_v|, G_V = |grad_h| per ref
    // If G_H > G_V (grad_v dominates), use vertical orientation
    bool vert_dom = std::abs(grad_v) > std::abs(grad_h);
    const int* f_orient = vert_dom ? F_ORI_V : F_ORI_H;

    s11_t blend0_win[PATCH_SIZE], blend1_win[PATCH_SIZE];
    int t0 = cfg.win_size_thresh[0];
    int t1 = cfg.win_size_thresh[1];
    int t2 = cfg.win_size_thresh[2];
    int t3 = cfg.win_size_thresh[3];

    (void)win_size;  // suppress unused warning

    if (win_size < t0) {
        s11_t tmp1[PATCH_SIZE], tmp2[PATCH_SIZE];
        mix_scalar(b1_hor, src, f_orient, tmp1);
        mix_scalar(b1_hor, src, F2X2, tmp2);
        for (int i = 0; i < PATCH_SIZE; i++) {
            int val = round_div((int)tmp1[i] * cfg.reg_edge_protect + (int)tmp2[i] * (64 - cfg.reg_edge_protect), 64);
            blend1_win[i] = saturate_s11(val);
        }
        for (int i = 0; i < PATCH_SIZE; i++) blend0_win[i] = 0;
    } else if (win_size < t1) {
        s11_t tmp1[PATCH_SIZE], tmp2[PATCH_SIZE];
        mix_scalar(b1_hor, src, f_orient, tmp1);
        mix_scalar(b1_hor, src, F2X2, tmp2);
        for (int i = 0; i < PATCH_SIZE; i++) {
            int val = round_div((int)tmp1[i] * cfg.reg_edge_protect + (int)tmp2[i] * (64 - cfg.reg_edge_protect), 64);
            blend1_win[i] = saturate_s11(val);
        }
        mix_scalar(b0_hor, src, F3X3, blend0_win);
    } else if (win_size < t2) {
        mix_scalar(b1_hor, src, F3X3, blend1_win);
        mix_scalar(b0_hor, src, F4X4, blend0_win);
    } else if (win_size < t3) {
        mix_scalar(b1_hor, src, F4X4, blend1_win);
        mix_scalar(b0_hor, src, F5X5, blend0_win);
    } else {
        mix_scalar(b0_hor, src, F5X5, blend0_win);
        for (int i = 0; i < PATCH_SIZE; i++) blend1_win[i] = 0;
    }

    int remain = win_size % 8;
    if (win_size < t0) {
        for (int i = 0; i < PATCH_SIZE; i++) final_patch[i] = blend1_win[i];
    } else if (win_size >= t3) {
        for (int i = 0; i < PATCH_SIZE; i++) final_patch[i] = blend0_win[i];
    } else {
        for (int i = 0; i < PATCH_SIZE; i++) {
            int val = round_div((int)blend0_win[i] * remain + (int)blend1_win[i] * (8 - remain), 8);
            final_patch[i] = saturate_s11(val);
        }
    }
}

//==============================================================================
// Full Processing - computes gradients at left, center, right positions
//==============================================================================
inline void sobel_gradient_at(const pixel_t img[], int img_w, int img_h,
                              int center_i, int center_j,
                              grad_t& grad_out) {
    // Compute Sobel gradient at a specific position using sparse window
    // Returns grad = grad_h/5 + grad_v/5
    pixel_t window[PATCH_SIZE];
    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            int row = std::max(0, std::min(img_h - 1, center_j + dy));
            int col = std::max(0, std::min(img_w - 1, center_i + dx * 2));
            window[(dy + 2) * 5 + (dx + 2)] = img[row * img_w + col];
        }
    }
    grad_t gh, gv, g;
    sobel_gradient_5x5(window, gh, gv, g);
    grad_out = g;
}

inline pixel_t process_pixel_at(const Config& cfg, const pixel_t img[],
                                int img_w, int img_h,
                                int center_i, int center_j) {
    // Build center window with sparse sampling
    pixel_t window[PATCH_SIZE];
    for (int dy = -2; dy <= 2; dy++) {
        for (int dx = -2; dx <= 2; dx++) {
            int row = std::max(0, std::min(img_h - 1, center_j + dy));
            int col = std::max(0, std::min(img_w - 1, center_i + dx * 2));
            window[(dy + 2) * 5 + (dx + 2)] = img[row * img_w + col];
        }
    }

    s11_t patch_s11[PATCH_SIZE];
    for (int i = 0; i < PATCH_SIZE; i++) patch_s11[i] = u10_to_s11(window[i]);

    grad_t grad_h, grad_v, grad_c;
    sobel_gradient_5x5(window, grad_h, grad_v, grad_c);

    // Compute left and right gradients for LUT (using max per Python algorithm)
    grad_t grad_l, grad_r;
    int left_i = std::max(0, std::min(img_w - 1, center_i - 2));
    int right_i = std::max(0, std::min(img_w - 1, center_i + 2));
    sobel_gradient_at(img, img_w, img_h, left_i, center_j, grad_l);
    sobel_gradient_at(img, img_w, img_h, right_i, center_j, grad_r);

    int win_size = lut_win_size(cfg, std::max(grad_l, std::max(grad_c, grad_r)));

    DirAvgResult dir_avg = compute_directional_avg(cfg, patch_s11, win_size);

    // Neighbors for fusion
    grad_t grad_u, grad_d;
    int up_j = std::max(0, std::min(img_h - 1, center_j - 1));
    int down_j = std::max(0, std::min(img_h - 1, center_j + 1));
    sobel_gradient_at(img, img_w, img_h, center_i, up_j, grad_u);
    sobel_gradient_at(img, img_w, img_h, center_i, down_j, grad_d);

    FusionResult fusion = compute_gradient_fusion(dir_avg, (int)grad_u, (int)grad_d,
                                                  (int)grad_l, (int)grad_r, (int)grad_c);

    s11_t final_patch[PATCH_SIZE];
    compute_iir_blend(cfg, patch_s11, win_size, fusion.blend0, fusion.blend1,
                      dir_avg.avg0_u, dir_avg.avg1_u, (int)grad_h, (int)grad_v, final_patch);

    return s11_to_u10(final_patch[12]);  // Center pixel (row 2, col 2)
}

} // namespace

#endif // ISP_CSIIR_HLS_STANDALONE_HPP
