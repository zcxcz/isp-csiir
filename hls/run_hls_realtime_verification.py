#!/usr/bin/env python3
"""
HLS C++ Model vs Python Reference Model Verification

Compares the HLS standalone C++ model with the Python fixed-point
reference model using random configurations and patterns.

Usage:
    python3 run_hls_realtime_verification.py --num-tests 100
    python3 run_hls_realtime_verification.py --seed 42 --pattern random
    python3 run_hls_realtime_verification.py --coverage  # Collect corner coverage
"""

import os
import sys
import subprocess
import argparse
import numpy as np
from pathlib import Path
from dataclasses import dataclass, field
from typing import List, Dict, Tuple, Optional, Set
from datetime import datetime
from collections import defaultdict
import json

# Add verification directory to path
SCRIPT_DIR = Path(__file__).parent
VERIF_DIR = SCRIPT_DIR.parent / "verification"
sys.path.insert(0, str(VERIF_DIR))

from generate_test_config import ConfigGenerator, TestConfig
from isp_csiir_fixed_model import ISPCSIIRFixedModel, FixedPointConfig


# ============================================================================
# HLS Model Wrapper (using subprocess to run compiled C++)
# ============================================================================

class HLSModelRunner:
    """
    Runs HLS C++ standalone model via subprocess.

    Note: The existing standalone_tb.cpp uses fixed 64x64 dimensions and
    hardcoded Config. For verification, we generate input patterns and
    compare the C++ output with our Python reference model.
    """

    def __init__(self, hls_dir: Path):
        self.hls_dir = hls_dir
        self.standalone_cpp = hls_dir / "isp_csiir_hls_standalone.cpp"
        self.standalone_tb = hls_dir / "standalone_tb.cpp"
        self.tb_exe = hls_dir / "standalone_tb"

    def compile_if_needed(self) -> bool:
        """Compile standalone testbench if needed"""
        if self.tb_exe.exists() and self.tb_exe.stat().st_mtime > max(
            self.standalone_cpp.stat().st_mtime,
            self.standalone_tb.stat().st_mtime
        ):
            return True

        print("  Compiling HLS standalone model...")
        cmd = [
            "g++", "-std=c++17", "-O2", "-Wall",
            "-o", str(self.tb_exe),
            str(self.standalone_tb)
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"  Compilation failed:\n{result.stderr}")
            return False
        return True

    def run(self, pattern: str, stimulus: Optional[np.ndarray] = None) -> Optional[np.ndarray]:
        """
        Run HLS model with given pattern or stimulus.

        The standalone tb has hardcoded 64x64 dimensions and generates
        its own input based on pattern. We can optionally provide a
        pre-generated input file.

        Returns:
            Output image as numpy array (64x64), or None on failure
        """
        if not self.compile_if_needed():
            return None

        # Write stimulus to temp file if provided (must be 64x64)
        stimulus_file = SCRIPT_DIR / "_hls_stimulus.hex"
        output_file = SCRIPT_DIR / "_hls_output.hex"

        if stimulus is not None:
            if stimulus.shape != (64, 64):
                print(f"  Warning: HLS model only supports 64x64, got {stimulus.shape}")
                return None
            # Match C++ dump_image_hex format: one hex value per line
            with open(stimulus_file, 'w') as f:
                for val in stimulus.flatten():
                    f.write(f"{val:03x}\n")

        # Clean up old output
        if output_file.exists():
            output_file.unlink()

        # Build command
        if stimulus is not None:
            cmd = [str(self.tb_exe), "-i", str(stimulus_file)]
        else:
            cmd = [str(self.tb_exe), pattern]

        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=120,
                cwd=str(self.hls_dir)
            )
        except subprocess.TimeoutExpired:
            print("  HLS model timed out")
            return None

        if result.returncode != 0:
            print(f"  HLS model error:\n{result.stderr}")
            return None

        # The testbench writes to cpp_output.hex in the hls_dir
        cpp_output = self.hls_dir / "cpp_output.hex"
        if not cpp_output.exists():
            print("  HLS model did not produce cpp_output.hex")
            return None

        # Read output
        output = []
        with open(cpp_output, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    try:
                        output.append(int(line, 16))
                    except ValueError:
                        pass

        if len(output) != 64 * 64:
            print(f"  HLS output size mismatch: expected {64*64}, got {len(output)}")
            return None

        return np.array(output, dtype=np.int32).reshape((64, 64))


# ============================================================================
# Python Reference Model (No-Feedback Version)
# ============================================================================

class PythonReferenceModel:
    """
    Python reference model that matches HLS standalone behavior.
    This is a feed-forward per-pixel model WITHOUT feedback.
    """

    def __init__(self, config: 'HLSTestConfig'):
        self.cfg = config
        self.DATA_MAX = 1023
        self.HORIZONTAL_TAP_STEP = 2

    def _clip(self, value, min_val=0, max_val=1023):
        """Clip value to range - handles both scalar and array"""
        if isinstance(value, np.ndarray):
            return np.clip(value, min_val, max_val)
        return max(min_val, min(max_val, value))

    def _round_div(self, num, den):
        """Round division - handles both scalar and array"""
        if isinstance(num, np.ndarray):
            result = np.zeros_like(num)
            pos_mask = num >= 0
            neg_mask = ~pos_mask
            result[pos_mask] = (num[pos_mask] + den // 2) // den
            result[neg_mask] = -(((-num[neg_mask]) + den // 2) // den)
            result[den == 0] = 0
            return result
        if den == 0:
            return 0
        if num >= 0:
            return (num + den // 2) // den
        return -(((-num) + den // 2) // den)

    def _u10_to_s11(self, value):
        """Convert u10 to s11 - handles both scalar and array"""
        if isinstance(value, np.ndarray):
            return value.astype(np.int32) - 512
        return int(value) - 512

    def _s11_to_u10(self, value):
        """Convert s11 to u10 - handles both scalar and array"""
        if isinstance(value, np.ndarray):
            return np.clip(value.astype(np.int32) + 512, 0, 1023)
        return self._clip(int(value) + 512, 0, 1023)

    def _saturate_s11(self, value):
        """Saturate s11 - handles both scalar and array"""
        if isinstance(value, np.ndarray):
            return np.clip(value, -512, 511)
        return self._clip(int(value), -512, 511)

    def _get_window(self, img: np.ndarray, center_i: int, center_j: int) -> np.ndarray:
        """Get 5x5 window with sparse horizontal sampling (matches HLS)"""
        h, w = img.shape
        window = np.zeros((5, 5), dtype=np.int32)
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                col = self._clip(center_i + dx * self.HORIZONTAL_TAP_STEP, 0, w - 1)
                row = self._clip(center_j + dy, 0, h - 1)
                window[dy + 2, dx + 2] = int(img[row, col])
        return window

    def _sobel_gradient(self, window: np.ndarray) -> Tuple[int, int, int]:
        """Sobel 5x5 gradient - matches HLS"""
        sum_h = np.sum(window[0, :]) - np.sum(window[4, :])
        sum_v = np.sum(window[:, 0]) - np.sum(window[:, 4])
        grad_h = abs(sum_h)
        grad_v = abs(sum_v)
        grad = self._round_div(grad_h, 5) + self._round_div(grad_v, 5)
        return grad_h, grad_v, grad

    def _lut_win_size(self, grad_triplet_max: int) -> int:
        """Window size LUT - matches HLS"""
        x_nodes = []
        acc = 0
        for sft in self.cfg.win_size_clip_sft:
            acc += (1 << sft)
            x_nodes.append(acc)

        y0 = self.cfg.win_size_clip_y[0]
        y1 = self.cfg.win_size_clip_y[3]

        x = grad_triplet_max
        if x <= x_nodes[0]:
            return self._clip(y0, 16, 40)
        if x >= x_nodes[3]:
            return self._clip(y1, 16, 40)

        win_size = y1
        for idx in range(3):
            if x_nodes[idx] <= x <= x_nodes[idx + 1]:
                x0, x1 = x_nodes[idx], x_nodes[idx + 1]
                y0_i = self.cfg.win_size_clip_y[idx]
                y1_i = self.cfg.win_size_clip_y[idx + 1]
                win_size = y0_i + self._round_div((x - x0) * (y1_i - y0_i), (x1 - x0))
                break

        return self._clip(win_size, 16, 40)

    def _select_kernel_type(self, win_size: int) -> int:
        """Select kernel type based on window size"""
        t = self.cfg.win_size_thresh
        if win_size < t[0]:
            return 0
        if win_size < t[1]:
            return 1
        if win_size < t[2]:
            return 2
        if win_size < t[3]:
            return 3
        return 4

    def _weighted_avg(self, patch_s11: np.ndarray, kernel: np.ndarray) -> int:
        """Weighted average computation"""
        total = np.sum(patch_s11 * kernel)
        weight = np.sum(kernel)
        if weight == 0:
            return 0
        return self._saturate_s11(self._round_div(int(total), int(weight)))

    def _compute_directional_avg(self, patch_s11: np.ndarray, win_size: int) -> Dict[str, int]:
        """Compute directional averages - matches HLS"""
        kt = self._select_kernel_type(win_size)

        # Kernels
        K2X2 = np.array([0,0,0,0,0,0,1,2,1,0,0,2,4,2,0,0,1,2,1,0,0,0,0,0,0], dtype=np.int32).reshape(5,5)
        K3X3 = np.array([0,0,0,0,0,0,1,1,1,0,0,1,1,1,0,0,1,1,1,0,0,0,0,0,0], dtype=np.int32).reshape(5,5)
        K4X4 = np.array([1,1,2,1,1,1,2,4,2,1,2,4,8,4,2,1,2,4,2,1,1,1,2,1,1], dtype=np.int32).reshape(5,5)
        K5X5 = np.ones((5, 5), dtype=np.int32)
        ZERO = np.zeros((5, 5), dtype=np.int32)

        # Direction masks
        MC = np.ones((5, 5), dtype=np.int32)
        MU = np.concatenate([np.ones((3, 5), dtype=np.int32), np.zeros((2, 5), dtype=np.int32)])
        MD = np.concatenate([np.zeros((2, 5), dtype=np.int32), np.ones((3, 5), dtype=np.int32)])
        ML = np.zeros((5, 5), dtype=np.int32)
        MR = np.zeros((5, 5), dtype=np.int32)
        for i in range(5):
            for j in range(5):
                if j < 3:
                    ML[i, j] = 1
                if j > 1:
                    MR[i, j] = 1

        # Select kernels
        if kt == 0:
            k0, k1 = ZERO, K2X2
        elif kt == 1:
            k0, k1 = K3X3, K2X2
        elif kt == 2:
            k0, k1 = K4X4, K3X3
        elif kt == 3:
            k0, k1 = K5X5, K4X4
        else:
            k0, k1 = K5X5, ZERO

        # Compute masked averages
        mk0_c = k0 * MC
        mk0_u = k0 * MU
        mk0_d = k0 * MD
        mk0_l = k0 * ML
        mk0_r = k0 * MR

        result = {
            'avg0_c': self._weighted_avg(patch_s11, mk0_c),
            'avg0_u': self._weighted_avg(patch_s11, mk0_u),
            'avg0_d': self._weighted_avg(patch_s11, mk0_d),
            'avg0_l': self._weighted_avg(patch_s11, mk0_l),
            'avg0_r': self._weighted_avg(patch_s11, mk0_r),
            'avg1_c': self._weighted_avg(patch_s11, k1 * MC),
            'avg1_u': self._weighted_avg(patch_s11, k1 * MU),
            'avg1_d': self._weighted_avg(patch_s11, k1 * MD),
            'avg1_l': self._weighted_avg(patch_s11, k1 * ML),
            'avg1_r': self._weighted_avg(patch_s11, k1 * MR),
        }
        return result

    def _grad_inverse_remap(self, g: List[int]) -> List[int]:
        """Inverse remap of gradients"""
        idx = list(range(5))
        for i in range(4):
            for j in range(4 - i):
                if g[idx[j]] < g[idx[j + 1]]:
                    idx[j], idx[j + 1] = idx[j + 1], idx[j]
        inv = [0] * 5
        for i in range(5):
            inv[idx[4 - i]] = g[idx[i]]
        return inv

    def _compute_gradient_fusion(self, dir_avg: Dict[str, int],
                                 grad_u: int, grad_d: int,
                                 grad_l: int, grad_r: int, grad_c: int) -> Tuple[int, int]:
        """Gradient fusion - matches HLS"""
        g = [grad_u, grad_d, grad_l, grad_r, grad_c]
        inv = self._grad_inverse_remap(g)
        sum_inv = sum(inv)

        v0 = [dir_avg['avg0_c'], dir_avg['avg0_u'], dir_avg['avg0_d'],
              dir_avg['avg0_l'], dir_avg['avg0_r']]
        v1 = [dir_avg['avg1_c'], dir_avg['avg1_u'], dir_avg['avg1_d'],
              dir_avg['avg1_l'], dir_avg['avg1_r']]

        if sum_inv == 0:
            # When gradient sum is 0, use simple average
            total0 = sum(v0)
            total1 = sum(v1)
            blend0 = self._saturate_s11(self._round_div(total0, 5))
            blend1 = self._saturate_s11(self._round_div(total1, 5))
        else:
            total0 = sum(v * i for v, i in zip(v0, inv))
            total1 = sum(v * i for v, i in zip(v1, inv))
            blend0 = self._saturate_s11(self._round_div(total0, sum_inv))
            blend1 = self._saturate_s11(self._round_div(total1, sum_inv))

        return blend0, blend1

    def _get_ratio(self, win_size: int) -> int:
        """Get blending ratio based on window size"""
        idx = self._clip(win_size // 8 - 2, 0, 3)
        return self.cfg.blending_ratio[idx]

    def _mix_scalar(self, scalar: int, src: np.ndarray, factor: np.ndarray) -> np.ndarray:
        """Scalar mixing - uses rounding like C++ round_div"""
        f = factor.astype(np.int32)
        # Compute numerator for each element
        num = scalar * f + src.astype(np.int32) * (4 - f)
        # Use proper rounding for each element (handles negative values correctly)
        result = self._round_div(num, 4)
        return self._saturate_s11(result)

    def _compute_iir_blend(self, src: np.ndarray, win_size: int,
                          blend0_g: int, blend1_g: int,
                          avg0_u: int, avg1_u: int,
                          grad_h: int, grad_v: int) -> np.ndarray:
        """IIR blend - matches HLS"""
        ratio = self._get_ratio(win_size)

        b0_hor = self._saturate_s11(self._round_div(ratio * blend0_g + (64 - ratio) * avg0_u, 64))
        b1_hor = self._saturate_s11(self._round_div(ratio * blend1_g + (64 - ratio) * avg1_u, 64))

        vert_dom = abs(grad_v) > abs(grad_h)

        # Orientation factor (C++ matches: F_ORI_V has indices 7,12,17=1, F_ORI_H has 11,12,13=1)
        F_ORI_V = np.zeros((5, 5), dtype=np.int32)
        F_ORI_V[1, 2] = 1  # C++ flat index 7
        F_ORI_V[2, 2] = 1  # C++ flat index 12
        F_ORI_V[3, 2] = 1  # C++ flat index 17
        F_ORI_H = np.zeros((5, 5), dtype=np.int32)
        F_ORI_H[2, 1:4] = 1
        f_orient = F_ORI_V if vert_dom else F_ORI_H

        # Blend kernels
        F2X2 = np.array([0,0,0,0,0,0,1,2,1,0,0,2,4,2,0,0,1,2,1,0,0,0,0,0,0], dtype=np.int32).reshape(5,5)
        F3X3 = np.array([0,0,0,0,0,0,1,1,1,0,0,1,1,1,0,0,1,1,1,0,0,0,0,0,0], dtype=np.int32).reshape(5,5)
        F4X4 = np.array([1,1,2,1,1,1,2,4,2,1,2,4,8,4,2,1,2,4,2,1,1,1,2,1,1], dtype=np.int32).reshape(5,5)
        F5X5 = np.ones((5, 5), dtype=np.int32)

        t = self.cfg.win_size_thresh
        final_patch = np.zeros((5, 5), dtype=np.int32)
        blend0_win = np.zeros((5, 5), dtype=np.int32)
        blend1_win = np.zeros((5, 5), dtype=np.int32)

        if win_size < t[0]:
            tmp1 = self._mix_scalar(b1_hor, src, f_orient)
            tmp2 = self._mix_scalar(b1_hor, src, F2X2)
            # C++ uses: round_div(tmp1 * reg_edge_protect + tmp2 * (64 - reg_edge_protect), 64)
            blend1_win = self._round_div(
                tmp1 * self.cfg.reg_edge_protect + tmp2 * (64 - self.cfg.reg_edge_protect),
                64
            )
        elif win_size < t[1]:
            tmp1 = self._mix_scalar(b1_hor, src, f_orient)
            tmp2 = self._mix_scalar(b1_hor, src, F2X2)
            blend1_win = self._round_div(
                tmp1 * self.cfg.reg_edge_protect + tmp2 * (64 - self.cfg.reg_edge_protect),
                64
            )
            blend0_win = self._mix_scalar(b0_hor, src, F3X3)
        elif win_size < t[2]:
            blend1_win = self._mix_scalar(b1_hor, src, F3X3)
            blend0_win = self._mix_scalar(b0_hor, src, F4X4)
        elif win_size < t[3]:
            blend1_win = self._mix_scalar(b1_hor, src, F4X4)
            blend0_win = self._mix_scalar(b0_hor, src, F5X5)
        else:
            blend0_win = self._mix_scalar(b0_hor, src, F5X5)

        remain = win_size % 8
        if win_size < t[0]:
            final_patch = blend1_win
        elif win_size >= t[3]:
            final_patch = blend0_win
        else:
            # C++ uses: round_div(blend0_win * remain + blend1_win * (8 - remain), 8)
            final_patch = self._round_div(
                blend0_win * remain + blend1_win * (8 - remain),
                8
            )

        return final_patch

    def _sobel_gradient_at(self, img: np.ndarray, center_i: int, center_j: int) -> int:
        """Compute gradient at a specific position"""
        window = self._get_window(img, center_i, center_j)
        _, _, grad = self._sobel_gradient(window)
        return grad

    def process(self, img: np.ndarray) -> np.ndarray:
        """
        Process entire image - feed-forward per-pixel (matches HLS standalone)
        NO feedback - each pixel computed independently using original image
        """
        h, w = img.shape
        output = np.zeros((h, w), dtype=np.int32)

        for j in range(h):
            for i in range(w):
                # Build center window with sparse sampling
                window = self._get_window(img, i, j)

                # Convert to signed
                patch_s11 = self._u10_to_s11(window)

                # Sobel gradient at center
                grad_h, grad_v, grad_c = self._sobel_gradient(window)

                # Gradients at left and right (for LUT)
                left_i = self._clip(i - 2, 0, w - 1)
                right_i = self._clip(i + 2, 0, w - 1)
                grad_l = self._sobel_gradient_at(img, left_i, j)
                grad_r = self._sobel_gradient_at(img, right_i, j)

                win_size = self._lut_win_size(max(grad_l, max(grad_c, grad_r)))

                # Directional average
                dir_avg = self._compute_directional_avg(patch_s11, win_size)

                # Neighbors for fusion
                up_j = self._clip(j - 1, 0, h - 1)
                down_j = self._clip(j + 1, 0, h - 1)
                grad_u = self._sobel_gradient_at(img, i, up_j)
                grad_d = self._sobel_gradient_at(img, i, down_j)

                # Gradient fusion
                blend0, blend1 = self._compute_gradient_fusion(
                    dir_avg, grad_u, grad_d, grad_l, grad_r, grad_c
                )

                # IIR blend
                final_patch = self._compute_iir_blend(
                    patch_s11, win_size, blend0, blend1,
                    dir_avg['avg0_u'], dir_avg['avg1_u'],
                    grad_h, grad_v
                )

                output[j, i] = self._s11_to_u10(final_patch[2, 2])

        return output


# ============================================================================
# HLS-Style Test Configuration
# ============================================================================

@dataclass
class HLSTestConfig:
    """Configuration matching HLS standalone model"""
    img_width: int = 64
    img_height: int = 64
    win_size_thresh: List[int] = field(default_factory=lambda: [16, 24, 32, 40])
    win_size_clip_y: List[int] = field(default_factory=lambda: [15, 23, 31, 39])
    win_size_clip_sft: List[int] = field(default_factory=lambda: [2, 2, 2, 2])
    blending_ratio: List[int] = field(default_factory=lambda: [32, 32, 32, 32])
    reg_edge_protect: int = 32

    def __str__(self):
        return (f"HLSConfig({self.img_width}x{self.img_height}, "
                f"thresh={self.win_size_thresh}, clip_y={self.win_size_clip_y})")


class HLSConfigGenerator:
    """Generates random HLS-style configurations"""

    def __init__(self, seed: int = 0):
        self.rng = np.random.default_rng(seed)

    def generate_random_config(self,
                               img_size_range: Tuple[int, int] = (16, 128),
                               thresh_range: Tuple[int, int] = (8, 48),
                               clip_y_range: Tuple[int, int] = (8, 48),
                               blend_range: Tuple[int, int] = (8, 56),
                               sft_range: Tuple[int, int] = (1, 4)) -> HLSTestConfig:
        """Generate random HLS configuration"""
        return HLSTestConfig(
            img_width=self.rng.integers(img_size_range[0], img_size_range[1] + 1),
            img_height=self.rng.integers(img_size_range[0], img_size_range[1] + 1),
            win_size_thresh=[
                self.rng.integers(thresh_range[0], thresh_range[1]),
                self.rng.integers(thresh_range[0], thresh_range[1]),
                self.rng.integers(thresh_range[0], thresh_range[1]),
                self.rng.integers(thresh_range[0], thresh_range[1]),
            ],
            win_size_clip_y=[
                self.rng.integers(clip_y_range[0], clip_y_range[1]),
                self.rng.integers(clip_y_range[0], clip_y_range[1]),
                self.rng.integers(clip_y_range[0], clip_y_range[1]),
                self.rng.integers(clip_y_range[0], clip_y_range[1]),
            ],
            blending_ratio=[
                self.rng.integers(blend_range[0], blend_range[1] + 1),
                self.rng.integers(blend_range[0], blend_range[1] + 1),
                self.rng.integers(blend_range[0], blend_range[1] + 1),
                self.rng.integers(blend_range[0], blend_range[1] + 1),
            ],
            reg_edge_protect=self.rng.integers(16, 64),
        )

    def generate_stimulus(self, config: HLSTestConfig, pattern: str = 'random') -> np.ndarray:
        """Generate test stimulus"""
        size = config.img_width * config.img_height

        if pattern == "random":
            return self.rng.integers(0, 1024, size, dtype=np.uint16).reshape(
                config.img_height, config.img_width
            )
        elif pattern == "ramp":
            return (np.arange(size, dtype=np.uint16) % 1024).reshape(
                config.img_height, config.img_width
            )
        elif pattern == "checker":
            # Match C++ pattern: ((i / 4 + j / 4) % 2) ? 1023 : 0
            x = np.arange(config.img_width) // 4
            y = np.arange(config.img_height) // 4
            xx, yy = np.meshgrid(x, y)
            checker = (xx + yy) % 2
            return (checker * 1023).astype(np.uint16)
        elif pattern == "gradient":
            x = np.arange(config.img_width)
            y = np.arange(config.img_height)
            xx, yy = np.meshgrid(x, y)
            gradient = ((xx * 1024 // config.img_width + yy * 1024 // config.img_height) // 2) % 1024
            return gradient.astype(np.uint16)
        elif pattern == "zero":
            return np.zeros((config.img_height, config.img_width), dtype=np.uint16)
        elif pattern == "max":
            return np.full((config.img_height, config.img_width), 1023, dtype=np.uint16)
        elif pattern == "corner":
            arr = np.zeros((config.img_height, config.img_width), dtype=np.uint16)
            arr[0, 0] = 1023
            arr[-1, -1] = 1023
            arr[0, -1] = 511
            arr[-1, 0] = 511
            return arr
        else:
            return self.rng.integers(0, 1024, size, dtype=np.uint16).reshape(
                config.img_height, config.img_width
            )


# ============================================================================
# Coverage Collector
# ============================================================================

class CoverageCollector:
    """Collects and analyzes coverage of corner cases"""

    def __init__(self):
        self.win_size_bins = defaultdict(int)  # Which kernel type triggered
        self.grad_bins = defaultdict(int)      # Gradient ranges
        self.blend_ratio_bins = defaultdict(int)  # Blend ratio ranges
        self.configs_tested = []

    def record(self, config: HLSTestConfig, img: np.ndarray, diff_max: int):
        """Record a test case for coverage"""
        # Record kernel type distribution (based on thresholds)
        for i, t in enumerate(config.win_size_thresh):
            self.win_size_bins[f"thresh_{i}_{t}"] += 1

        # Record gradient range from image
        grad_min, grad_max = int(img.min()), int(img.max())
        grad_range = f"grad_{grad_min//256}_{grad_max//256}"
        self.grad_bins[grad_range] += 1

        # Record blend ratio
        for i, r in enumerate(config.blending_ratio):
            self.blend_ratio_bins[f"blend_{i}_{r}"] += 1

        self.configs_tested.append({
            'img_size': f"{config.img_width}x{config.img_height}",
            'max_diff': diff_max,
        })

    def get_coverage_report(self) -> str:
        """Generate coverage report"""
        lines = ["\n=== COVERAGE REPORT ==="]

        # Image size coverage
        sizes = set(c['img_size'] for c in self.configs_tested)
        lines.append(f"\nImage sizes tested: {len(sizes)}")
        lines.append(f"  {', '.join(sorted(sizes))}")

        # Kernel type coverage (simplified)
        lines.append(f"\nKernel threshold combinations: {len(self.win_size_bins)}")

        # Blend ratio coverage
        lines.append(f"Blend ratio entries: {len(self.blend_ratio_bins)}")

        # Gradient coverage
        lines.append(f"Gradient ranges: {len(self.grad_bins)}")

        return "\n".join(lines)


# ============================================================================
# Main Verification Runner
# ============================================================================

@dataclass
class TestResult:
    """Result of a single test"""
    seed: int
    pattern: str
    config: HLSTestConfig
    passed: bool
    max_diff: int
    mean_diff: float
    hls_output: Optional[np.ndarray] = None
    python_output: Optional[np.ndarray] = None


class HLSRealtimeVerification:
    """Main verification runner"""

    def __init__(self, output_dir: str = "hls_verification_results", tolerance: int = 0):
        self.hls_dir = SCRIPT_DIR
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.hls_runner = HLSModelRunner(self.hls_dir)
        self.coverage = CoverageCollector()
        self.tolerance = tolerance

    def run_single_test(self, seed: int, pattern: str = 'random',
                        img_size: Tuple[int, int] = (64, 64)) -> TestResult:
        """Run a single test"""
        print(f"\n{'='*60}")
        print(f"Test seed={seed}, pattern={pattern}")
        print(f"{'='*60}")

        # Use default config (HLS standalone has hardcoded defaults)
        config = HLSTestConfig()  # Uses default values
        config.img_width = 64
        config.img_height = 64

        # Generate stimulus using same seed for reproducibility
        gen = HLSConfigGenerator(seed)
        stimulus = gen.generate_stimulus(config, pattern)
        print(f"  Stimulus: {pattern}, shape={stimulus.shape}, range=[{stimulus.min()}, {stimulus.max()}]")

        # Run Python reference model (no-feedback)
        print("  Running Python reference model...")
        py_model = PythonReferenceModel(config)
        python_output = py_model.process(stimulus.astype(np.int32))
        print(f"  Python output: range=[{python_output.min()}, {python_output.max()}]")

        # Run HLS model with the stimulus
        print("  Running HLS model...")
        hls_output = self.hls_runner.run(pattern, stimulus)

        if hls_output is None:
            print("  FAILED: HLS model run failed")
            return TestResult(
                seed=seed, pattern=pattern, config=config,
                passed=False, max_diff=-1, mean_diff=-1,
                python_output=python_output
            )

        print(f"  HLS output: range=[{hls_output.min()}, {hls_output.max()}]")

        # Compare outputs
        diff = np.abs(python_output.astype(np.int32) - hls_output.astype(np.int32))
        max_diff = int(np.max(diff))
        mean_diff = float(np.mean(diff))

        print(f"\n  Comparison:")
        print(f"    Max diff: {max_diff}")
        print(f"    Mean diff: {mean_diff:.4f}")

        # Use tolerance for pass/fail (helps with rounding differences)
        passed = max_diff <= self.tolerance
        status = "PASS" if passed else "FAIL"
        print(f"    Status: [{status}] (tolerance={self.tolerance})")

        # Record coverage
        self.coverage.record(config, stimulus, max_diff)

        # Save outputs if failed (for debugging)
        if not passed:
            self._save_failed_test(seed, config, stimulus, python_output, hls_output)

        return TestResult(
            seed=seed, pattern=pattern, config=config,
            passed=passed, max_diff=max_diff, mean_diff=mean_diff,
            hls_output=hls_output, python_output=python_output
        )

    def _save_failed_test(self, seed: int, config: HLSTestConfig,
                          stimulus: np.ndarray, python_out: np.ndarray, hls_out: np.ndarray):
        """Save outputs from a failed test for debugging"""
        test_dir = self.output_dir / f"failed_seed{seed}"
        test_dir.mkdir(parents=True, exist_ok=True)

        # Save stimulus
        np.savetxt(test_dir / "stimulus.txt", stimulus, fmt="%03x")

        # Save outputs
        np.savetxt(test_dir / "python_output.txt", python_out, fmt="%d")
        np.savetxt(test_dir / "hls_output.txt", hls_out, fmt="%d")

        # Save diff
        diff = np.abs(python_out.astype(np.int32) - hls_out.astype(np.int32))
        np.savetxt(test_dir / "diff.txt", diff, fmt="%d")

        # Save config
        with open(test_dir / "config.txt", 'w') as f:
            f.write(f"seed={seed}\n")
            f.write(f"img_width={config.img_width}\n")
            f.write(f"img_height={config.img_height}\n")
            f.write(f"win_size_thresh={config.win_size_thresh}\n")
            f.write(f"win_size_clip_y={config.win_size_clip_y}\n")
            f.write(f"blending_ratio={config.blending_ratio}\n")

        print(f"  Saved debug files to {test_dir}")

    def run_random_tests(self, num_tests: int, pattern: str = 'random',
                        img_size: Tuple[int, int] = (64, 64),
                        seed_start: int = 0) -> Dict:
        """Run multiple random tests"""
        print(f"\n{'#'*60}")
        print(f"Running {num_tests} random tests")
        print(f"{'#'*60}")

        results = []
        passed_count = 0
        failed_count = 0

        for i in range(num_tests):
            seed = seed_start + i
            result = self.run_single_test(seed, pattern, img_size)
            results.append(result)

            if result.passed:
                passed_count += 1
            else:
                failed_count += 1

            print(f"\n  Progress: {i+1}/{num_tests} | Passed: {passed_count} | Failed: {failed_count}")

        return {
            'total': num_tests,
            'passed': passed_count,
            'failed': failed_count,
            'results': results,
        }

    def generate_report(self, stats: Dict) -> str:
        """Generate final report"""
        lines = []
        lines.append("\n" + "=" * 60)
        lines.append("HLS vs PYTHON REFERENCE VERIFICATION REPORT")
        lines.append("=" * 60)

        lines.append(f"\nTest Summary:")
        lines.append(f"  Total:   {stats['total']}")
        lines.append(f"  Passed:  {stats['passed']}")
        lines.append(f"  Failed:  {stats['failed']}")
        lines.append(f"  Pass Rate: {stats['passed']/stats['total']*100:.2f}%")

        # Find worst cases
        failed_results = [r for r in stats['results'] if not r.passed]
        if failed_results:
            lines.append(f"\nFailed tests (worst {min(5, len(failed_results))}):")
            sorted_failed = sorted(failed_results, key=lambda r: -r.max_diff)
            for r in sorted_failed[:5]:
                lines.append(f"  seed={r.seed}: max_diff={r.max_diff}, config={r.config}")

        # Coverage report
        lines.append(self.coverage.get_coverage_report())

        lines.append("\n" + "=" * 60)
        if stats['failed'] == 0:
            lines.append("ALL TESTS PASSED - Ready for coverage collection")
        else:
            lines.append("SOME TESTS FAILED - Fix before proceeding")
        lines.append("=" * 60)

        return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(
        description="HLS C++ Model vs Python Reference Verification"
    )
    parser.add_argument("--num-tests", "-n", type=int, default=10,
                       help="Number of random tests")
    parser.add_argument("--seed", "-s", type=int, default=None,
                       help="Single test seed")
    parser.add_argument("--seed-start", type=int, default=0,
                       help="Starting seed for multiple tests")
    parser.add_argument("--pattern", "-p", type=str, default='random',
                       choices=['random', 'ramp', 'checker', 'gradient', 'zero', 'max', 'corner'],
                       help="Stimulus pattern")
    parser.add_argument("--width", "-W", type=int, default=64,
                       help="Image width")
    parser.add_argument("--height", "-H", type=int, default=64,
                       help="Image height")
    parser.add_argument("--output", "-o", type=str, default="hls_verification_results",
                       help="Output directory")
    parser.add_argument("--tolerance", "-t", type=int, default=0,
                       help="Accept tolerance for diff (default=0 for exact match)")
    parser.add_argument("--golden-only", action="store_true",
                       help="Run Python reference only (no HLS)")

    args = parser.parse_args()

    runner = HLSRealtimeVerification(output_dir=args.output, tolerance=args.tolerance)

    print("=" * 60)
    print("HLS C++ Model vs Python Reference Verification")
    print(f"Started: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 60)

    if args.golden_only:
        # Just run Python reference with various configs
        print("\nRunning Python reference only (no HLS)...")
        gen = HLSConfigGenerator(0)
        for seed in range(5):
            config = gen.generate_random_config()
            print(f"\nConfig {seed}: {config}")
            stimulus = gen.generate_stimulus(config, args.pattern)
            py_model = PythonReferenceModel(config)
            output = py_model.process(stimulus.astype(np.int32))
            print(f"  Output range: [{output.min()}, {output.max()}]")
        print("\nPython reference only run complete")
        return

    if args.num_tests == 1 and args.seed is not None:
        # Single test
        result = runner.run_single_test(
            args.seed, args.pattern, (args.width, args.height)
        )
        if result.passed:
            print("\nTEST PASSED")
            sys.exit(0)
        else:
            print("\nTEST FAILED")
            sys.exit(1)
    else:
        # Multiple tests
        stats = runner.run_random_tests(
            num_tests=args.num_tests,
            pattern=args.pattern,
            img_size=(args.width, args.height),
            seed_start=args.seed_start
        )

        report = runner.generate_report(stats)
        print(report)

        # Save report
        report_path = Path(args.output) / "verification_report.txt"
        with open(report_path, 'w') as f:
            f.write(report)
        print(f"\nReport saved to: {report_path}")

        sys.exit(0 if stats['failed'] == 0 else 1)


if __name__ == "__main__":
    main()
