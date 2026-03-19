#!/usr/bin/env python3
"""
ISP-CSIIR Reference Model
Reference: isp-csiir-algorithm-reference.md

4-Stage Pipeline:
  Stage 1: Gradient computation and window size determination
  Stage 2: Multi-scale directional averaging
  Stage 3: Gradient-weighted directional fusion
  Stage 4: IIR filtering and blending output
"""

import numpy as np
from typing import Tuple, Optional
from dataclasses import dataclass


@dataclass
class ISPConfig:
    """Configuration parameters for ISP-CSIIR"""
    # Image dimensions
    width: int = 64
    height: int = 64

    # Window size thresholds
    win_size_thresh0: int = 16
    win_size_thresh1: int = 24
    win_size_thresh2: int = 32
    win_size_thresh3: int = 40

    # Gradient clip thresholds
    win_size_clip_y: list = None
    win_size_clip_sft: list = None

    # Blending ratios
    blending_ratio: list = None

    # Edge protection
    edge_protect: int = 32

    def __post_init__(self):
        if self.win_size_clip_y is None:
            self.win_size_clip_y = [15, 23, 31, 39]
        if self.win_size_clip_sft is None:
            self.win_size_clip_sft = [2, 2, 2, 2]
        if self.blending_ratio is None:
            self.blending_ratio = [32, 32, 32, 32]


# Sobel kernels (5x5)
SOBEL_X = np.array([
    [1, 1, 1, 1, 1],
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
    [-1, -1, -1, -1, -1]
], dtype=np.int32)

SOBEL_Y = np.array([
    [1, 0, 0, 0, -1],
    [1, 0, 0, 0, -1],
    [1, 0, 0, 0, -1],
    [1, 0, 0, 0, -1],
    [1, 0, 0, 0, -1]
], dtype=np.int32)

# Average factor kernels (5x5)
AVG_FACTOR_C_2X2 = np.array([
    [0, 0, 0, 0, 0],
    [0, 1, 2, 1, 0],
    [0, 2, 4, 2, 0],
    [0, 1, 2, 1, 0],
    [0, 0, 0, 0, 0]
], dtype=np.int32)

AVG_FACTOR_C_3X3 = np.array([
    [0, 0, 0, 0, 0],
    [0, 1, 1, 1, 0],
    [0, 1, 1, 1, 0],
    [0, 1, 1, 1, 0],
    [0, 0, 0, 0, 0]
], dtype=np.int32)

AVG_FACTOR_C_4X4 = np.array([
    [1, 1, 2, 1, 1],
    [1, 2, 4, 2, 1],
    [2, 4, 8, 4, 2],
    [1, 2, 4, 2, 1],
    [1, 1, 2, 1, 1]
], dtype=np.int32)

AVG_FACTOR_C_5X5 = np.array([
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1]
], dtype=np.int32)

# Direction masks
AVG_FACTOR_U_MASK = np.array([
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0]
], dtype=np.int32)

AVG_FACTOR_D_MASK = np.array([
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1],
    [1, 1, 1, 1, 1]
], dtype=np.int32)

AVG_FACTOR_L_MASK = np.array([
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0],
    [1, 1, 1, 0, 0]
], dtype=np.int32)

AVG_FACTOR_R_MASK = np.array([
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1],
    [0, 0, 1, 1, 1]
], dtype=np.int32)

# Blend factor kernels for Stage 4
BLEND_FACTOR_2X2_H = np.array([
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0],
    [0, 1, 1, 1, 0],
    [0, 0, 0, 0, 0],
    [0, 0, 0, 0, 0]
], dtype=np.int32)

BLEND_FACTOR_2X2_V = np.array([
    [0, 0, 0, 0, 0],
    [0, 0, 1, 0, 0],
    [0, 0, 1, 0, 0],
    [0, 0, 1, 0, 0],
    [0, 0, 0, 0, 0]
], dtype=np.int32)

BLEND_FACTOR_2X2 = np.array([
    [0, 0, 0, 0, 0],
    [0, 1, 2, 1, 0],
    [0, 2, 4, 2, 0],
    [0, 1, 2, 1, 0],
    [0, 0, 0, 0, 0]
], dtype=np.int32)

BLEND_FACTOR_3X3 = np.array([
    [0, 0, 0, 0, 0],
    [0, 1, 1, 1, 0],
    [0, 1, 1, 1, 0],
    [0, 1, 1, 1, 0],
    [0, 0, 0, 0, 0]
], dtype=np.int32)

BLEND_FACTOR_4X4 = np.array([
    [1, 2, 2, 2, 1],
    [2, 4, 4, 4, 2],
    [2, 4, 4, 4, 2],
    [2, 4, 4, 4, 2],
    [1, 2, 2, 2, 1]
], dtype=np.int32)

BLEND_FACTOR_5X5 = np.array([
    [4, 4, 4, 4, 4],
    [4, 4, 4, 4, 4],
    [4, 4, 4, 4, 4],
    [4, 4, 4, 4, 4],
    [4, 4, 4, 4, 4]
], dtype=np.int32)


def clip(val: int, low: int, high: int) -> int:
    """Clip value to [low, high] range"""
    return max(low, min(high, val))


def get_5x5_window(img: np.ndarray, i: int, j: int, height: int, width: int) -> np.ndarray:
    """
    Extract 5x5 window centered at (i, j) with boundary replication.
    (i, j) is the center pixel coordinate.
    """
    window = np.zeros((5, 5), dtype=np.float64)

    for h in range(-2, 3):
        for w in range(-2, 3):
            # Clip coordinates to image bounds
            y = clip(j + h, 0, height - 1)  # j is row (height direction)
            x = clip(i + w, 0, width - 1)    # i is column (width direction)
            window[h + 2, w + 2] = img[y, x]

    return window


class ISPCSIIRRefModel:
    """ISP-CSIIR Reference Model"""

    def __init__(self, config: ISPConfig = None):
        self.config = config or ISPConfig()
        self.width = self.config.width
        self.height = self.config.height

        # Intermediate buffers
        self.grad = None           # Gradient magnitude
        self.grad_h = None         # Horizontal gradient
        self.grad_v = None         # Vertical gradient
        self.win_size_clip = None  # Window size after clipping

        # Stage 2 outputs
        self.avg0 = {}  # avg0_c, avg0_u, avg0_d, avg0_l, avg0_r
        self.avg1 = {}  # avg1_c, avg1_u, avg1_d, avg1_l, avg1_r

        # Stage 3 outputs
        self.blend0_grad = None
        self.blend1_grad = None

        # Stage 4 outputs
        self.blend_uv = None  # Final output

        # IIR state (for temporal filtering)
        self.src_uv_state = None

    def process(self, img: np.ndarray) -> np.ndarray:
        """
        Process input image through all 4 stages.

        Args:
            img: Input image (height x width), values in [0, 1023] for 10-bit

        Returns:
            Processed image (height x width)
        """
        self.height, self.width = img.shape

        # Initialize output
        self.blend_uv = np.zeros_like(img, dtype=np.float64)

        # Initialize IIR state
        if self.src_uv_state is None:
            self.src_uv_state = img.astype(np.float64).copy()

        # Stage 1: Gradient computation
        self._stage1_gradient(img)

        # Stage 2: Multi-scale directional averaging
        self._stage2_directional_avg(img)

        # Stage 3: Gradient-weighted directional fusion
        self._stage3_gradient_fusion()

        # Stage 4: IIR filtering and blending
        self._stage4_iir_blend(img)

        # Update IIR state
        self.src_uv_state = self.blend_uv.copy()

        return np.round(np.clip(self.blend_uv, 0, 1023)).astype(np.int32)

    def _stage1_gradient(self, img: np.ndarray):
        """Stage 1: Sobel gradient computation and window size determination"""
        self.grad = np.zeros((self.height, self.width), dtype=np.float64)
        self.grad_h = np.zeros((self.height, self.width), dtype=np.float64)
        self.grad_v = np.zeros((self.height, self.width), dtype=np.float64)
        self.win_size_clip = np.zeros((self.height, self.width), dtype=np.int32)

        # Compute gradients
        for j in range(self.height):
            for i in range(self.width):
                window = get_5x5_window(img, i, j, self.height, self.width)

                # Sobel convolution
                grad_h = np.sum(window * SOBEL_X)
                grad_v = np.sum(window * SOBEL_Y)

                self.grad_h[j, i] = abs(grad_h)
                self.grad_v[j, i] = abs(grad_v)

                # grad = |grad_h|/5 + |grad_v|/5
                self.grad[j, i] = abs(grad_h) / 5.0 + abs(grad_v) / 5.0

        # Compute window size using LUT
        for j in range(self.height):
            for i in range(self.width):
                # Get max of 3 gradients: grad(i-1,j), grad(i,j), grad(i+1,j)
                grad_left = self.grad[j, clip(i-1, 0, self.width-1)]
                grad_center = self.grad[j, i]
                grad_right = self.grad[j, clip(i+1, 0, self.width-1)]

                grad_max = max(grad_left, grad_center, grad_right)

                # LUT for window size
                win_size = self._lut_window_size(grad_max)

                # Clip to [16, 40]
                self.win_size_clip[j, i] = clip(win_size, 16, 40)

    def _lut_window_size(self, grad_max: float) -> int:
        """
        Look up window size based on gradient threshold.

        The win_size_clip_y values are gradient thresholds.
        When grad_max exceeds a threshold, return corresponding window size.

        Default gradient thresholds [15, 23, 31, 39] are scaled for normalized gradients.
        For 10-bit image gradients, use scaled thresholds.
        """
        clip_y = self.config.win_size_clip_y

        # Gradient thresholds need to be scaled for actual gradient magnitudes
        # For 10-bit images with 5x5 Sobel, gradients can be much larger
        # Scale thresholds: multiply by typical gradient scale factor
        scale_factor = 25  # Approximate scale for 5-pixel Sobel sum

        scaled_thresh = [t * scale_factor for t in clip_y]

        if grad_max < scaled_thresh[0]:
            return 16
        elif grad_max < scaled_thresh[1]:
            return 24
        elif grad_max < scaled_thresh[2]:
            return 32
        elif grad_max < scaled_thresh[3]:
            return 40
        else:
            return 40

    def _stage2_directional_avg(self, img: np.ndarray):
        """Stage 2: Multi-scale directional averaging"""
        # Initialize output dictionaries
        for direction in ['c', 'u', 'd', 'l', 'r']:
            self.avg0[direction] = np.zeros((self.height, self.width), dtype=np.float64)
            self.avg1[direction] = np.zeros((self.height, self.width), dtype=np.float64)

        thresh = [
            self.config.win_size_thresh0,
            self.config.win_size_thresh1,
            self.config.win_size_thresh2,
            self.config.win_size_thresh3
        ]

        for j in range(self.height):
            for i in range(self.width):
                window = get_5x5_window(img, i, j, self.height, self.width)
                ws = self.win_size_clip[j, i]

                # Select kernel pair based on window size
                if ws < thresh[0]:
                    avg0_factor_c = np.zeros((5, 5), dtype=np.int32)
                    avg1_factor_c = AVG_FACTOR_C_2X2
                elif ws < thresh[1]:
                    avg0_factor_c = AVG_FACTOR_C_2X2
                    avg1_factor_c = AVG_FACTOR_C_3X3
                elif ws < thresh[2]:
                    avg0_factor_c = AVG_FACTOR_C_3X3
                    avg1_factor_c = AVG_FACTOR_C_4X4
                elif ws < thresh[3]:
                    avg0_factor_c = AVG_FACTOR_C_4X4
                    avg1_factor_c = AVG_FACTOR_C_5X5
                else:
                    avg0_factor_c = AVG_FACTOR_C_5X5
                    avg1_factor_c = np.zeros((5, 5), dtype=np.int32)

                # Compute directional averages for avg0
                self.avg0['c'][j, i] = self._compute_avg(window, avg0_factor_c)
                self.avg0['u'][j, i] = self._compute_avg(window, avg0_factor_c * AVG_FACTOR_U_MASK)
                self.avg0['d'][j, i] = self._compute_avg(window, avg0_factor_c * AVG_FACTOR_D_MASK)
                self.avg0['l'][j, i] = self._compute_avg(window, avg0_factor_c * AVG_FACTOR_L_MASK)
                self.avg0['r'][j, i] = self._compute_avg(window, avg0_factor_c * AVG_FACTOR_R_MASK)

                # Compute directional averages for avg1
                self.avg1['c'][j, i] = self._compute_avg(window, avg1_factor_c)
                self.avg1['u'][j, i] = self._compute_avg(window, avg1_factor_c * AVG_FACTOR_U_MASK)
                self.avg1['d'][j, i] = self._compute_avg(window, avg1_factor_c * AVG_FACTOR_D_MASK)
                self.avg1['l'][j, i] = self._compute_avg(window, avg1_factor_c * AVG_FACTOR_L_MASK)
                self.avg1['r'][j, i] = self._compute_avg(window, avg1_factor_c * AVG_FACTOR_R_MASK)

    def _compute_avg(self, window: np.ndarray, factor: np.ndarray) -> float:
        """Compute weighted average using factor kernel"""
        weight_sum = np.sum(factor)
        if weight_sum == 0:
            return 0.0
        pixel_sum = np.sum(window * factor)
        return pixel_sum / weight_sum

    def _stage3_gradient_fusion(self):
        """Stage 3: Gradient-weighted directional fusion"""
        self.blend0_grad = np.zeros((self.height, self.width), dtype=np.float64)
        self.blend1_grad = np.zeros((self.height, self.width), dtype=np.float64)

        for j in range(self.height):
            for i in range(self.width):
                # Get gradients with boundary handling
                grad_c = self.grad[j, i]

                # Upper gradient (j-1)
                if j == 0:
                    grad_u = grad_c
                else:
                    grad_u = self.grad[j-1, i]

                # Down gradient (j+1)
                if j == self.height - 1:
                    grad_d = grad_c
                else:
                    grad_d = self.grad[j+1, i]

                # Left gradient (i-1)
                if i == 0:
                    grad_l = grad_c
                else:
                    grad_l = self.grad[j, i-1]

                # Right gradient (i+1)
                if i == self.width - 1:
                    grad_r = grad_c
                else:
                    grad_r = self.grad[j, i+1]

                # Inverse sort gradients (descending order)
                sorted_grads = sorted([grad_u, grad_d, grad_l, grad_r, grad_c], reverse=True)
                grad_u_s, grad_d_s, grad_l_s, grad_r_s, grad_c_s = sorted_grads

                grad_sum = grad_u_s + grad_d_s + grad_l_s + grad_r_s + grad_c_s

                # Get averages (need to sort these according to gradient order)
                # For simplicity, use the sorted gradients with original averages
                avg0_c = self.avg0['c'][j, i]
                avg0_u = self.avg0['u'][j, i]
                avg0_d = self.avg0['d'][j, i]
                avg0_l = self.avg0['l'][j, i]
                avg0_r = self.avg0['r'][j, i]

                avg1_c = self.avg1['c'][j, i]
                avg1_u = self.avg1['u'][j, i]
                avg1_d = self.avg1['d'][j, i]
                avg1_l = self.avg1['l'][j, i]
                avg1_r = self.avg1['r'][j, i]

                # Gradient fusion
                if grad_sum == 0:
                    self.blend0_grad[j, i] = (avg0_c + avg0_u + avg0_d + avg0_l + avg0_r) / 5.0
                    self.blend1_grad[j, i] = (avg1_c + avg1_u + avg1_d + avg1_l + avg1_r) / 5.0
                else:
                    self.blend0_grad[j, i] = (
                        avg0_c * grad_c_s +
                        avg0_u * grad_u_s +
                        avg0_d * grad_d_s +
                        avg0_l * grad_l_s +
                        avg0_r * grad_r_s
                    ) / grad_sum

                    self.blend1_grad[j, i] = (
                        avg1_c * grad_c_s +
                        avg1_u * grad_u_s +
                        avg1_d * grad_d_s +
                        avg1_l * grad_l_s +
                        avg1_r * grad_r_s
                    ) / grad_sum

    def _stage4_iir_blend(self, img: np.ndarray):
        """Stage 4: IIR filtering and blending output"""
        thresh = [
            self.config.win_size_thresh0,
            self.config.win_size_thresh1,
            self.config.win_size_thresh2,
            self.config.win_size_thresh3
        ]

        for j in range(self.height):
            for i in range(self.width):
                ws = self.win_size_clip[j, i]
                grad_h = self.grad_h[j, i]
                grad_v = self.grad_v[j, i]

                # Get blend ratio index
                blend_ratio_idx = ws // 8 - 2
                blend_ratio_idx = clip(blend_ratio_idx, 0, 3)
                ratio = self.config.blending_ratio[blend_ratio_idx]

                # Horizontal blend
                avg0_u = self.avg0['u'][j, i]
                avg1_u = self.avg1['u'][j, i]
                blend0_hor = (ratio * self.blend0_grad[j, i] + (64 - ratio) * avg0_u) / 64.0
                blend1_hor = (ratio * self.blend1_grad[j, i] + (64 - ratio) * avg1_u) / 64.0

                # Select blend factor based on gradient direction
                if grad_h > grad_v:
                    blend_factor_2x2_hv = BLEND_FACTOR_2X2_H
                else:
                    blend_factor_2x2_hv = BLEND_FACTOR_2X2_V

                # Get 5x5 window for blending
                window = get_5x5_window(img, i, j, self.height, self.width)

                # Window blending based on window size
                # Formula: blend_win = (blend_hor * blend_factor + src_uv * (4 - blend_factor)) / 4
                # Weight sum is 4, so divide by 4 to get weighted average
                if ws < thresh[0]:
                    # blend0
                    blend00_win_5x5 = (blend0_hor * blend_factor_2x2_hv + window * (4 - blend_factor_2x2_hv)) / 4.0
                    blend01_win_5x5 = (blend0_hor * BLEND_FACTOR_2X2 + window * (4 - BLEND_FACTOR_2X2)) / 4.0
                    blend0_win = (blend00_win_5x5 * self.config.edge_protect +
                                  blend01_win_5x5 * (64 - self.config.edge_protect)) / 64.0
                    blend0_win_val = blend0_win[2, 2]  # Center pixel

                    blend1_win_val = 0.0  # Not used
                elif ws < thresh[1]:
                    blend00_win_5x5 = (blend0_hor * blend_factor_2x2_hv + window * (4 - blend_factor_2x2_hv)) / 4.0
                    blend01_win_5x5 = (blend0_hor * BLEND_FACTOR_2X2 + window * (4 - BLEND_FACTOR_2X2)) / 4.0
                    blend0_win = (blend00_win_5x5 * self.config.edge_protect +
                                  blend01_win_5x5 * (64 - self.config.edge_protect)) / 64.0
                    blend0_win_val = blend0_win[2, 2]

                    blend1_win_5x5 = (blend1_hor * BLEND_FACTOR_3X3 + window * (4 - BLEND_FACTOR_3X3)) / 4.0
                    blend1_win_val = blend1_win_5x5[2, 2]
                elif ws < thresh[2]:
                    blend0_win_5x5 = (blend0_hor * BLEND_FACTOR_3X3 + window * (4 - BLEND_FACTOR_3X3)) / 4.0
                    blend0_win_val = blend0_win_5x5[2, 2]

                    blend1_win_5x5 = (blend1_hor * BLEND_FACTOR_4X4 + window * (4 - BLEND_FACTOR_4X4)) / 4.0
                    blend1_win_val = blend1_win_5x5[2, 2]
                elif ws < thresh[3]:
                    blend0_win_5x5 = (blend0_hor * BLEND_FACTOR_4X4 + window * (4 - BLEND_FACTOR_4X4)) / 4.0
                    blend0_win_val = blend0_win_5x5[2, 2]

                    blend1_win_5x5 = (blend1_hor * BLEND_FACTOR_5X5 + window * (4 - BLEND_FACTOR_5X5)) / 4.0
                    blend1_win_val = blend1_win_5x5[2, 2]
                else:
                    blend0_win_val = 0.0  # Not used
                    blend1_win_5x5 = (blend1_hor * BLEND_FACTOR_5X5 + window * (4 - BLEND_FACTOR_5X5)) / 4.0
                    blend1_win_val = blend1_win_5x5[2, 2]

                # Final blend
                win_size_remain_8 = ws % 8

                if ws < thresh[0]:
                    self.blend_uv[j, i] = blend0_win_val
                elif ws >= thresh[3]:
                    self.blend_uv[j, i] = blend1_win_val
                else:
                    self.blend_uv[j, i] = (
                        blend0_win_val * win_size_remain_8 +
                        blend1_win_val * (8 - win_size_remain_8)
                    ) / 8.0


def process_image(img: np.ndarray, config: ISPConfig = None) -> np.ndarray:
    """
    Convenience function to process an image.

    Args:
        img: Input image (height x width)
        config: ISP configuration

    Returns:
        Processed image
    """
    model = ISPCSIIRRefModel(config)
    return model.process(img)


if __name__ == "__main__":
    # Simple test
    config = ISPConfig(width=64, height=64)
    model = ISPCSIIRRefModel(config)

    # Generate random test image
    np.random.seed(42)
    img = np.random.randint(0, 1024, (64, 64), dtype=np.int32)

    result = model.process(img)
    print(f"Input shape: {img.shape}")
    print(f"Output shape: {result.shape}")
    print(f"Input range: [{img.min()}, {img.max()}]")
    print(f"Output range: [{result.min()}, {result.max()}]")