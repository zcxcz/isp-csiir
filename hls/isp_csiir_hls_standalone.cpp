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
    grad = (grad_t)(round_div(grad_h, 5) + round_div(grad_v, 5));
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

// 5x5 kernels
static const int K2X2[PATCH_SIZE] = {
    0, 0, 0, 0, 0,
    0, 1, 2, 1, 0,
    0, 2, 4, 2, 0,
    0, 1, 2, 1, 0,
    0, 0, 0, 0, 0
};

static const int K3X3[PATCH_SIZE] = {
    0, 0, 0, 0, 0,
    0, 1, 1, 1, 0,
    0, 1, 1, 1, 0,
    0, 1, 1, 1, 0,
    0, 0, 0, 0, 0
};

static const int K4X4[PATCH_SIZE] = {
    1, 1, 2, 1, 1,
    1, 2, 4, 2, 1,
    2, 4, 8, 4, 2,
    1, 2, 4, 2, 1,
    1, 1, 2, 1, 1
};

static const int K5X5[PATCH_SIZE] = {
    1, 1, 1, 1, 1,
    1, 1, 1, 1, 1,
    1, 1, 1, 1, 1,
    1, 1, 1, 1, 1,
    1, 1, 1, 1, 1
};

static const int ZERO[PATCH_SIZE] = {0};

// Direction masks
static const int MC[PATCH_SIZE] = {1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1};
static const int MU[PATCH_SIZE] = {1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0};
static const int MD[PATCH_SIZE] = {0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1};
static const int ML[PATCH_SIZE] = {1,1,1,0,0,1,1,1,0,0,1,1,1,0,0,1,1,1,0,0,1,1,1,0,0};
static const int MR[PATCH_SIZE] = {0,0,1,1,1,0,0,1,1,1,0,0,1,1,1,0,0,1,1,1,0,0,1,1,1};

inline DirAvgResult compute_directional_avg(const Config& cfg,
                                             const s11_t patch_s11[PATCH_SIZE],
                                             int win_size) {
    DirAvgResult result = {};
    int kt = select_kernel_type(cfg, win_size);

    const int* k0;
    const int* k1;
    switch (kt) {
        case 0: k0 = ZERO; k1 = K2X2; result.avg0_enable = false; result.avg1_enable = true; break;
        case 1: k0 = K3X3; k1 = K2X2; result.avg0_enable = true; result.avg1_enable = true; break;
        case 2: k0 = K4X4; k1 = K3X3; result.avg0_enable = true; result.avg1_enable = true; break;
        case 3: k0 = K5X5; k1 = K4X4; result.avg0_enable = true; result.avg1_enable = true; break;
        default: k0 = K5X5; k1 = ZERO; result.avg0_enable = true; result.avg1_enable = false; break;
    }

    // Compute masked kernels for avg0 (kernel * mask for each direction)
    // Always compute avg0 values even when avg0_enable=false, per Python semantics
    int mk0_c[PATCH_SIZE], mk0_u[PATCH_SIZE], mk0_d[PATCH_SIZE];
    int mk0_l[PATCH_SIZE], mk0_r[PATCH_SIZE];
    for (int i = 0; i < PATCH_SIZE; i++) {
        mk0_c[i] = k0[i] * MC[i];
        mk0_u[i] = k0[i] * MU[i];
        mk0_d[i] = k0[i] * MD[i];
        mk0_l[i] = k0[i] * ML[i];
        mk0_r[i] = k0[i] * MR[i];
    }
    result.avg0_c = weighted_avg(patch_s11, mk0_c);
    result.avg0_u = weighted_avg(patch_s11, mk0_u);
    result.avg0_d = weighted_avg(patch_s11, mk0_d);
    result.avg0_l = weighted_avg(patch_s11, mk0_l);
    result.avg0_r = weighted_avg(patch_s11, mk0_r);

    // Compute masked kernels for avg1
    int mk1_c[PATCH_SIZE], mk1_u[PATCH_SIZE], mk1_d[PATCH_SIZE];
    int mk1_l[PATCH_SIZE], mk1_r[PATCH_SIZE];
    for (int i = 0; i < PATCH_SIZE; i++) {
        mk1_c[i] = k1[i] * MC[i];
        mk1_u[i] = k1[i] * MU[i];
        mk1_d[i] = k1[i] * MD[i];
        mk1_l[i] = k1[i] * ML[i];
        mk1_r[i] = k1[i] * MR[i];
    }
    result.avg1_c = weighted_avg(patch_s11, mk1_c);
    result.avg1_u = weighted_avg(patch_s11, mk1_u);
    result.avg1_d = weighted_avg(patch_s11, mk1_d);
    result.avg1_l = weighted_avg(patch_s11, mk1_l);
    result.avg1_r = weighted_avg(patch_s11, mk1_r);

    return result;
}

//==============================================================================
// Gradient Fusion
//==============================================================================
struct FusionResult {
    s11_t blend0;
    s11_t blend1;
};

inline void grad_inverse_remap(int g[5], int inv[5]) {
    int idx[5] = {0, 1, 2, 3, 4};
    for (int i = 0; i < 4; i++) {
        for (int j = 0; j < 4 - i; j++) {
            if (g[idx[j]] < g[idx[j+1]]) {
                int t = idx[j]; idx[j] = idx[j+1]; idx[j+1] = t;
            }
        }
    }
    for (int i = 0; i < 5; i++) {
        inv[idx[4-i]] = g[idx[i]];
    }
}

inline FusionResult compute_gradient_fusion(const DirAvgResult& dir_avg,
                                           int grad_u, int grad_d,
                                           int grad_l, int grad_r, int grad_c) {
    FusionResult result;
    int g[5] = {grad_u, grad_d, grad_l, grad_r, grad_c};
    int inv[5];
    grad_inverse_remap(g, inv);

    int sum = inv[0] + inv[1] + inv[2] + inv[3] + inv[4];

    int v0[5] = {(int)dir_avg.avg0_c, (int)dir_avg.avg0_u, (int)dir_avg.avg0_d,
                 (int)dir_avg.avg0_l, (int)dir_avg.avg0_r};
    int v1[5] = {(int)dir_avg.avg1_c, (int)dir_avg.avg1_u, (int)dir_avg.avg1_d,
                 (int)dir_avg.avg1_l, (int)dir_avg.avg1_r};

    int total0 = 0, total1 = 0;
    for (int i = 0; i < 5; i++) {
        total0 += v0[i] * inv[i];
        total1 += v1[i] * inv[i];
    }

    if (sum == 0) {
        // When gradient sum is 0, use simple average of all directional values
        // (matches Python: total = sum(avg_c + avg_u + avg_d + avg_l + avg_r))
        int simple_sum0 = v0[0] + v0[1] + v0[2] + v0[3] + v0[4];
        int simple_sum1 = v1[0] + v1[1] + v1[2] + v1[3] + v1[4];
        result.blend0 = saturate_s11(round_div(simple_sum0, 5));
        result.blend1 = saturate_s11(round_div(simple_sum1, 5));
    } else {
        result.blend0 = saturate_s11(round_div(total0, sum));
        result.blend1 = saturate_s11(round_div(total1, sum));
    }
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

// Blend factors (matching Python's BLEND_FACTOR_*)
static const int F2X2[PATCH_SIZE] = {0,0,0,0,0,0,1,2,1,0,0,2,4,2,0,0,1,2,1,0,0,0,0,0,0};
static const int F3X3[PATCH_SIZE] = {0,0,0,0,0,0,1,1,1,0,0,1,1,1,0,0,1,1,1,0,0,0,0,0,0};
// Note: Python's AVG_FACTOR_C_4X4 has center element 8 (not 4)
static const int F4X4[PATCH_SIZE] = {1,1,2,1,1,1,2,4,2,1,2,4,8,4,2,1,2,4,2,1,1,1,2,1,1};
// Note: Python's AVG_FACTOR_C_5X5 is all 1s (not 4s)
static const int F5X5[PATCH_SIZE] = {1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1};
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
